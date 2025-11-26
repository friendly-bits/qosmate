#!/bin/sh
# shellcheck disable=SC3043,SC3060

_NL_='
'
DEFAULT_IFS=" 	${_NL_}"
IFS="$DEFAULT_IFS"

PR_OFFSET_UNIT="    "

trim_spaces() {
	local tr_in tr_out
	eval "tr_in=\"\${$1}\""
	tr_out="${tr_in%"${tr_in##*[! 	]}"}"
	tr_out="${tr_out#"${tr_out%%[! 	]*}"}"
	eval "$1=\"\${tr_out}\""
}

json_err() {
	printf '\n'
	[ -z "$ERR_PATH_REPORTED" ] && error_out "At json path '${JSON_PATH}${2:+":"}${2}'"
	ERR_PATH_REPORTED=1
	[ -n "$1" ] && error_out "$1"
}

inc_pr_offset() { pr_offset="${pr_offset}${PR_OFFSET_UNIT}"; }
dec_pr_offset() { pr_offset="${pr_offset%"${PR_OFFSET_UNIT}"}"; }

json_select_h() {
	case "$1" in
		'') false ;;
		'..')
			json_select .. &&
			JSON_PATH="${JSON_PATH%":"*}" ;;
		*)
			json_select "$1" &&
			JSON_PATH="${JSON_PATH}:${1}"
	esac || { json_err "Failed to select object '$1'."; return 1; }
	:
}

# Check that expression is safe for RHS of eval
check_shell_expr() {
	local s="$1"
	trim_spaces s
	case "$s" in
		*[!a-zA-Z0-9'_.(){}+-*/%?$!&><=#: ']* ) ;; # only allow these characters
		*\\*|*\$\([!\(]* ) ;; # disallow backslash and subshells
		*) return 0
	esac
	json_err "Unsupported shell epxression '$1'."
	return 1
}

get_json_var() {
	local gv_out_var="$1" gv_key="$2" gv_val="$3"
	[ -n "$gv_val" ] || json_get_var gv_val "$gv_key" &&
	case "$gv_val" in
		*\$[a-zA-Z_\{\(]* )
			check_shell_expr "$gv_val" &&
			eval "gv_val=\"$gv_val\"" ;;
	esac || { json_err "Failed to get var value." "$gv_key"; return 1; }

	eval "$gv_out_var=\"\${gv_val}\""
}

get_json_arr() {
	local ga_val ga_values='' _type='' \
		ga_out_var="$1" ga_key="$2"

	json_select_h "$ga_key" || return 1

	i=0
	while :; do
		i=$((i+1))
		json_get_type _type $i && [ -n "$_type" ] || break
		get_json_var ga_val ${i} || return 1
		ga_values="${ga_values}${ga_values:+"${_NL_}"}${ga_val}"
	done
	json_select_h .. || return 1
	eval "$ga_out_var=\"\${ga_values}\""
}

get_child_keys() {
	eval "$1="
	local _key _keys _child_keys='' real_keys_seen=''
	json_get_keys _keys &&
	[ -n "$_keys" ] &&
	for _key in $_keys; do
		case "$_key" in
			comment*) _child_keys="${_child_keys}${_key} " ;;
			*)
				_child_keys="${_child_keys}${_key} "
				real_keys_seen=1
		esac
		:
	done &&
	trim_spaces _child_keys &&
	[ -n "$real_keys_seen" ] || return 1
	eval "$1=\"\${_child_keys}\""
	:
}

print_transl_line() {
	local err_check_str=" &&"
	if [ "$1" = "-end_check" ]; then
		err_check_str=" || return 1"
		shift
	fi
	if [ -n "$prev_line_err_check_req" ]; then
		printf '%s\n' "${err_check_str}"
	else
		printf '\n'
	fi
	[ -n "$COMMENT" ] && printf '%s\n' "${pr_offset}# ${COMMENT}"
	COMMENT=''
	printf '%s' "${pr_offset}${1}"
	prev_line_err_check_req=1
}


get_match_var() {
	local _var
	case "$2" in
		direction) _var="DIR" ;;
		gameqdisc) _var="gameqdisc" ;;
		SFO_ENABLED) _var="SFO_ENABLED" ;;
		*) false
	esac || { json_err "Unexpected 'requires' match '$2'"; return 1; }
	eval "$1=\"$_var\""
}

