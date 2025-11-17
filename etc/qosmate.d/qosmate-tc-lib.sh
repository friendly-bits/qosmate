#!/bin/sh
# shellcheck disable=SC3043,SC3060

## COMMON PARAM HELPERS

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
        dual-srchost|dual-dsthost|nat|wash|ack-filter|autorate-ingress)
            # Special treatment for cake params
            local prefix='' \
                selector="$val"
            [ "$selector" = 1 ] ||
                case "$key" in
                    wash|nat) prefix='no' ;;
                    ack-filter) prefix='no-' ;;
                    *) return 0 ;;
                esac
            val="${prefix}${key}" ;;
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
            steady_rate|burst_rate) [ "$val" -gt 0 ] || val=1
        esac &&
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

# Get CAKE parameters from common link settings
# $3 = "-hybrid" to force manual overhead for consistency with HFSC
get_cake_link_params() {
    local _oh="$OVERHEAD" _link="$COMMON_LINK_PRESETS"

    # Determine link keyword and default overhead
    case "$_link" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            [ "$3" = "-hybrid" ] && _link="atm"
            : "${_oh:=44}"
            ;;
        docsis)        : "${_oh:=25}" ;;
        raw)           : "${_oh:=0}"  ;;
        cake-ethernet) _link="ethernet"; : "${_oh:=38}" ; [ "$3" = "-hybrid" ] || _oh="" ;;
        ethernet|*)    _link="ethernet"; : "${_oh:=40}" ;;
    esac
    eval "$1=\"\$_link\" $2=\"\$_oh\""
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


## TC OBJECTS AND FILTERS

create_class() { create_tc_obj "$1" CLASS "$2" "$3"; }
create_qdisc() { create_tc_obj "$1" QDISC "$2" "$3"; }

create_tc_obj() {
    inval_obj() { error_out "create_tc_obj: Invalid object id '$tc_obj_id'"; }
    inval_parent() { error_out "create_tc_obj: Invalid parent id '$tc_parent_id' for object '$tc_obj_id'"; }

    local helper_short helper_args unexp_func='' PARAMS='' \
        helper_str="$1" tc_obj_type="$2" tc_obj_id="$3" tc_parent_id="$4"

    case "$tc_obj_id" in
        *![0-9:]*) inval_obj; return 1 ;;
        ''|*[0-9]:*) ;;
        *) inval_obj; return 1
    esac

    case "$tc_parent_id" in
        root) tc_parent_id='' ;;
        *![0-9:]*) inval_parent; return 1 ;;
        *[0-9]:*) ;;
        *) inval_parent; return 1
    esac

    helper_short="${helper_str%% *}"
    helper_args="${helper_str#"$helper_short"}"

    case "$tc_obj_type" in
        QDISC)
            case "$helper_short" in
                hfsc_root|hfsc_game|hfsc_non_game|\
                hybrid_cake|\
                cake_root|cake|fq_codel|red)
                    ${helper_short}_qdisc_helper ${helper_args} ;;
                *) unexp_func=1; false
            esac &&
            echo "tc qdisc add dev \"$DEV\"${tc_parent_id:+ parent }${tc_parent_id}${tc_obj_id:+ handle }${tc_obj_id} ${PARAMS}" ;;
        CLASS)
            case "$helper_short" in
                hfsc_lan|hfsc_main_link|hfsc_tin|\
                hybrid_tin|\
                game_drr_qfq)
                    ${helper_short}_class_helper ${helper_args} ;;
                *) unexp_func=1; false
            esac &&
            echo "tc class add dev \"$DEV\" parent ${tc_parent_id} classid ${tc_obj_id} ${PARAMS}" ;;
        *) false
    esac ||
        {
            [ -n "$unexp_func" ] && error_out "Unexpected helper '$helper_short'."
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
        echo "    tc filter add dev \"$DEV\" parent 1: protocol \"$proto\" prio \"$prio\" u32 match $match_str classid \"$class_id\""
    done
}


##############################
#       Main Logic
##############################

setup_tc() {
    try_setup_tc || {
        error_out "Failed to set up $ROOT_QDISC root qdisc."
        # *** Any additional error handling needed? ***
        exit 1
    }
}

try_setup_tc() {
    LAN=ifb-$WAN
    MTU=1500

    command -v tc >/dev/null || {
        error_out "'tc' command not found."
        return 1
    }

    ## Set up ctinfo downstream shaping

    print_msg "" "Setting up ctinfo downstream shaping..."

    # Set up ingress handle for WAN interface
    tc qdisc add dev "$WAN" handle ffff: ingress &&

    # Create IFB interface
    ip link add name "$LAN" type ifb &&
    ip link set "$LAN" up &&

    # Redirect ingress traffic from WAN to IFB and restore DSCP from conntrack
    tc filter add dev "$WAN" parent ffff: protocol all matchall action ctinfo dscp 63 128 mirred \
        egress redirect dev "$LAN" || return 1

    print_msg "Applying $ROOT_QDISC queueing discipline."

    local lib_file setup_cmd
	case "$ROOT_QDISC" in
        hfsc) lib_file="$QOSMATE_LIB_HFSC" setup_cmd=setup_hfsc ;;
        hybrid) lib_file="$QOSMATE_LIB_HYBRID" setup_cmd=setup_hybrid ;;
        cake) lib_file="$QOSMATE_LIB_CAKE" setup_cmd=setup_cake ;;
        htb) lib_file="$QOSMATE_LIB_HTB" setup_cmd=setup_htb
	esac

    [ -f "$lib_file" ] || { error_out "Can not find $lib_file"; return 1; }
    # shellcheck source=/dev/null
    . "$lib_file"
	$setup_cmd || return 1

    ## Set up ctinfo for upstream (egress) - SFO compatibility
    # Restore DSCP values from conntrack for egress packets
    # Only needed when Software Flow Offloading is active
    if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ]; then
        print_msg "" "Software Flow Offloading detected - enabling SFO compatibility mode..."
        tc filter add dev "$WAN" parent 1: protocol all matchall action ctinfo dscp 63 128 continue
    else
        print_msg "" "Software Flow Offloading disabled - dynamic rules fully functional..."
    fi

    print_msg "DONE!"

    # Conditional output of tc status
    case "$ROOT_QDISC" in hfsc|hybrid)
        [ "$gameqdisc" != "red" ] || {
            print_msg "" \
                "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc, but things are working!"
            false
        }
    esac && {
        print_msg "--- Egress ($WAN) ---"
        tc -s qdisc show dev "$WAN"
        print_msg "--- Ingress ($LAN) ---"
        tc -s qdisc show dev "$LAN"
    }

    :
}

:
