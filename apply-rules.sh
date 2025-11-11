#!/bin/sh
# shellcheck disable=SC3043,SC3060

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

# prints each argument to a separate line
print_msg() {
    local _arg
    for _arg in "$@"
    do
        case "${_arg}" in
            '') printf '\n' ;; # print out empty lines
            *) printf '%s\n' "${_arg}"
        esac
    done
    :
}

error_out() { print_msg "${@}"; }


## Req match helper
test_req_match() {
	local test_val key="$1" val="$2"
	[ -n "$key" ] && [ -n "$val" ] &&
	case "$key" in
		direction) test_val="$DIR" ;;
		gameqdisc) test_val="$gameqdisc" ;;
		*) false
	esac || return 2

	[ "$test_val" = "$val" ]
}


## CLASS HELPERS

hfsc_lan_class_helper() {
	append_params "hfsc" &&
	append_curve_params "linkshare" "burst_rate:50000" "burst_dur:$BURST_DUR" "steady_rate:10000"
}

hfsc_main_link_class_helper() {
	append_params "hfsc" &&
	append_curve_params "linkshare" "steady_rate:$NON_GAME_RATE" &&
	append_curve_params "upperlimit" "steady_rate:$NON_GAME_RATE"
}

hfsc_tin_class_helper() {
	local burst_percent steady_percent \
		base_burst_rate="$NON_GAME_RATE" \
		base_steady_rate="$NON_GAME_RATE"

	case "$1" in
		realtime) base_burst_rate="$GAME_BURST_RATE" burst_percent=100 steady_percent=100 ;;
		fast) burst_percent=70 steady_percent=30 ;;
		normal) burst_percent=20 steady_percent=45 ;;
		lowprio) burst_percent=7 steady_percent=15 ;;
		bulk) burst_percent=3 steady_percent=15 ;;
		*) # TODO: throw error
	esac

	append_params "hfsc" &&
	append_curve_params "linkshare" \
		"burst_rate:$((base_burst_rate*burst_percent/100))" \
		"burst_dur:$BURST_DUR" \
		"steady_rate:$((base_steady_rate*steady_percent/100))"
}

drr_qfq_class_helper() {
	[ -n "$1" ] || : # TODO: throw error
	local param
	case "$gameqdisc" in
		drr) param=quantum ;;
		qfq) param=weithg ;;
		*) # TODO: throw error
	esac

	append_params \
		"${gameqdisc}" \
		"${param}:${1}"
}


## QDISC HELPERS

root_qdisc_helper() {
	local oh_params
	get_tc_overhead_params oh_params || return 1
	PARAMS="root $oh_params hfsc default 13"
}

hfsc_non_game_qdisc_helper() {
	case "$nongameqdisc" in
		cake) cake_qdisc_helper ;;
		fq_codel) fq_codel_qdisc_helper ;;
	esac
}

hfsc_game_qdisc_helper() {
	case "$gameqdisc" in
		drr|qfq) append_params "$gameqdisc" ;;
		pfifo) append_params "pfifo" "limit:$((PFIFOMIN+MAXDEL*NON_GAME_RATE/8/PACKETSIZE))" ;;
		bfifo) append_params "bfifo" "limit:$((MAXDEL * GAMERATE / 8))" ;;
		red) red_qdisc_helper ;;
		fq_codel) fq_codel_qdisc_helper ;;
		netem) netem_qdisc_helper ;;
		*) error_out "Unexpected game qdisc '$gameqdisc'."; return 1 ;;
	esac
}

cake_qdisc_helper() {
	append_params \
		"cake" \
		"extra:$nongameqdiscoptions"
}

