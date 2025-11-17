#!/bin/sh
# shellcheck disable=SC3043

: "${DEV}" "${PARAMS}" "${nongameqdisc:-}" "${nongameqdiscoptions:-}"
: "${netemdelayms:-}" "${netemjitterms:-}" "${netemdist:-}" "${pktlossp:-}"


## CLASS HELPERS

## QDISC HELPERS

cake_root_qdisc_helper() {
    local link oh ack_filter_egress_val

    get_cake_link_params link oh &&
    append_params "cake" &&

    case "$DIR" in
        UP)
            DEV="$WAN"
            case "$ACK_FILTER_EGRESS" in
                auto) ack_filter_egress_val=$(( (DOWNRATE / UPRATE) >= 15 )) ;;
                *[!0-9]*|'') error_out "Invalid value '$ACK_FILTER_EGRESS' for ACK_FILTER_EGRESS."; return 1 ;;
                *) ack_filter_egress_val=$ACK_FILTER_EGRESS ;;
            esac

            append_params \
                "bandwidth:$UPRATE" \
                "extra:$PRIORITY_QUEUE_EGRESS" \
                "dual-srchost:$HOST_ISOLATION" \
                "rtt:$RTT" \
                "link:$link" \
                "overhead:$oh" \
                "extra:$LINK_COMPENSATION" \
                "extra:$EXTRA_PARAMETERS_EGRESS" \
                "nat:$NAT_EGRESS" \
                "wash:$WASHDSCPUP" \
                "ack-filter:$ack_filter_egress_val"
                ;;
        DOWN)
            DEV="$LAN"
            append_params \
                "bandwidth:$DOWNRATE" \
                "extra:ingress" \
                "autorate-ingress:$AUTORATE_INGRESS" \
                "extra:$PRIORITY_QUEUE_INGRESS" \
                "dual-dsthost:$HOST_ISOLATION" \
                "rtt:$RTT" \
                "link:$link" \
                "overhead:$oh" \
                "extra:$LINK_COMPENSATION" \
                "extra:$EXTRA_PARAMETERS_INGRESS" \
                "nat:$NAT_INGRESS" \
                "wash:$WASHDSCPDOWN"
    esac
}

setup_cake() {
    local DIR DEV

    for DIR in UP DOWN; do
        create_qdisc "cake_root" "1:" "root" || return 1
    done
    :
}

