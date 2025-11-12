#!/bin/sh
# shellcheck disable=SC3043

create_class() {
	local helper_short="${1%% *}"
	local helper_args="${1#"$helper_short"}"
	create_tc_obj "${helper_short}_class_helper${helper_args}" CLASS "$2" "$3"
}

create_qdisc() {
	local helper_short="${1%% *}"
	local helper_args="${1#"$helper_short"}"
	create_tc_obj "${helper_short}_qdisc_helper${helper_args}" QDISC "$2" "$3"
}

apply_rules_no_json() {
	# Indentation expresses class/qdisc/filters hierarchy position
	create_qdisc root "1:" &&

		{ [ "$DIR" = UP ] || create_class "hfsc_lan" "1:2" "1:" ; } &&

		create_class "hfsc_main_link" "1:1" "1:" &&

			create_class "hfsc_tin fast" "1:12" "1:1" &&
				create_qdisc "hfsc_non_game" "" "1:12" &&
				for family in ipv4 ipv6; do
					create_filters "CS4 AF41 AF42" "1:12" "$family" || return 1
				done &&

			create_class "hfsc_tin normal" "1:13" "1:1" &&
				create_qdisc "hfsc_non_game" "" "1:13" &&
				for family in ipv4 ipv6; do
					create_filters "CS0" "1:13" "$family" || return 1
				done &&

			create_class "hfsc_tin lowprio" "1:14" "1:1" &&
				create_qdisc "hfsc_non_game" "" "1:14" &&
				for family in ipv4 ipv6; do
					create_filters "CS2 AF11" "1:14" "$family" || return 1
				done &&

			create_class "hfsc_tin bulk" "1:15" "1:1" &&
				create_qdisc "hfsc_non_game" "" "1:15" &&
				for family in ipv4 ipv6; do
					create_filters "CS1" "1:15" "$family" || return 1
				done &&

			create_class "hfsc_tin realtime" "1:11" "1:15" &&
				create_qdisc "hfsc_game" "10:" "1:11" &&
					case "$gameqdisc" in
						drr|qfq)
							create_class "game_drr_qfq" 8000 "10:1" "10:" &&
								create_qdisc "red" "11:" "10:1" &&
							create_class "game_drr_qfq" 4000 "10:2" "10:" &&
								create_qdisc "red" "12:" "10:2" &&
							create_class "game_drr_qfq" 1000 "10:3" "10:" &&
								create_qdisc "red" "13:" "10:3" ;;
						*) :
					esac
}