netem_qdisc_helper() {
	local delay_params='' \
		delay="$netemdelayms" \
		jitter='' \
		dist='' \
		pkt_loss=''

	# If jitter is set but delay is 0, force minimum delay of 1ms
	if [ "$netemjitterms" -gt 0 ] && ! [ "$netemdelayms" -gt 0 ]; then
		delay=1
	fi

	# Add delay parameter if set (either original or forced minimum)
	if [ "$delay" -gt 0 ] && [ "$netemjitterms" -gt 0 ]; then
		jitter="${netemjitterms}"
		dist="${netemdist}"
	fi

	delay_params="${delay:+"delay ${delay}ms"}${jitter:+" ${jitter}ms"}${dist:+" distribution ${dist}"}"

	# Add packet loss if set
	pkt_loss=
	case "$pktlossp" in
		none|'') ;;
		*) pkt_loss="$pktlossp"
	esac

	append_params \
		"netem" \
		"limit:$(( 4 + 9*NON_GAME_RATE/8/500 ))" \
		"extra:${delay_params}${pkt_loss:+ }${pkt_loss}"
}

# shellcheck disable=SC2120
fq_codel_qdisc_helper() {
	local mem_coeff=2

	case "$1" in
		'') ;;
		'-mem-coeff')
			case "$2" in
				''|*![0-9]*) false ;;
				*) mem_coeff="$2"
			esac ;;
		*) false
	esac || {
		error_out "fq_codel_qdisc_helper: invalid args '$*'."
		return 1
	}

	append_params \
		"fq_codel" \
		"memory_limit:$(( NON_GAME_RATE*mem_coeff*100/8 ))" \
		"interval:$(( 100 + 2*1500*8/NON_GAME_RATE ))" \
		"target:$(( 540*8/NON_GAME_RATE + 4 ))" \
		"quantum:$(( MTU * 2 ))"
}

red_qdisc_helper() {
	# Calculate redmin and redmax based on gamerate and MAXDEL
	local redmin=$((GAMERATE * MAXDEL / 3 / 8)) \
		redmax=$((GAMERATE * MAXDEL / 8))

	# Calculate redburst: (min + min + max)/(3 * avpkt) as per RED documentation
	local redburst=$(( (redmin + redmin + redmax) / (3 * 500) ))
	[ $redburst -ge 2 ] || redburst=2

	append_params \
		"red" \
		"limit:150000" \
		"min:$redmin" \
		"max:$redmax" \
		"avpkt:500" \
		"bandwidth:$NON_GAME_RATE" \
		"burst:$redburst" \
		"probability:1.0"
}


## PARAM HELPER FUNCTIONS

append_params() {
	local param
	for param in "$@"; do
		append_param "$param" || return 1
	done
}

append_param() {
	local param_str="$1"
	local param='' key="${param_str%%:*}"
	local val="${param_str#"$key"}"
	val="${val#":"}"

	case "$key" in
		hfsc|cake|fq_codel|red|drr|qfq|pfifo|bfifo|netem) val="$key" ;;
		min|max|avpkt|probability|burst|weight|quantum|limit|memory_limit|interval|target| \
			rt|ls|ul|sc| \
			overhead|mpu) param="$key" ;;
		jitter) val="${val:+"${val}ms"}" ;;
		rtt) val="${val:+"${val}ms"}" ;;
		extra) ;;
		link) ;;
		bandwidth) param="bandwidth" val="${val:+"${val}kbit"}" ;;
		dual_srchost|dual_dsthost|nat|wash|ack-filter)
			# Special treatment for cake params
			local prefix='' \
				selector="$val"
			[ "$selector" = 1 ] ||
				case "$key" in
					wash|nat) prefix='no' ;;
					ack-filter) prefix='no-' ;;
		            *) return 0 ;;
				esac
			val="${prefix}${key//_/-}" ;;
		*) error_out "Unexpected param '$key'"; return 1
	esac
	[ -n "$val" ] || return 0
	PARAMS="${PARAMS}${PARAMS:+ }${param}${param:+ }${val}"
}

