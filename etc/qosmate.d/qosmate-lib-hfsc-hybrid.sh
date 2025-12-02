#!/bin/sh
# shellcheck disable=SC3043

: "${DEV}" "${nongameqdisc:-}" "${nongameqdiscoptions:-}"
: "${netemdelayms:-}" "${netemjitterms:-}" "${netemdist:-}" "${pktlossp:-}"


## CLASS HELPERS

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
    append_params CLASS "${curve}:${params_str}" || return 1
}

hfsc_main_link_class_helper() {
    append_params CLASS "qdisc:hfsc" &&
    append_curve_params "linkshare" "steady_rate:$NON_GAME_RATE" &&
    append_curve_params "upperlimit" "steady_rate:$NON_GAME_RATE" || return 1
}

hfsc_lan_class_helper() {
    append_params CLASS "qdisc:hfsc" &&
    append_curve_params "linkshare" "burst_rate:50000" "burst_dur:$BURST_DUR" "steady_rate:10000" || return 1
}

hfsc_tin_class_helper() {
    local base_steady_rate="$NON_GAME_RATE" \
        steady_percent \
        base_burst_rate burst_percent

    case "$1" in
        realtime)
            steady_percent=100
            base_burst_rate="$GAME_BURST_RATE"
            burst_percent=100 ;;
        fast)
            steady_percent=30
            base_burst_rate="$NON_GAME_RATE"
            burst_percent=70 ;;
        normal)
            steady_percent=45
            base_burst_rate="$NON_GAME_RATE"
            burst_percent=20 ;;
        lowprio)
            steady_percent=15
            base_burst_rate="$NON_GAME_RATE"
            burst_percent=7 ;;
        bulk)
            steady_percent=15
            base_burst_rate="$NON_GAME_RATE"
            burst_percent=3 ;;
        *) # TODO: throw error
    esac

    append_params CLASS "qdisc:hfsc" &&
    append_curve_params "linkshare" \
        "steady_rate:$((base_steady_rate*steady_percent/100))" \
        "burst_rate:$((base_burst_rate*burst_percent/100))" \
        "burst_dur:$BURST_DUR" || return 1
}

hybrid_tin_class_helper() {
    local \
        base_steady_rate steady_percent \
        base_burst_rate burst_percent \
        normal_rate

    case "$1" in
        normal)
            normal_rate=$((NON_GAME_RATE - GAMERATE))
            [ $normal_rate -gt 0 ] || normal_rate=1
            base_steady_rate=$normal_rate
            steady_percent=100
            base_burst_rate=$normal_rate
            burst_percent=100
            ;;
        bulk)
            base_steady_rate=$NON_GAME_RATE
            steady_percent=10
            base_burst_rate=$NON_GAME_RATE
            burst_percent=3 ;;
        *) # TODO: throw error
    esac

    append_params CLASS "qdisc:hfsc" &&
    append_curve_params "linkshare" \
        "steady_rate:$((base_steady_rate*steady_percent/100))" \
        "burst_rate:$((base_burst_rate*burst_percent/100))" \
        "burst_dur:$BURST_DUR" || return 1
}

game_drr_qfq_class_helper() {
    [ -n "$1" ] || : # TODO: throw error
    local param
    case "$gameqdisc" in
        drr) param=quantum ;;
        qfq) param=weight ;;
        *) # TODO: throw error
    esac

    append_params CLASS \
        "qdisc:${gameqdisc}" \
        "${param}:${1}" || return 1
}


## QDISC HELPERS

hfsc_root_qdisc_helper() {
    append_params QDISC "qdisc:root" &&
    append_tc_overhead_params &&
    append_params QDISC "qdisc:hfsc" "STRING:default 13" || return 1
}

hfsc_non_game_qdisc_helper() {
    case "$nongameqdisc" in
        cake) hfsc_cake_qdisc_helper ;;
        fq_codel) hfsc_fq_codel_qdisc_helper ;;
        *) error_out "Unexpected non-game qdisc '$nongameqdisc'."; false
    esac || return 1
}

hfsc_game_qdisc_helper() {
    case "$gameqdisc" in
        drr|qfq) append_params QDISC "qdisc:$gameqdisc" ;;
        pfifo) append_params QDISC "qdisc:pfifo" "limit:$((PFIFOMIN+MAXDEL*NON_GAME_RATE/8/PACKETSIZE))" ;;
        bfifo) append_params QDISC "qdisc:bfifo" "limit:$((MAXDEL * GAMERATE / 8))" ;;
        red) red_qdisc_helper ;;
        fq_codel) hfsc_fq_codel_qdisc_helper ;;
        netem) netem_qdisc_helper ;;
        *) error_out "Unexpected game qdisc '$gameqdisc'."; false ;;
    esac || return 1
}

hfsc_cake_qdisc_helper() {
    append_params QDISC \
        "qdisc:cake" \
        "OPT:STRING:$nongameqdiscoptions" || return 1
}