process_requires() {
	local gc_keys gc_key gc_type \
		req_key='' req_vals='' match_var='' term_delim='' \
		condition='' condition_type='' condition_def='' condition_op='' condition_closure='' pr_con_line='' \
		IFS="$DEFAULT_IFS" \
		key="$1"

	# check obj condition
	json_select_h "$key" || return 1
	get_child_keys gc_keys
	for gc_key in $gc_keys; do
		case "$gc_key" in
			comment*) continue ;;
			requires|requires_or)
				json_get_type gc_type "$gc_key" &&
				case "$gc_type" in
					array)
						condition_op="if"
						condition_closure="fi"
						get_json_arr condition_def "$gc_key" ;;
					string)
						condition_op="case"
						condition_closure="esac"
						get_json_var condition_def "$gc_key" ;;
					*) false
				esac &&
				[ -n "$condition_def" ] || {
					json_err "Failed to process key '$gc_key'"
					return 1
				}

				condition_type="$gc_key"
				condition="$condition_type:$condition_op:$condition_def"
				break ;;
			*) break
		esac
	done
	json_select_h .. || return 1

	if [ "$condition" != "$prev_condition" ]; then
		if [ -n "$prev_condition" ]; then
			case "$prev_condition_closure" in "esac"|"fi") ;;
				*) json_err "Invalid prev condition closure '$prev_condition_closure'"; return 1
			esac
			print_transl_line -end_check "${prev_condition_closure}"
			[ "$prev_condition_closure" = "fi" ] && prev_line_err_check_req=''
			prev_condition_closure=
			dec_pr_offset
		fi

		if [ -n "$condition" ]; then
			inc_pr_offset
			case "$condition" in
				*:*:*:*) false ;;
				*:*:*) ;;
				*) false
			esac &&
			[ -n "$condition_type" ] && [ -n "$condition_op" ] && [ -n "$condition_def" ] ||
				{ match_failed "$condition"; return 1; }

			case "$condition_op" in
				"if")
					case "$condition_type" in
						requires) term_delim="&&" ;;
						requires_or) term_delim="||"
					esac

					pr_con_line=

					IFS="${_NL_}"
					for condition_line in $condition_def; do
						IFS="$DEFAULT_IFS"

						req_key="${condition_line%%=*}" &&
						req_vals="${condition_line#"$req_key"}" &&
						req_vals="${req_vals#=}" &&
						[ -n "$req_vals" ] || { match_failed "$condition_line"; return 1; }

						get_match_var match_var "$req_key" || return 1
						pr_con_line="${pr_con_line}${pr_con_line:+" $term_delim "}[ \"\$$match_var\" = \"$req_vals\" ]"
					done
					IFS="$DEFAULT_IFS"
					print_transl_line -end_check "if ${pr_con_line}; then"
					prev_line_err_check_req=''
					;;
				"case")
					req_key="${condition_def%%=*}" &&
					req_vals="${condition_def#"$req_key"}" &&
					req_vals="${req_vals#=}" &&
					[ -n "$req_vals" ] || { match_failed "$condition_def"; return 1; }

					get_match_var match_var "$req_key" || return 1
					print_transl_line "case \"\$$match_var\" in ${req_vals})"
					prev_line_err_check_req=''
					;;
			esac
		fi
		prev_condition="$condition"
		prev_condition_closure="$condition_closure"
	fi
	:
}