append_curve_params() {
	local key val param params_str='' steady_rate='' burst_rate='' burst_dur='' \
		curve curve_type rate dur \
		curve_in="$1"

	case "$curve_in" in
		rt|realtime) curve="rt" ;;
		ls|linkshare) curve="ls" ;;
		ul|upperlimit) curve="ul" ;;
		sc|servicecurve) curve="sc" ;;
		*) error_out "Unexpected curve '$curve_in'."; return 1
	esac
	shift

	for param in "$@"; do
		case "$param" in
			*:*) : ;;
			*) false
		esac &&
		key="${param%%":"*}" &&
		val="${param#*":"}" &&
		[ -n "$key" ] && [ -n "$val" ] &&
		case "$key" in
			burst_dur) burst_dur=" d ${val}ms" ;;
			burst_rate) burst_rate="m1 ${val}kbit" ;;
			steady_rate) steady_rate="m2 ${val}kbit" ;;
			*) false
		esac ||
			{ error_out "Failed to process curve param '$param'."; return 1; }
	done

	: "${burst_rate}" "${steady_rate}" "${burst_dur}"

	for curve_type in burst steady; do
		eval "rate=\"\${${curve_type}_rate}\" dur=\"\${${curve_type}_dur}\""
		params_str="${params_str}${params_str:+ }${rate}${dur}"
	done
	append_param "${curve}:${params_str}"
}


# Set CAKE parameters from common link settings
# $1 = "hybrid" to force manual overhead for consistency with HFSC
cake_link_params_helper() {
	CAKE_OH="$OVERHEAD"
	LINK="$COMMON_LINK_PRESETS"

    # Determine link keyword and default overhead
    case "$LINK" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            [ "$1" = "hybrid" ] && LINK="atm"
            : "${CAKE_OH:=44}"
            ;;
        docsis)        : "${CAKE_OH:=25}" ;;
        raw)           : "${CAKE_OH:=0}"  ;;
        cake-ethernet) LINK="ethernet"; : "${CAKE_OH:=38}" ; [ "$1" = "hybrid" ] || CAKE_OH="" ;;
        ethernet|*)    LINK="ethernet"; : "${CAKE_OH:=40}" ;;
    esac
	:
}

# Set tc stab parameters for HFSC/HTB/Hybrid
get_tc_overhead_params() {
	local _params=''
    # Detect ATM-based presets
    case "$COMMON_LINK_PRESETS" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            _params="stab mtu 2047 tsize 512 mpu 68 overhead ${OVERHEAD:-44} linklayer atm" ;;
        docsis)
            _params="stab overhead ${OVERHEAD:-25} linklayer ethernet" ;;
        cake-ethernet)
            _params="stab overhead ${OVERHEAD:-38} linklayer ethernet" ;;
        raw)
            _params="stab overhead ${OVERHEAD:-0} linklayer ethernet" ;;
        *)
            _params="stab overhead ${OVERHEAD:-40} linklayer ethernet" ;;
    esac
	eval "$1=\"\${_params}\""
	:
}


hybrid_params_helper() {
	CAKE_RATE=$((NON_GAME_RATE - GAMERATE))
	[ $CAKE_RATE -gt 0 ] || CAKE_RATE=1
}

hybrid_bulk_helper() {
    BULK_RATE_BURST=$((RATE*3/100)); [ $BULK_RATE_BURST -le 0 ] && BULK_RATE_BURST=1
    BULK_RATE_STEADY=$((RATE*10/100)); [ $BULK_RATE_STEADY -le 0 ] && BULK_RATE_STEADY=1
}


## TC OBJECTS AND FILTERS