# shellcheck disable=SC2120
hfsc_fq_codel_qdisc_helper() {
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
        error_out "hfsc_fq_codel_qdisc_helper: invalid args '$*'."
        return 1
    }

    append_params QDISC \
        "qdisc:fq_codel" \
        "memory_limit:$(( NON_GAME_RATE*mem_coeff*100/8 ))" \
        "interval:$(( 100 + 2*1500*8/NON_GAME_RATE ))" \
        "target:$(( 540*8/NON_GAME_RATE + 4 ))" \
        "quantum:$(( MTU * 2 ))" || return 1
}

netem_qdisc_helper() {
    local delay_str='' \
		delay="$netemdelayms" \
        pkt_loss=''

	[ "$delay" -gt 0 ] || delay=0

    # If jitter is set but delay is 0, force minimum delay of 1ms
    if [ "$netemjitterms" -gt 0 ] && [ "$delay" -le 0 ]; then
        delay=1
    fi

	delay_str="delay ${delay}ms"

    # Add delay parameter if set (either original or forced minimum)
    if [ "$delay" -gt 0 ] && [ "$netemjitterms" -gt 0 ]; then
		[ -n "$netemdist" ] || netemdist="normal"
		delay_str="${delay_str} ${netemjitterms}ms distribution ${netemdist}"
    fi

    # Add packet loss if set
    pkt_loss=
    case "$pktlossp" in
        none|'') ;;
        *) pkt_loss="$pktlossp"
    esac

    append_params QDISC \
        "qdisc:netem" \
        "limit:$(( 4 + 9*NON_GAME_RATE/8/500 ))" \
        "STRING:$delay_str" \
        "OPT:pkt_loss:$pkt_loss" || return 1
}

red_qdisc_helper() {
    # Calculate redmin and redmax based on gamerate and MAXDEL
    local redmin=$((GAMERATE * MAXDEL / 3 / 8)) \
        redmax=$((GAMERATE * MAXDEL / 8))

    # Calculate redburst: (min + min + max)/(3 * avpkt) as per RED documentation
    local redburst=$(( (redmin + redmin + redmax) / (3 * 500) ))
    [ $redburst -ge 2 ] || redburst=2

    append_params QDISC \
        "qdisc:red" \
        "limit:150000" \
        "min:$redmin" \
        "max:$redmax" \
        "avpkt:500" \
        "bandwidth:$NON_GAME_RATE" \
        "burst:$redburst" \
        "probability:1.0" || return 1
}

hybrid_cake_qdisc_helper() {
    append_params QDISC "qdisc:cake" || return 1
    case "$DIR" in
        UP)
            append_params QDISC \
                "STRING:besteffort" \
                "OPT:STRING:$EXTRA_PARAMETERS_EGRESS" \
                "dual-srchost:$HOST_ISOLATION" \
                "nat:$NAT_EGRESS" \
                "wash:$WASHDSCPUP" ;;
        DOWN)
            append_params QDISC \
                "STRING:besteffort ingress" \
                "OPT:STRING:$EXTRA_PARAMETERS_INGRESS" \
                "dual-dsthost:$HOST_ISOLATION" \
                "nat:$NAT_INGRESS" \
                "wash:$WASHDSCPDOWN"
    esac &&
    append_params QDISC \
        "OPT:rtt:$RTT" &&
    append_cake_link_params -hybrid &&
    append_params QDISC \
        "OPT:mpu:$MPU" \
        "OPT:STRING:$ETHER_VLAN_KEYWORD" \
        "OPT:STRING:$LINK_COMPENSATION" || return 1
}


apply_rules_hfsc() {
    create_qdisc "hfsc_root" "1:" "root" &&

        case "$DIR" in 'DOWN')
            # Router traffic class (only on LAN/IFB)
            create_class "hfsc_lan" "1:2" "1:" || return 1
        esac &&

        # Main link
        create_class "hfsc_main_link" "1:1" "1:" &&

            # Attach non-game qdiscs

            # Fast
            create_class "hfsc_tin fast" "1:12" "1:1" &&
                create_qdisc "hfsc_non_game" "" "1:12" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "CS4 AF41 AF42" "1:12" "$family" || return 1
                done

            # Normal (Default)
            create_class "hfsc_tin normal" "1:13" "1:1" &&
                create_qdisc "hfsc_non_game" "" "1:13" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "CS0" "1:13" "$family" || return 1
                done

            # Low Prio
            create_class "hfsc_tin lowprio" "1:14" "1:1" &&
                create_qdisc "hfsc_non_game" "" "1:14" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "CS2 AF11" "1:14" "$family" || return 1
                done

            # Bulk
            create_class "hfsc_tin bulk" "1:15" "1:1" &&
                create_qdisc "hfsc_non_game" "" "1:15" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "CS1" "1:15" "$family" || return 1
                done

            # Game qdisc - Realtime
            create_class "hfsc_tin realtime" "1:11" "1:1" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "EF CS5 CS6 CS7" "1:11" "$family" || return 1
                done
                create_qdisc "hfsc_game" "10:" "1:11" &&
                    case "$gameqdisc" in 'drr'|'qfq')
                        create_class "game_drr_qfq 8000" "10:1" "10:" &&
                            create_qdisc "red" "11:" "10:1" &&
                        create_class "game_drr_qfq 4000" "10:2" "10:" &&
                            create_qdisc "red" "12:" "10:2" &&
                        create_class "game_drr_qfq 1000" "10:3" "10:" &&
                            create_qdisc "red" "13:" "10:3" || return 1
                    esac ||
    return 1
}

