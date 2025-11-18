#!/bin/sh
# shellcheck disable=SC3043

: "${DEV}" "${PARAMS}" "${nongameqdisc:-}" "${nongameqdiscoptions:-}"
: "${netemdelayms:-}" "${netemjitterms:-}" "${netemdist:-}" "${pktlossp:-}"


## CLASS HELPERS

hfsc_main_link_class_helper() {
    append_params "hfsc" &&
    append_curve_params "linkshare" "steady_rate:$NON_GAME_RATE" &&
    append_curve_params "upperlimit" "steady_rate:$NON_GAME_RATE"
}

hfsc_lan_class_helper() {
    append_params "hfsc" &&
    append_curve_params "linkshare" "burst_rate:50000" "burst_dur:$BURST_DUR" "steady_rate:10000"
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

    append_params "hfsc" &&
    append_curve_params "linkshare" \
        "steady_rate:$((base_steady_rate*steady_percent/100))" \
        "burst_rate:$((base_burst_rate*burst_percent/100))" \
        "burst_dur:$BURST_DUR"
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

    append_params "hfsc" &&
    append_curve_params "linkshare" \
        "steady_rate:$((base_steady_rate*steady_percent/100))" \
        "burst_rate:$((base_burst_rate*burst_percent/100))" \
        "burst_dur:$BURST_DUR"
}

game_drr_qfq_class_helper() {
    [ -n "$1" ] || : # TODO: throw error
    local param
    case "$gameqdisc" in
        drr) param=quantum ;;
        qfq) param=weight ;;
        *) # TODO: throw error
    esac

    append_params \
        "${gameqdisc}" \
        "${param}:${1}"
}


## QDISC HELPERS

hfsc_root_qdisc_helper() {
    append_params "root" &&
    append_tc_overhead_params oh_params &&
    append_params "hfsc" "extra:default 13"
}

hfsc_non_game_qdisc_helper() {
    case "$nongameqdisc" in
        cake) hfsc_cake_qdisc_helper ;;
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

hfsc_cake_qdisc_helper() {
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

hybrid_cake_qdisc_helper() {
    append_params "cake" || return 1
    case "$DIR" in
        UP)
            append_params \
                "extra:besteffort" \
                "extra:$EXTRA_PARAMETERS_EGRESS" \
                "dual-srchost:$HOST_ISOLATION" \
                "nat:$NAT_EGRESS" \
                "wash:$WASHDSCPUP" ;;
        DOWN)
            append_params \
                "extra:besteffort ingress" \
                "extra:$EXTRA_PARAMETERS_INGRESS" \
                "dual-dsthost:$HOST_ISOLATION" \
                "nat:$NAT_INGRESS" \
                "wash:$WASHDSCPDOWN"
    esac
    append_params \
        "rtt:$RTT" &&
    append_cake_link_params -hybrid &&
    append_params \
        "mpu:$MPU" \
        "extra:$ETHER_VLAN_KEYWORD" \
        "extra:$LINK_COMPENSATION"
}


# Sets DEV NON_GAME_RATE GAMERATE GAME_BURST_RATE BURST_DUR
set_hfsc_vars() {
    local DIR="$1" \
        max_burst_rate min_burst_dur

    # Validate gameqdisc choice (used by HFSC and Hybrid)
    case "$gameqdisc" in
        drr|qfq|pfifo|bfifo|red|fq_codel|netem) ;; # Supported game qdiscs
        *)
            print_msg -warn "Unsupported gameqdisc '$gameqdisc' selected in config. Using pfifo fallback."
            gameqdisc="pfifo" ;; # Revert to a simple default as fallback
    esac

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

    # Ensure rates/packetsize are non-zero to avoid errors in calculations
    [ "$NON_GAME_RATE" -gt 0 ] || NON_GAME_RATE=1
    [ "$GAMERATE" -gt 0 ] || GAMERATE=1
    [ "$PACKETSIZE" -gt 0 ] || PACKETSIZE=1

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
            *) false ;; # TODO: Error out
        esac || gameqdisc=pfifo
    fi

}