create_tc_obj() {
	local helper_func helper_args unexp_func='' PARAMS='' \
		helper_str="$1" tc_obj_type="$2" tc_obj_id="$3" tc_parent_obj_id="$4"

	[ -n "$helper_str" ] || { error_out "Helper function not specified!"; return 1; }
	helper_func="${helper_str%% *}"
	helper_args="${helper_str#"$helper_func"}"

	case "$tc_obj_type" in
		QDISC)
			case "$helper_func" in
				root_qdisc_helper|hfsc_game_qdisc_helper|hfsc_non_game_qdisc_helper| \
				cake_qdisc_helper|fq_codel_qdisc_helper|red_qdisc_helper)
					${helper_func} ${helper_args} ;;
				*) unexp_func=1; false
			esac &&
			echo "${pr_offset}** tc qdisc add dev \"$DEV\"${tc_parent_obj_id:+ parent }${tc_parent_obj_id}${tc_obj_id:+ handle }${tc_obj_id} ${PARAMS} **" ;;
		CLASS)
			case "$helper_func" in
				hfsc_lan_class_helper|hfsc_main_link_class_helper|hfsc_tin_class_helper|drr_qfq_class_helper)
					${helper_func} ${helper_args} ;;
				*) unexp_func=1; false
			esac &&
			echo "${pr_offset}** tc class add dev \"$DEV\" parent ${tc_parent_obj_id} classid ${tc_obj_id} ${PARAMS} **" ;;
		*) false
	esac ||
		{
			[ -n "$unexp_func" ] && error_out "Unexpected helper '$helper_func'."
			error_out "Failed to create tc object with type '$tc_obj_type', ID '$tc_obj_id'."
			return 1
		}
}

# 1 - filter list (class enum)
# 2 - class id
# 3 - family (ipv4|ipv6)
create_filters() {
    local dsfield hex_match proto prio match_str class_enum \
        class_enums="$1" \
        class_id="$2" \
        family="$3"

	for class_enum in $class_enums; do
		case "$class_enum" in
			cs0|CS0) dsfield=0x00 hex_match=0x0000 ;; # 0 -> Default
			ef|EF) dsfield=0xb8 hex_match=0x0B80 ;; # 46
			cs1|CS1) dsfield=0x20 hex_match=0x0200 ;; # 8
			cs2|CS2) dsfield=0x40 hex_match=0x0400 ;; # 16
			cs4|CS4) dsfield=0x80 hex_match=0x0800 ;; # 32
			cs5|CS5) dsfield=0xa0 hex_match=0x0A00 ;; # 40
			cs6|CS6) dsfield=0xc0 hex_match=0x0C00 ;; # 48
			cs7|CS7) dsfield=0xe0 hex_match=0x0E00 ;; # 56
			af11|AF11) dsfield=0x28 hex_match=0x0280 ;; # 10
			af41|AF41) dsfield=0x88 hex_match=0x0880 ;; # 34
			af42|AF42) dsfield=0x90 hex_match=0x0900 ;; # 36
			*) # TODO: throw an error
		esac

		case "$family" in
			ipv4) proto=ip prio=1 match_str="ip dsfield $dsfield 0xfc" ;;
			ipv6) proto=ipv6 prio=2 match_str="u16 $hex_match 0x0FC0 at 0" ;;
		esac

		# shellcheck disable=SC2086
#		tc filter add dev "$DEV" parent 1: protocol "$proto" prio "$prio" u32 match $match_str classid "$class_id"
		echo "${pr_offset}*** tc filter add dev \"$DEV\" parent 1: protocol \"$proto\" prio \"$prio\" u32 match $match_str classid \"$class_id\" ***"
	done
}



## MAIN CONSTRUCTORS

