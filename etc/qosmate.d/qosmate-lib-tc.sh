#!/bin/sh
# shellcheck disable=SC3043,SC3060

: "$MTU" "${gameqdisc:-}"

# Print tc commands to console rather than running them - for testing/debugging
tc() {
    printf '%s\n' "tc $*" >&2
}

## COMMON PARAM HELPERS

unexp_qdisc() { error_out "Unexpected qdisc '$2' for tc object '$1'"; }

# NOTE:
# Syntax to append params: 'append_params [CLASS|QDISC] "key:val" ["key2:val2" "key3:val3" ... ]'

# All passed keys must be explicitly supported in append_param_[CLASS|QDISC],
#    otherwise param helper will error out
# To allow param with empty value, prepend 'opt:', eg 'opt:key:val'
#    otherwise param helper will error out on empty value
# To append arbitrary string, use 'extra:val', or 'opt:extra:val' when value may be empty

append_params() {
    local param_str key val opt me="append_params" \
        obj_type="$1"
    shift

    case "$obj_type" in CLASS|QDISC) ;; *)
        error_out "$me: invalid tc object type '$obj_type'"; return 1
    esac

    for param_str in "$@"; do
        opt=
        case "$param_str" in "opt:"*)
            opt=1
            param_str="${param_str#"opt:"}" ;;
        esac
        key="${param_str%%:*}"
        val="${param_str#"$key"}"
        val="${val#":"}"

        [ -n "$key" ] || { error_out "$me: empty key in param string '$param_str'"; return 1; }

        # params must have value except when key starts with 'opt:'
        if [ -z "$val" ]; then
            [ -n "$opt" ] || { error_out "$me: param '$key' must have a value."; return 1; }
            return 0
        fi

        # shellcheck disable=SC2086
        append_param_${obj_type} "$key" "$val" || { error_out "$me: unexpected $obj_type param '$key'"; return 1; }
    done
    :
}

append_param_CLASS() {
    local param='' \
        key="$1" val="$2"

    case "$key" in
        qdisc)
            case "$val" in
                hfsc|htb|drr|qfq) ;;
                *) unexp_qdisc CLASS "$val"; return 1
            esac ;;
        rt|ls|ul|sc|burst|cburst|weight|quantum|prio) param="$key" ;;
        extra) ;;
        rate|ceil) param="$key" val="${val:+"${val}kbit"}" ;;
        *) return 1
    esac

    CLASS_PARAMS="${CLASS_PARAMS}${CLASS_PARAMS:+ }${param}${param:+ }${val}"
}

append_param_QDISC() {
    local param=''  \
        key="$1" val="$2"

    case "$key" in
        qdisc)
            case "$val" in
                root|hfsc|cake|htb|drr|qfq|pfifo|bfifo|red|netem|fq_codel) ;;
                *) unexp_qdisc QDISC "$val"; return 1
            esac ;;
        burst|min|max|avpkt|\
            overhead|limit|memory_limit|interval|target|quantum|probability|mpu|distribution) param="$key" ;;
        bandwidth) param="$key" val="${val:+"${val}kbit"}" ;;
        rtt|delay|jitter) val="${val:+"${val}ms"}" ;;
        extra|pkt_loss|link) ;;
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
        *) return 1
    esac

    QDISC_PARAMS="${QDISC_PARAMS}${QDISC_PARAMS:+ }${param}${param:+ }${val}"
}

# Get tc stab parameters for HFSC/HTB/Hybrid
append_tc_overhead_params() {
    local params=''
    # Detect ATM-based presets
    case "$COMMON_LINK_PRESETS" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            params="stab mtu 2047 tsize 512 mpu 68 overhead ${OVERHEAD:-44} linklayer atm" ;;
        docsis)
            params="stab overhead ${OVERHEAD:-25} linklayer ethernet" ;;
        cake-ethernet)
            params="stab overhead ${OVERHEAD:-38} linklayer ethernet" ;;
        raw)
            params="stab overhead ${OVERHEAD:-0} linklayer ethernet" ;;
        *)
            params="stab overhead ${OVERHEAD:-40} linklayer ethernet" ;;
    esac
    append_params QDISC "extra:$params" || return 1
}