apply_rules_hybrid() {
    create_qdisc "hfsc_root" "1:" "root" &&

        case "$DIR" in 'DOWN')
            # Router traffic class (only on LAN/IFB)
            create_class "hfsc_lan" "1:2" "1:" || return 1
        esac &&

        # Main link
        create_class "hfsc_main_link" "1:1" "1:" &&

            # CAKE (most traffic - default)
            create_class "hybrid_tin normal" "1:13" "1:1" &&
                create_qdisc "hybrid_cake" "13:" "1:13" &&
                create_filters "1:" "CS0" "1:13" "ipv6" &&

            # Bulk traffic (HFSC LS + fq_codel)
            create_class "hybrid_tin bulk" "1:15" "1:1" &&
                create_qdisc "hfsc_fq_codel -mem-coeff 1" "15:" "1:15" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "CS1" "1:15" "$family" || return 1
                done

            # High priority realtime (HFSC RT + gameqdisc)
            create_class "hfsc_tin realtime" "1:11" "1:1" || return 1
                for family in ipv4 ipv6; do
                    create_filters "1:" "EF CS5 CS6 CS7" "1:11" "$family" || return 1
                done
                create_qdisc "hfsc_game" "10:" "1:11" &&
                    case "$gameqdisc" in 'drr'|'qfq')
                        create_class "game_drr_qfq 8000" "10:1" "10:" &&
                            create_qdisc "red" "11:" "10:1" &&
                        create_class "game_drr_qfq 4000" "10:2" "10:" &&
                            create_qdisc "red" "12:" "10:2" &&
                        create_class "game_drr_qfq 1000" "10:3" "10:" &&
                            create_qdisc "red" "13:" "10:3" || return 1
                    esac ||
    return 1
}


setup_hfsc_hybrid() {
    local DIR \
        DEV \
        NON_GAME_RATE GAMERATE GAME_BURST_RATE BURST_DUR \
        max_burst_rate min_burst_dur \
        gqd_err

    # Validate gameqdisc choice (used by HFSC and Hybrid)
    case "$gameqdisc" in
        drr|qfq|pfifo|bfifo|red|fq_codel) : ;; # Supported game qdiscs
        netem)
            case "$NETEM_DIRECTION" in
                both|egress|ingress) : ;;
                *) gqd_err="Unexpected netem direction '$NETEM_DIRECTION'"; false ;;
            esac ;;
        *)
            gqd_err="Unsupported gameqdisc '$gameqdisc'"; false ;;
    esac || {
        print_msg -warn "$gqd_err selected in config. Reverting to pfifo game qdisc."
        gameqdisc=pfifo
    }

    # Ensure supported non-game qdisc for hfsc
    [ "$1" != hfsc ] ||
        case "$nongameqdisc" in
            cake|fq_codel) ;;
            *)
                error_out "Unsupported qdisc for non-game traffic: '$nongameqdisc'." \
                    "Supported qdiscs are: cake, fq_codel."
                return 1
        esac


    for DIR in UP DOWN; do
        case "$DIR" in
            UP)
                DEV="$WAN"
                GAMERATE="$GAMEUP"
                NON_GAME_RATE="$UPRATE" ;;
            DOWN)
                DEV="$LAN"
                GAMERATE="$GAMEDOWN"
                NON_GAME_RATE="$DOWNRATE" ;;
            *) error_out "Unexpected direction '$DIR'"; return 1
        esac

        min_burst_dur=25
        BURST_DUR=$((5*1500*8/NON_GAME_RATE))
        [ "$BURST_DUR" -ge $min_burst_dur ] ||
            BURST_DUR=$min_burst_dur

        max_burst_rate=$((NON_GAME_RATE*97/100))
        GAME_BURST_RATE=$((GAMERATE*10))
        [ "$GAME_BURST_RATE" -le $max_burst_rate ] ||
            GAME_BURST_RATE=$max_burst_rate

        if [ "$gameqdisc" = "netem" ]; then
            # Only apply NETEM if this direction is enabled
            case "$NETEM_DIRECTION" in
                both) : ;;
                egress) [ "$DIR" = "UP" ] ;;
                ingress) [ "$DIR" = "DOWN" ] ;;
            esac || gameqdisc=pfifo
        fi

        case "$1" in
            hfsc) apply_rules_hfsc ;;
            hybrid) apply_rules_hybrid ;;
            *) error_out "setup_hfsc_hybrid: unexpected input '$1'"; false
        esac || return 1
    done
    :
}

setup_hfsc() {
    setup_hfsc_hybrid hfsc || return 1
}

setup_hybrid() {
    setup_hfsc_hybrid hybrid || return 1
}