setup_hfsc_dir() {
	local max_burst_rate min_burst_dur \
		dir="$1"

	case "$dir" in
		UP)
			DEV="$WAN"
			GAMERATE="$GAMEUP"
			NON_GAME_RATE="$UPRATE" ;;
		DOWN)
			DEV="$LAN"
			GAMERATE="$GAMEDOWN"
			NON_GAME_RATE="$DOWNRATE" ;;
	esac

	# Ensure rates/packetsize are non-zero to avoid errors in calculations
	[ "$NON_GAME_RATE" -gt 0 ] || NON_GAME_RATE=1
	[ "$GAMERATE" -gt 0 ] || GAMERATE=1
	[ "$PACKETSIZE" -gt 0 ] || PACKETSIZE=1

	min_burst_dur=25
	BURST_DUR=$((5*1500*8/NON_GAME_RATE))
	[ $BURST_DUR -ge $min_burst_dur ] ||
		BURST_DUR=$min_burst_dur

	max_burst_rate=$((NON_GAME_RATE*97/100))
	GAME_BURST_RATE=$((GAMERATE*10))
	[ $GAME_BURST_RATE -le $max_burst_rate ] ||
		GAME_BURST_RATE=$max_burst_rate

	if [ "$gameqdisc" = "netem" ]; then
		# Only apply NETEM if this direction is enabled
		case "$NETEM_DIRECTION" in
			both) : ;;
			egress) [ "$dir" = "UP" ] ;;
			ingress) [ "$dir" = "DOWN" ] ;;
			*) false ;; # TODO: Error out
		esac || gameqdisc=pfifo
	fi
}

apply_hfsc_rules() {
	if [ -n "$USE_JSON" ]; then
		init_json_parser "${1:-"$TEST_JSON"}" &&
		parse_json
	else
		apply_rules_no_json
	fi
}

setup_hfsc() {
	local DIR
	for DIR in UP DOWN; do
		setup_hfsc_dir "$DIR" &&
		apply_hfsc_rules "$@" || exit 1
	done
	:
}


# Add a value to use the json implementation
USE_JSON=

if [ -n "$USE_JSON" ]; then
	echo "!!! USING JSON IMPLEMENTATION !!!"
	TEST_JSON="${script_dir}/${1:-"hfsc-rules.json"}"
	. "${script_dir}/json-parser.sh"
else
	echo "!!! USING JSON-LESS IMPLEMENTATION !!!"
	. "${script_dir}/hfsc-no-json.sh"
fi


# Hard-coded config vars

ROOT_QDISC=hfsc
gameqdisc=drr
nongameqdisc=cake
nongameqdiscoptions="besteffort ack-filter"

WAN=eth0
DOWNRATE=1000
UPRATE=1000
GAMEUP=$((UPRATE*15/100+400))
GAMEDOWN=$((DOWNRATE*15/100+400))
COMMON_LINK_PRESETS=ethernet
MAXDEL=24
PFIFOMIN=5
NETEM_DIRECTION=both
netemdelayms=30
netemjitterms=7
netemdist=normal
pktlossp=none
PACKETSIZE=450


##############################
#       Main Logic
##############################

LAN=ifb-$WAN
MTU=1500


case "$ROOT_QDISC" in
	hfsc) ;;
	hybrid|cake|htb)
		error_out "Support for $ROOT_QDISC not implemented!"; exit 1 ;;
    *)
		# Fallback for unsupported ROOT_QDISC
        print_msg -err "Unsupported ROOT_QDISC: '$ROOT_QDISC'. Check /etc/config/qosmate."
        print_msg -warn "Falling back to default HFSC mode with pfifo game qdisc."
        ROOT_QDISC="hfsc"
        gameqdisc="pfifo" # Safe default for fallback
esac

print_msg "Applying $ROOT_QDISC queueing discipline."

# Validate gameqdisc choice (used by HFSC and Hybrid)
case "$ROOT_QDISC" in hfsc|hybrid)
    case "$gameqdisc" in
        drr|qfq|pfifo|bfifo|red|fq_codel|netem) ;; # Supported game qdiscs
        *)
            print_msg -warn "Unsupported gameqdisc '$gameqdisc' selected in config. Using pfifo fallback."
            gameqdisc="pfifo" # Revert to a simple default as fallback
            ;;
    esac
esac

case "$ROOT_QDISC" in
	hfsc) setup_hfsc "$@" ;;
	hybrid) setup_hybrid "$@"
esac
