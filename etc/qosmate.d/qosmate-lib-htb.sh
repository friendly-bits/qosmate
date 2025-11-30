#!/bin/sh
# shellcheck disable=SC3043

: "${DEV}"

## Param helpers

# Helper functions for HTB dynamic parameter calculation
# Calculate optimal HTB quantum based on rate
calculate_htb_quantum() {
    local ch_quantum min_quantum \
        ch_out_var="$1" \
        rate="$2" \
        duration_us="${3:-1000}"  # Default 1ms = 1000µs

    # Duration-based calculation (SQM-style)
    # rate in kbit/s, duration in µs, result in bytes
    ch_quantum=$(((duration_us * rate) / 8000))

    # ATM-aware minimum
    # *** THE VAR IS $LINKTYPE IN THE CURRENT MAIN BRANCH BUT - SHOULD BE $COMMON_LINK_PRESETS? ***
    if [ "$COMMON_LINK_PRESETS" = "atm" ]; then
        # *** SHOULD MULTIPLICATION BY 53 COME BEFORE DIVISION BY 48, FOR INCREASED PRECISION? ***
        min_quantum=$(((MTU + 48 + 47) / 48 * 53))
        [ $ch_quantum -ge $min_quantum ] || ch_quantum=$min_quantum
    else
        [ $ch_quantum -ge $MTU ] || ch_quantum=$MTU
    fi

    # Maximum reasonable quantum (200KB)
    [ $ch_quantum -le 200000 ] || ch_quantum=200000

    eval "$ch_out_var=\"\$ch_quantum\""
}

# Calculate HTB burst size based on rate and target latency
calculate_htb_burst() {
    local ch_burst \
        ch_out_var="$1" \
        rate="$2" \
        duration_us="${3:-10000}"  # Default 10ms = 10000µs

    # burst in bytes for given duration
    ch_burst=$(((duration_us * rate) / 8000))

    # Minimum burst should be at least 1 MTU
    [ $ch_burst -ge 1500 ] || ch_burst=1500

    eval "$ch_out_var=\"\$ch_burst\""
}


## CLASS HELPERS

htb_main_class_helper() {
    local ROOT_BURST ROOT_CBURST

    # Root class gets modest burst since we typically configure 80-90% of physical rate
    # This allows brief bursts into the headroom without causing bufferbloat
    calculate_htb_burst ROOT_BURST "$HTB_RATE" 1000 &&   # 1ms burst
    calculate_htb_burst ROOT_CBURST "$HTB_RATE" 1000 &&  # 1ms cburst

    append_params CLASS \
        "qdisc:htb" \
        "quantum:$HTB_QUANTUM" \
        "rate:$HTB_RATE" \
        "ceil:$HTB_RATE" \
        "burst:$ROOT_BURST" \
        "cburst:$ROOT_CBURST" || return 1
}

htb_tin_class_helper() {
    local rate ceil min_ceil burst cburst prio

    case "$1" in
        realtime)
            prio=1
            rate=$PRIO_RATE_MIN
            # Calculate ceiling - ensure it's at least min + some headroom
            ceil=$((HTB_RATE / 3))  # Start with 33%

            # Ensure ceiling is at least min rate + 10%
            min_ceil=$((PRIO_RATE_MIN * 110 / 100))
            [ $ceil -ge $min_ceil ] || ceil=$min_ceil
            ;;
        default)
            prio=2
            rate=$BE_MIN_RATE
            ceil=$BE_CEIL
            ;;
        bulk)
            prio=3
            rate=$BK_MIN_RATE
            ceil=$BE_CEIL
            ;;
        *) # TODO: throw error
    esac

    calculate_htb_burst burst "$rate" 10000 &&
    calculate_htb_burst cburst "$rate" 5000 || return 1
    [ "$cburst" -ge 1500 ] || cburst=1500

    append_params CLASS \
        "qdisc:htb" \
        "quantum:$HTB_QUANTUM" \
        "rate:$rate" \
        "ceil:$ceil" \
        "burst:$burst" \
        "cburst:$cburst" \
        "prio:$prio" || return 1
}

## QDISC HELPERS

htb_root_qdisc_helper() {
    # HTB root qdisc defaults to best effort (class 13)
    append_params QDISC "qdisc:root" &&
    append_tc_overhead_params &&
    append_params QDISC "qdisc:htb" "extra:default 13" || return 1
}

htb_fq_codel_qdisc_helper() {
    local arg var val quantum targ_coeff=1 inval_args=''
    for arg in "$@"; do
        var='' val=''
        case "$arg" in
            "quantum:"*|"targ_coeff:"*)
                var="${arg%%":"*}"
                val="${arg#*":"}" ;;
            *) false
        esac &&
        case "$val" in
            ''|*[!0-9]*) false
        esac &&
        eval "$var=\"\$val\"" || { inval_args=1; break; }
    done

    [ -z "$inval_args" ] && [ -n "$quantum" ] ||
        { error_out "htb_fq_codel_qdisc_helper: invalid args '$*'"; return 1; }

    append_params QDISC \
        "qdisc:fq_codel" \
        "interval:$(( 100 + 2*1500*8/HTB_RATE ))" \
        "target:$(( 4 + targ_coeff*540*8/HTB_RATE ))" \
        "quantum:$quantum" || return 1
}