apply_rules_hfsc() {
    create_qdisc "hfsc_root" "1:" "root" &&

        case "$DIR" in DOWN)
            create_class "hfsc_lan" "1:2" "1:"
        esac &&

        create_class "hfsc_main_link" "1:1" "1:" &&

            create_class "hfsc_tin fast" "1:12" "1:" &&
                create_qdisc "hfsc_non_game" "" "1:12" &&
                for family in ipv4 ipv6; do
                    create_filters "CS4 AF41 AF42" "1:12" "$family" || return 1
                done &&

            create_class "hfsc_tin normal" "1:13" "1:" &&
                create_qdisc "hfsc_non_game" "" "1:13" &&
                for family in ipv4 ipv6; do
                    create_filters "CS0" "1:13" "$family" || return 1
                done &&

            create_class "hfsc_tin lowprio" "1:14" "1:" &&
                create_qdisc "hfsc_non_game" "" "1:14" &&
                for family in ipv4 ipv6; do
                    create_filters "CS2 AF11" "1:14" "$family" || return 1
                done &&

            create_class "hfsc_tin bulk" "1:15" "1:" &&
                create_qdisc "hfsc_non_game" "" "1:15" &&
                for family in ipv4 ipv6; do
                    create_filters "CS1" "1:15" "$family" || return 1
                done &&

            create_class "hfsc_tin realtime" "1:11" "1:" &&
                for family in ipv4 ipv6; do
                    create_filters "EF CS5 CS6 CS7" "1:11" "$family" || return 1
                done &&

                create_qdisc "hfsc_game" "10:" "1:11" &&
                    case "$gameqdisc" in drr|qfq)
                        create_class "game_drr_qfq 8000" "10:1" "10:" &&
                            create_qdisc "red" "11:" "10:1" &&
                        create_class "game_drr_qfq 4000" "10:2" "10:" &&
                            create_qdisc "red" "12:" "10:2" &&
                        create_class "game_drr_qfq 1000" "10:3" "10:" &&
                            create_qdisc "red" "13:" "10:3" ;;
                    esac
}

apply_rules_hybrid() {
    create_qdisc "hfsc_root" "1:" "root" &&

        case "$DIR" in DOWN)
            create_class "hfsc_lan" "1:2" "1:"
        esac &&

        create_class "hfsc_main_link" "1:1" "1:" &&

            create_class "hybrid_tin normal" "1:13" "1:1" &&
                create_qdisc "hybrid_cake" "13:" "1:13" &&
                create_filters "CS0" "1:13" "ipv6" || return 1

            create_class "hybrid_tin bulk" "1:15" "1:1" &&
                create_qdisc "fq_codel -mem-coeff 1" "15:" "1:15" &&
                for family in ipv4 ipv6; do
                    create_filters "CS1" "1:15" "$family" || return 1
                done &&

            create_class "hfsc_tin realtime" "1:11" "1:1" &&
                for family in ipv4 ipv6; do
                    create_filters "EF CS5 CS6 CS7" "1:11" "$family" || return 1
                done &&

                create_qdisc "hfsc_game" "10:" "1:11" &&
                    case "$gameqdisc" in drr|qfq)
                        create_class "game_drr_qfq 8000" "10:1" "10:" &&
                            create_qdisc "red" "11:" "10:1" &&
                        create_class "game_drr_qfq 4000" "10:2" "10:" &&
                            create_qdisc "red" "12:" "10:2" &&
                        create_class "game_drr_qfq 1000" "10:3" "10:" &&
                            create_qdisc "red" "13:" "10:3"
                    esac
}


setup_hfsc_hybrid() {
    local DIR \
        DEV NON_GAME_RATE GAMERATE GAME_BURST_RATE BURST_DUR

    for DIR in UP DOWN; do
        set_hfsc_vars "$DIR" &&
        case "$1" in
            hfsc) apply_rules_hfsc ;;
            hybrid) apply_rules_hybrid ;;
            *) error_out "setup_hfsc_hybrid: unexpected input '$1'"; false
        esac || return 1
    done
    :
}

setup_hfsc() {
    setup_hfsc_hybrid hfsc
}

setup_hybrid() {
    setup_hfsc_hybrid hybrid
}