traverse_obj() {
	helper_missing() { json_err "No helper specified for object '$json_obj'."; }
	match_failed () { json_err "Failed to parse 'requires' statement '$1'."; }

	local tc_obj_id="$tc_obj_id" tc_obj_type tc_obj_type_lc \
		prev_condition='' prev_condition_closure='' \
		json_child_type key val child_keys='' family families class_enums \
		pr_offset="$pr_offset" \
		IFS="$DEFAULT_IFS" \
			json_obj="$1" \
			tc_parent_id="$2"

	local traverse_parent_id="$tc_parent_id"

	case "$json_obj" in
		ROOT)
			get_child_keys child_keys || { json_err "No child keys found."; return 1; } ;;
		*)
			json_select_h "$json_obj" || return 1
			get_child_keys child_keys
	esac

	case "$json_obj" in
		QDISC)
			tc_obj_id='' ;;
		QDISC_*)
			tc_obj_id="${json_obj#"QDISC_"}"
			tc_obj_id="${tc_obj_id}:" ;;
		CLASS_*)
			tc_obj_id="${json_obj#"CLASS_"}" ;;
	esac

	case "$json_obj" in
		ROOT) ;;
		LOGIC_BRANCH*)
			local REQUIRES_EXPECTED=1 ;;
		QDISC*|CLASS_*)
			inc_pr_offset
			local HELPER_REQ=1 REQUIRES_EXPECTED=1

			tc_obj_id="${tc_obj_id//_/:}"
			case "$tc_obj_id" in *[!0-9:]*)
				json_err "Invalid result '$tc_obj_id' when translating object '$json_obj' to tc object id."
				return 1
			esac

			traverse_parent_id="$tc_obj_id" ;;
		*)
			json_err "Unexpected object '$json_obj'!"
			return 1
	esac

	for key in $child_keys; do
		json_get_type json_child_type "$key" || { json_err "Failed to get type of key '$key'."; return 1; }

		[ "$json_child_type" = int ] && json_child_type=string # int is equivalent to string for our use case

		case "$key" in
			comment*) ;;
			requires|requires_or)
				[ -n "$REQUIRES_EXPECTED" ] &&
					REQUIRES_EXPECTED='' ;;
			helper)
				[ -n "$HELPER_REQ" ] &&
					REQUIRES_EXPECTED='' HELPER_REQ='' ;;
			QDISC*|CLASS_*|FILTERS*)
				REQUIRES_EXPECTED=''
				[ -z "$HELPER_REQ" ] || {
					helper_missing
					return 1
				} ;;
			LOGIC_BRANCH*) ;;
			*) false
		esac || { json_err "'$key' is not expected here."; return 1; }

		case "$json_child_type" in
			object)
				case "$key" in
					QDISC*|CLASS_*|LOGIC_BRANCH*)
						process_requires "$key" || return 1
						traverse_obj "$key" "$traverse_parent_id" ;;
					*) json_err "Unexpected key '$key'"; false
				esac || return 1
				continue ;;
			string)
				get_json_var val "$key" || return 1
				case "$key" in
					comment*) COMMENT="${val}" ;;
					requires) ;; # processed by the parent json obj
					helper)
						case "$tc_parent_id" in
							root) ;;
							*![0-9:]*) false ;;
							*[0-9]:*) ;;
							*) false
						esac || { json_err "Invalid tc parent id '$tc_parent_id' for tc object '$tc_obj_id'"; return 1; }

						tc_obj_type="${json_obj%%_*}"
						case "$tc_obj_type" in
							CLASS) tc_obj_type_lc=class ;;
							QDISC) tc_obj_type_lc=qdisc ;;
							*) json_err "Unexpected tc obj type '$tc_obj_type'."; return 1
						esac
						print_transl_line "create_${tc_obj_type_lc} \"$val\" \"$tc_obj_id\" \"$tc_parent_id\""
						continue ;;
					*)
						json_err "Unexpected string/int key '$key'"
						return 1
				esac
				continue ;;
			array)
				get_json_arr class_enums "$key" || return 1
				case "$key" in
					FILTERS)
						inc_pr_offset
						families="ipv4 ipv6"
						print_transl_line "for family in $families; do"
						inc_pr_offset
						prev_line_err_check_req=''
						print_transl_line \
							"create_filters \"${class_enums//"$_NL_"/ }\" \"$tc_obj_id\" \"\$family\""
						dec_pr_offset
						print_transl_line -end_check "done"
						dec_pr_offset ;;
					FILTERS_IPV4|FILTERS_IPV6)
						family="ipv${key#"FILTERS_IPV"}"
						print_transl_line \
							"${PR_OFFSET_UNIT}create_filters \"${class_enums//"$_NL_"/ }\" \"$tc_obj_id\" \"$family\""
						;;
					requires|requires_or) ;; # processed by the parent json obj
					*) json_err "Unexpected array '$key'"; return 1
				esac
				continue ;;
			*) json_err "Unexpected object type '$json_child_type'." "$key"; return 1
		esac || return 1
	done

	if [ -n "$prev_condition" ]; then
		print_transl_line -end_check "${prev_condition_closure}"
		dec_pr_offset
		[ "$prev_condition_closure" = "fi" ] && prev_line_err_check_req=''
	fi

	[ -n "$HELPER_REQ" ] && {
		helper_missing
		return 1
	}

	case "$json_obj" in
		ROOT) ;;
		*) json_select_h .. || return 1
	esac

	:
}

init_json_parser() {
	# shellcheck source=/dev/null
	. /usr/share/libubox/jshn.sh || { error_out "Failed to source jshn.sh"; return 1; }
	[ -e "$1" ] || { error_out "No json file specified."; return 1; }
	json_load_file "${1}" || { error_out "Failed to load json file '$1'."; return 1; }

	JSON_PATH="ROOT"
}

parse_json() {
	traverse_obj "ROOT" "root"
}

error_out() {
	printf '%s\n' "Error: $*" >&2
}

init_json_parser "$1" &&
parse_json
rv=$?

if [ $rv = 0 ] && [ -n "$prev_line_err_check_req" ]; then
	printf '%s\n%s\n' " ||" "return 1"
else
	printf '\n'
fi

exit $rv
