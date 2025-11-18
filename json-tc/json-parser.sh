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
		ga_values="${ga_values}${ga_values:+ }${ga_val}"
	done
	json_select_h .. || return 1
	eval "$ga_out_var=\"\${ga_values}\""
}

get_child_keys() {
	eval "$1="
	local _key _keys _child_keys=
	json_get_keys _keys &&
	[ -n "$_keys" ] &&
	for _key in $_keys; do
		case "$_key" in
			comment*) ;;
			*) _child_keys="${_child_keys}${_key} "
		esac
		:
	done &&
	trim_spaces _child_keys &&
	[ -n "$_child_keys" ] || return 1
	eval "$1=\"\${_child_keys}\""
	:
}

print_transl_line() {
	local no_err=
	[ "$1" = "-no_err" ] && { no_err=1; shift; }
	[ -n "$prev_line_err_check_req" ] && printf '%s\n' " &&"
	printf '%s' "${pr_offset}${1}"
	prev_line_err_check_req=1
	[ -n "$no_err" ] && { prev_line_err_check_req=''; printf '\n'; }
}


get_match_var() {
	local _var
	case "$2" in
		direction) _var="DIR" ;;
		gameqdisc) _var="gameqdisc" ;;
		*) false
	esac || { json_err "Unexpected 'requires' match '$2'"; return 1; }
	eval "$1=\"$_var\""
}

traverse_obj() {
	helper_missing() { json_err "No helper specified for object '$json_obj'."; }
	match_failed () { json_err "Failed to parse 'requires' statement '$1'."; }

	local tc_obj_id='' tc_obj_type tc_obj_type_lc \
		grandchild_keys grandchild_type \
		curr_child_condition \
		prev_child_condition='' \
		condition_matched='' \
		match_var match_err \
		json_child_type key val child_keys='' family families class_enums \
		req_key req_val req_vals \
		pr_offset="$pr_offset" \
		IFS="$DEFAULT_IFS" \
			json_obj="$1" \
			tc_parent_obj_id="$2"

	local traverse_parent_id="$tc_parent_obj_id"

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
		LOGIC_BRANCH*) local REQUIRES_EXPECTED=1 ;;
		QDISC*|CLASS_*)
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
			requires)
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
						# check obj condition
						curr_child_condition='' req_key='' req_vals='' match_var=''
						json_select_h "$key" || return 1
						get_child_keys grandchild_keys
						for gc_key in $grandchild_keys; do
							case "$gc_key" in
								comment) continue ;;
								requires)
									json_get_type grandchild_type "$gc_key" &&
									[ "$grandchild_type" = string ] &&
									get_json_var curr_child_condition "$gc_key" &&
									[ -n "$curr_child_condition" ] || {
										json_err "Failed to process key '$gc_key'"
										return 1
									}

									req_key="${curr_child_condition%%=*}"
									req_vals="${curr_child_condition#"$req_key"}"
									req_vals="${req_vals#=}"

									[ -n "$req_vals" ] || { match_failed "$curr_child_condition"; return 1; }
									get_match_var match_var "$req_key" || return 1
									break ;;
								*) break
							esac
						done
						json_select_h .. || return 1

						if [ -z "$TRANSLATE_TO_SHELL" ]; then
							if [ -n "$match_var" ]; then
								condition_matched=
								IFS="|"
								for req_val in $req_vals; do
									IFS="$DEFAULT_IFS"
									[ -n "$req_val" ] || { match_err=1; break; }
									eval "[ \"\$req_val\" = \"\${$match_var}\" ]" && { condition_matched=1; break; }
								done
								IFS="$DEFAULT_IFS"
								[ -n "$match_err" ] && { match_failed "$val"; return 1; }
								# ignore child obj if condition not matched
								[ -n "$condition_matched" ] || continue
							fi
						else
							if [ "$curr_child_condition" != "$prev_child_condition" ]; then
								if [ -n "$prev_child_condition" ]; then
									dec_pr_offset
									prev_line_err_check_req=''
									printf '\n'
									print_transl_line "esac"
								fi
								if [ -n "$curr_child_condition" ]; then
									print_transl_line -no_err "case \"\$$match_var\" in ${req_vals})"
									prev_line_err_check_req=''
									inc_pr_offset
								fi
							fi
							prev_child_condition="$curr_child_condition"
						fi

						traverse_obj "$key" "$traverse_parent_id" ;;
					*) json_err "Unexpected key '$key'"; false
				esac || return 1
				continue ;;
			string)
				get_json_var val "$key" || return 1
				case "$key" in
					requires) ;; # processed by the parent json obj
					helper)
						tc_obj_type="${json_obj%%_*}"
						if [ -z "$TRANSLATE_TO_SHELL" ]; then
							create_tc_obj "$val" "${tc_obj_type}" "$tc_obj_id" "$tc_parent_obj_id" || return 1
						else
							case "$tc_obj_type" in
								CLASS) tc_obj_type_lc=class ;;
								QDISC) tc_obj_type_lc=qdisc ;;
								*) json_err "Unexpected tc obj type '$tc_obj_type'."; return 1
							esac
							print_transl_line "create_${tc_obj_type_lc} \"$val\" \"$tc_obj_id\" \"$tc_parent_obj_id\""
						fi
						inc_pr_offset
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
						families="ipv4 ipv6"
						if [ -z "$TRANSLATE_TO_SHELL" ]; then
							for family in $families; do
								create_filters "$class_enums" "$tc_obj_id" "$family" || return 1
							done
						else
							print_transl_line -no_err "for family in $families; do"
							print_transl_line -no_err \
								"${PR_OFFSET_UNIT}create_filters \"$class_enums\" \"$tc_obj_id\" \"\$family\" || return 1"
							print_transl_line "done"
						fi ;;
					FILTERS_IPV4|FILTERS_IPV6)
						family="ipv${key#"FILTERS_IPV"}"

						if [ -z "$TRANSLATE_TO_SHELL" ]; then
							create_filters "$class_enums" "$tc_obj_id" "$family" || return 1
						else
							print_transl_line -no_err \
								"create_filters \"$class_enums\" \"$tc_obj_id\" \"$family\" || return 1"
						fi ;;
					*) json_err "Unexpected array '$key'"; return 1
				esac
				continue ;;
			*) json_err "Unexpected object type '$json_child_type'." "$key"; return 1
		esac || return 1
	done

	if [ -n "$TRANSLATE_TO_SHELL" ] && [ -n "$prev_child_condition" ]; then
		dec_pr_offset
		prev_line_err_check_req=''
		printf '\n'
		print_transl_line "esac"
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


TRANSLATE_TO_SHELL=
if [ -z "$APPLY_SOURCED" ]; then

	error_out() {
		printf '%s\n' "Error: $*" >&2
	}

	TRANSLATE_TO_SHELL=1

	init_json_parser "$1" &&
	parse_json &&
	printf '\n'
	exit $?
fi

:
