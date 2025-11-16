#!/bin/sh
# shellcheck disable=SC3043

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

hybrid_cake_qdisc_helper() {
    local link oh
    get_cake_link_params link oh -hybrid
    append_params "cake" || return 1
    case "$DIR" in
        UP)
            append_params \
                "extra:besteffort" \
                "extra:$EXTRA_PARAMETERS_EGRESS" \
                "dual_srchost:$HOST_ISOLATION" \
                "nat:$NAT_EGRESS" \
                "wash:$WASHDSCPUP" ;;
        DOWN)
            append_params \
                "extra:besteffort ingress" \
                "extra:$EXTRA_PARAMETERS_INGRESS" \
                "dual_dsthost:$HOST_ISOLATION" \
                "nat:$NAT_INRESS" \
                "wash:$WASHDSCPDOWN"
    esac
    append_params \
        "rtt:$RTT" \
        "link:$link" \
        "overhead:$oh" \
        "mpu:$MPU" \
        "extra:$ETHER_VLAN_KEYWORD" \
        "extra:$LINK_COMPENSATION"
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

setup_hybrid() {
    local DIR directions="UP DOWN" \
        DEV NON_GAME_RATE GAMERATE GAME_BURST_RATE BURST_DUR

    for DIR in $directions; do
        set_hfsc_vars "$DIR" &&
        apply_rules_hybrid || return 1
    done
    :
}

[ -f "$QOSMATE_LIB_hfsc" ] || { error_out "Can not find '$QOSMATE_LIB_hfsc'"; return 1; }

# shellcheck source=hfsc-qdisc-lib.sh
. "$QOSMATE_LIB_hfsc"