apply_rules_htb() {
    create_qdisc "htb_root" "1:" "root" &&

        # Main rate limiting
        create_class "htb_main" "1:1" "1:" &&

            # Priority class for realtime/gaming traffic
            create_class "htb_tin realtime" "1:11" "1:1" &&
                # Priority class gets fq_codel with aggressive settings
                create_qdisc "htb_fq_codel quantum:300" "110:" "1:11" || return 1
                if [ "$DIR" = "DOWN" ] || [ "$SFO_ENABLED" = "1" ]; then
                    for family in ipv4 ipv6; do
                        create_filters "1:" "EF CS5 CS6 CS7" "1:11" "$family" || return 1
                    done || return 1
                fi

            # Best Effort - default traffic
            create_class "htb_tin default" "1:13" "1:1" &&
                # Best effort with standard settings
                create_qdisc "htb_fq_codel quantum:1500" "130:" "1:13" || return 1
                if [ "$DIR" = "DOWN" ] || [ "$SFO_ENABLED" = "1" ]; then
                    create_filters "1:" "CS0" "1:13" "ipv6" || return 1
                fi

            # Background/Bulk - low priority
            create_class "htb_tin bulk" "1:15" "1:1" &&
                # Background with larger target
                create_qdisc "htb_fq_codel quantum:300 targ_coeff:2" "150:" "1:15" || return 1
                if [ "$DIR" = "DOWN" ] || [ "$SFO_ENABLED" = "1" ]; then
                    for family in ipv4 ipv6; do
                        create_filters "1:" "CS1" "1:15" "$family" || return 1
                    done || return 1
                fi
}

setup_htb() {
    # Smart calculation that scales smoothly across all bandwidths
    # Formula: percent = 15 + (50000 / RATE), capped between 5-40%
    #
    # This creates a hyperbolic curve that provides:
    # - High percentage (up to 40%) for very low bandwidth connections
    # - Smooth decrease as bandwidth increases
    # - Stabilizes around 15% for high bandwidth connections
    #
    # Examples:
    # - 1 Mbit:   15 + 50 = 65% → capped at 40% → 400 kbit → min 800 kbit
    # - 5 Mbit:   15 + 10 = 25% → 1250 kbit
    # - 10 Mbit:  15 + 5  = 20% → 2000 kbit
    # - 50 Mbit:  15 + 1  = 16% → 8000 kbit
    # - 100 Mbit: 15 + 0.5 = 15.5% → 15500 kbit
    #
    # Visualization:
    #   40% |*
    #       |  *
    #   30% |    *
    #       |      *
    #   20% |        * * * * *
    #   15% |                  * * * * * * * *
    #       +---------------------------------> Bandwidth
    #       1    5   10   20   50  100  200 Mbit
    #
    # Two safety mechanisms ensure adequate priority bandwidth:
    # 1. Percentage-based: Scales with total bandwidth
    # 2. Absolute minimum: 800 kbit for gaming/VoIP needs

    local DIR DEV HTB_RATE HTB_QUANTUM \
        PRIO_RATE_MIN BE_MIN_RATE BK_MIN_RATE BE_CEIL \
        percent percent_based absolute_min total_min

    for DIR in UP DOWN; do
        case "$DIR" in
            UP)
                DEV="$WAN"
                HTB_RATE="$UPRATE" ;;
            DOWN)
                DEV="$LAN"
                HTB_RATE="$DOWNRATE" ;;
            *) error_out "Unexpected direction '$DIR'"; return 1
        esac

        # Calculate HTB quantum for root (all use same quantum)
        calculate_htb_quantum HTB_QUANTUM "$HTB_RATE"

        # Calculate sliding percentage (higher % for lower rates)
        percent=$((15 + 50000 / HTB_RATE))
        [ $percent -le 40 ] || percent=40   # Cap at 40%
        [ $percent -ge 5 ] || percent=5     # Floor at 5%

        percent_based=$((HTB_RATE * percent / 100))
        absolute_min=800              # Gaming/VoIP minimum

        # Take the maximum of percentage-based and absolute minimum
        PRIO_RATE_MIN=$percent_based
        [ $PRIO_RATE_MIN -ge $absolute_min ] || PRIO_RATE_MIN=$absolute_min

        # Calculate BE and BK rates
        BE_MIN_RATE=$((HTB_RATE / 6))    # 16% guaranteed
        BK_MIN_RATE=$((HTB_RATE / 6))    # 16% guaranteed

        # Adjust if total mins exceed available bandwidth
        total_min=$((PRIO_RATE_MIN + BE_MIN_RATE + BK_MIN_RATE))
        if [ $total_min -gt $((HTB_RATE * 90 / 100)) ]; then
            # Scale down proportionally
            BE_MIN_RATE=$((BE_MIN_RATE * HTB_RATE * 90 / 100 / total_min))
            BK_MIN_RATE=$((BK_MIN_RATE * HTB_RATE * 90 / 100 / total_min))
        fi

        # BE/BK ceiling - almost full rate minus a small reserve
        BE_CEIL=$((HTB_RATE - 16))

        apply_rules_htb || return 1
    done
    :
}