# Generate and append CAKE parameters based on common link settings
# $1 = "-hybrid" to force manual overhead for consistency with HFSC
append_cake_link_params() {
    local oh="$OVERHEAD" link="$COMMON_LINK_PRESETS"

    # Determine link keyword and default overhead
    case "$link" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            [ "$1" = "-hybrid" ] && link="atm"
            : "${oh:=44}"
            ;;
        docsis)        : "${oh:=25}" ;;
        raw)           : "${oh:=0}"  ;;
        cake-ethernet) link="ethernet"; : "${oh:=38}" ; [ "$1" = "-hybrid" ] || oh="" ;;
        ethernet|*)    link="ethernet"; : "${oh:=40}" ;;
    esac
    append_params QDISC "link:$link" "overhead:$oh" || return 1
}


## TC OBJECTS AND FILTERS

create_class() { create_tc_obj "$1" CLASS "$2" "$3"; }
create_qdisc() { create_tc_obj "$1" QDISC "$2" "$3"; }

create_tc_obj() {
    unexp_helper() { error_out "Unexpected $tc_obj_type helper '$helper_short'."; }
    params_confusion() { error_out "TC object is $tc_obj_type but $1 params are set: '$2'"; }
    inval_obj() { error_out "create_tc_obj: Invalid object id '$tc_obj_id'"; }
    inval_parent() { error_out "create_tc_obj: Invalid parent id '$tc_parent_id' for object '$tc_obj_id'"; }

    local helper_short helper_args  QDISC_PARAMS='' CLASS_PARAMS='' \
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

    # shellcheck disable=SC2086
    case "$tc_obj_type" in
        QDISC)
            case "$helper_short" in
                hfsc_root|hfsc_game|hfsc_non_game|hfsc_cake|hfsc_fq_codel|red|\
                hybrid_cake|\
                htb_root|htb_fq_codel|\
                cake_root)
                    ${helper_short}_qdisc_helper ${helper_args} ;;
                *) unexp_helper; false
            esac || return 1

            [ -z "$CLASS_PARAMS" ] || { params_confusion CLASS "$CLASS_PARAMS"; return 1; }

            tc qdisc add dev "$DEV" ${tc_parent_id:+ parent "${tc_parent_id}"} ${tc_obj_id:+ handle "${tc_obj_id}"} \
                ${QDISC_PARAMS} ;;
        CLASS)
            case "$helper_short" in
                hfsc_main_link|hfsc_lan|hfsc_tin|game_drr_qfq|\
                hybrid_tin|\
                htb_main|htb_tin)
                    ${helper_short}_class_helper ${helper_args} ;;
                *) unexp_helper; false
            esac || return 1

            [ -z "$QDISC_PARAMS" ] || { params_confusion QDISC "$QDISC_PARAMS"; return 1; }

            tc class add dev "$DEV" parent "${tc_parent_id}" classid "${tc_obj_id}" ${CLASS_PARAMS} ;;
        *) false
    esac ||
        {
            error_out "Failed to create tc object with type '$tc_obj_type'." \
                "dev:'$DEV', parent:'$tc_parent_id', obj: '$tc_obj_id', params: '$QDISC_PARAMS'"
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
        tc filter add dev "$DEV" parent 1: protocol "$proto" prio "$prio" u32 match $match_str classid "$class_id" || {
            error_out "Failed to create tc filter." \
                "DEV:'$DEV', proto:'$proto', prio:'$prio', match:'$match_str', class:'$class_id'"
            return 1
        }
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
    command -v tc >/dev/null || {
        error_out "'tc' command not found."
        return 1
    }

    LAN=ifb-$WAN
    MTU=1500

    # Ensure rates/packetsize are non-zero to avoid errors in calculations
    local var val
    for var in UPRATE DOWNRATE GAMEUP GAMEDOWN PACKETSIZE; do
        eval "val=\"\${$var}\""
        case "$val" in
            ''|*[!0-9]*) false ;;
            *) [ "$val" -gt 0 ]
        esac || val=1
        eval "$var=\"\$val\""
    done

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
        hfsc) lib_file="$QOSMATE_LIB_HFSC_HYBRID" setup_cmd=setup_hfsc ;;
        hybrid) lib_file="$QOSMATE_LIB_HFSC_HYBRID" setup_cmd=setup_hybrid ;;
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
        [ "$gameqdisc" = "red" ] && {
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
