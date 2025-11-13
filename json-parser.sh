#!/bin/sh
# shellcheck disable=SC3043,SC3060

_NL_='
'
DEFAULT_IFS=" 	${_NL_}"
IFS="$DEFAULT_IFS"


json_err() {
	[ -z "$ERR_PATH_REPORTED" ] && error_out "At json path '${JSON_PATH}${2:+":"}${2}'"
	ERR_PATH_REPORTED=1
	[ -n "$1" ] && error_out "$1"
}

inc_pr_offset() { pr_offset="${pr_offset}    "; }
dec_pr_offset() { pr_offset="${pr_offset%    }"; }

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

# TODO: remove this function
trim_spaces() {
	local tr_in tr_out
	eval "tr_in=\"\${$1}\""
	tr_out="${tr_in%"${tr_in##*[! 	]}"}"
	tr_out="${tr_out#"${tr_out%%[! 	]*}"}"
	eval "$1=\"\${tr_out}\""
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

print_no_json_line() {
	local no_err=
	[ "$1" = "-no_err" ] && { no_err=1; shift; }
	[ -n "$prev_line_err_check_req" ] && printf '%s\n' " &&"
	printf '%s' "${pr_offset}${1}"
	prev_line_err_check_req=1
	[ -n "$no_err" ] && { prev_line_err_check_req=''; printf '\n'; }
}


get_match_var() {
	local match_var
	case "$2" in
		direction) match_var="DIR" ;;
		gameqdisc) match_var="gameqdisc" ;;
		*) false
	esac || return 1
	eval "$1=\"$match_var\""
}

# req match helper
test_req_match() {
	local test_val var key="$1" val="$2"
	[ -n "$key" ] && [ -n "$val" ] &&
	get_match_var var "$key" &&
	eval "test_val=\"\${$var}\"" || return 2

	[ "$val" = "$test_val" ]
}


traverse_obj() {
	local tc_obj_id='' \
		condition_hier_ind="${condition_hier_ind:-0}" \
		condition_json_path='' \
		json_obj_cnt=0 json_child_type key val child_keys='' family families class_enums \
		req_key req_val req_vals \
		pr_offset="$pr_offset" \
			json_obj="$1" \
			tc_parent_obj_id="$2"
	
	case "$json_obj" in
		ROOT)
			tc_parent_obj_id=root
			get_child_keys child_keys || { json_err "No child keys found."; return 1; } ;;
		*)
			json_select_h "$json_obj" || return 1
			get_child_keys child_keys
	esac

	local traverse_parent_id="$tc_parent_obj_id"

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
		json_obj_cnt=$((json_obj_cnt + 1))

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
					json_err "No helper specified for object '$json_obj'."
					return 1
				} ;;
			*) false			
		esac || { json_err "'$key' is not expected here."; return 1; }

		case "$json_child_type" in
			object)
				case "$key" in
					QDISC*|CLASS_*) traverse_obj "$key" "$traverse_parent_id" ;;
					*) json_err "Unexpected key '$key'"; return 1
				esac ;;
			string)
				get_json_var val "$key" || return 1
				case "$key" in
					requires)
						req_key="${val%%=*}"
						req_vals="${val#"$req_key"}"
						req_vals="${req_vals#=}"

						if [ -n "$TRANSLATE_TO_NO_JSON" ]; then
							local var
							get_match_var var "$req_key"
							print_no_json_line -no_err "case \"\$$var\" in ${req_vals})"
							prev_line_err_check_req=''
							condition_hier_ind=$((condition_hier_ind+1))
							eval "condition_json_path_${condition_hier_ind}=\"$JSON_PATH\""
							inc_pr_offset
							continue
						fi

						local match_err=''
						[ -n "$req_vals" ] &&
						local IFS="|" &&
						for req_val in $req_vals; do
							IFS="$DEFAULT_IFS"
							test_req_match "$req_key" "$req_val" && continue 2
							[ $? != 2 ] || { match_err=1; break; }
						done || match_err=1
						IFS="$DEFAULT_IFS"

						[ -n "$match_err" ] && { json_err "Failed to parse 'requires' statement '$val'."; return 1; }
						break ;;
					helper)
						local tc_obj_type="${json_obj%%_*}"
						if [ -z "$TRANSLATE_TO_NO_JSON" ]; then
							create_tc_obj "$val" "${tc_obj_type}" "$tc_obj_id" "$tc_parent_obj_id" || return 1
						else
							case "$tc_obj_type" in
								CLASS) tc_obj_type_lc=class ;;
								QDISC) tc_obj_type_lc=qdisc ;;
								*) json_err "Unexpected tc obj type '$tc_obj_type'."; return 1
							esac
							print_no_json_line "create_${tc_obj_type_lc} \"$val\" \"$tc_obj_id\" \"$tc_parent_obj_id\""
						fi
						inc_pr_offset
						continue ;;
					*)
						json_err "Unexpected string/int key '$key'"
						return 1
				esac ;;
			array)
				get_json_arr class_enums "$key" || return 1
				case "$key" in
					FILTERS|FILTERS_IPV4|FILTERS_IPV6)
						if [ "$key" = FILTERS ]; then
							families="ipv4 ipv6"
							[ -n "$TRANSLATE_TO_NO_JSON" ] && {
								print_no_json_line -no_err "for family in $families; do"
								inc_pr_offset
							}
						else
							families="ipv${key#"FILTERS_IPV"}"
						fi

						if [ -z "$TRANSLATE_TO_NO_JSON" ]; then
							for family in $families; do
								create_filters "$class_enums" "$tc_obj_id" "$family" || return 1
							done
						else
							print_no_json_line -no_err \
								"create_filters \"$class_enums\" \"$tc_obj_id\" \"\$family\" || return 1"
							[ "$key" = FILTERS ] && {
								dec_pr_offset
								print_no_json_line "done"
							}
						fi
						continue ;;
					*) json_err "Unexpected array '$key'"; return 1
				esac ;;
			*) json_err "Unexpected object type '$json_child_type'." "$key"; return 1
		esac || return 1
	done

	[ -n "$TRANSLATE_TO_NO_JSON" ] && {
		eval "condition_json_path=\"\${condition_json_path_${condition_hier_ind}}\""
		if [ "$JSON_PATH" = "$condition_json_path" ]; then
			dec_pr_offset
			dec_pr_offset
			prev_line_err_check_req=
			printf '\n'
			print_no_json_line "esac"
			unset "condition_json_path_${condition_hier_ind}"
		fi
	}

	case "$json_obj" in
		ROOT) ;;
		*) json_select_h .. || return 1
	esac

	:
}

init_json_parser() {
	# shellcheck source=/dev/null
	. /usr/share/libubox/jshn.sh &&
	json_load_file "${1}" || { json_err "Failed to load file '$1'."; exit 1; }

	JSON_PATH="ROOT"
}

parse_json() {
	traverse_obj "ROOT"
	[ -n "$TRANSLATE_TO_NO_JSON" ] && printf '\n'
}
