#!/usr/bin/env bash
# decode_softnet.sh — decode /proc/net/softnet_stat
# Usage:
#   bash decode_softnet.sh                        # reads live /proc/net/softnet_stat
#   bash decode_softnet.sh /proc/net/softnet_stat # explicit path
#   cat /proc/net/softnet_stat | bash decode_softnet.sh

set -euo pipefail

BOLD=$'\033[1m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
GREEN=$'\033[32m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RESET=$'\033[0m'

NIC="${NIC:-ens2}"
INPUT="${1:-}"
if [ -z "$INPUT" ] && [ -t 0 ]; then
    INPUT="/proc/net/softnet_stat"
elif [ -z "$INPUT" ]; then
    INPUT=/dev/stdin
fi

# ── parse ──────────────────────────────────────────────────────────────────────
declare -a CPU TOTAL DROPPED SQUEEZE RPS FLOW THROTTLED
row=0
while read -r line; do
    f=($line)
    [ ${#f[@]} -lt 13 ] && continue
    CPU[$row]=$(( 16#${f[12]} ))
    TOTAL[$row]=$(( 16#${f[0]}  ))
    DROPPED[$row]=$(( 16#${f[1]}  ))
    SQUEEZE[$row]=$(( 16#${f[2]}  ))
    RPS[$row]=$(( 16#${f[9]}  ))
    FLOW[$row]=$(( 16#${f[10]} ))
    THROTTLED[$row]=$(( 16#${f[11]} ))
    row=$(( row + 1 ))
done < "$INPUT"

[ "$row" -eq 0 ] && { echo "${RED}No rows parsed — check input${RESET}"; exit 1; }

# ── helpers ────────────────────────────────────────────────────────────────────
commify() { printf '%d' "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'; }

sparkbar() {       # sparkbar value max width
    local val=$1 max=$2 width=${3:-20}
    local filled=$(( max > 0 ? val * width / max : 0 ))
    local empty=$(( width - filled ))
    printf '%0.s█' $(seq 1 $filled 2>/dev/null)
    printf '%0.s░' $(seq 1 $empty  2>/dev/null)
}

# ── totals ─────────────────────────────────────────────────────────────────────
sum_total=0; sum_drop=0; sum_squeeze=0; sum_rps=0
max_total=0; min_total=999999999999; heavy_cpu=0
for i in "${!TOTAL[@]}"; do
    sum_total=$(( sum_total + TOTAL[$i] ))
    sum_drop=$(( sum_drop + DROPPED[$i] ))
    sum_squeeze=$(( sum_squeeze + SQUEEZE[$i] ))
    sum_rps=$(( sum_rps + RPS[$i] ))
    if (( TOTAL[$i] > max_total )); then max_total=${TOTAL[$i]}; heavy_cpu=${CPU[$i]}; fi
    if (( TOTAL[$i] < min_total )); then min_total=${TOTAL[$i]}; fi
done
imbalance=$(awk "BEGIN{printf \"%.2f\", $max_total/$min_total}")

# ── header ─────────────────────────────────────────────────────────────────────
echo
echo "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}║        /proc/net/softnet_stat  —  decoder                ║${RESET}"
echo "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo

# ── summary cards ──────────────────────────────────────────────────────────────
printf "${BOLD}%-22s %-22s %-22s %-22s${RESET}\n" \
    "total frames" "drops" "time_squeeze" "load imbalance"
printf "%-22s %-22s %-22s %-22s\n" \
    "$(commify $sum_total)" \
    "$([ $sum_drop -gt 0 ] && echo "${RED}$(commify $sum_drop) ⚠${RESET}" || echo "${GREEN}0 ✔${RESET}")" \
    "$([ $sum_squeeze -gt 50 ] && echo "${YELLOW}$(commify $sum_squeeze) ⚠${RESET}" || echo "$(commify $sum_squeeze)")" \
    "$([ $(awk "BEGIN{print ($imbalance > 2.0)}") -eq 1 ] && echo "${YELLOW}${imbalance}× (CPU ${heavy_cpu})${RESET}" || echo "${imbalance}×")"
echo

# ── per-cpu table ──────────────────────────────────────────────────────────────
SEP="$(printf '%.0s─' {1..90})"
printf "${BOLD}%-5s %14s %10s %14s %14s %12s %10s${RESET}\n" \
    "CPU" "total" "dropped" "time_squeeze" "received_rps" "flow_limit" "throttled"
echo "$SEP"

for i in "${!CPU[@]}"; do
    cpu=${CPU[$i]}
    total=$(commify ${TOTAL[$i]})

    # dropped
    if [ "${DROPPED[$i]}" -gt 0 ]; then
        drop_s="${RED}$(printf '%10s' $(commify ${DROPPED[$i]})) ⚠${RESET}"
    else
        drop_s="$(printf '%10s' 0)"
    fi

    # time_squeeze
    if [ "${SQUEEZE[$i]}" -ge 50 ]; then
        sq_s="${RED}$(printf '%14s' $(commify ${SQUEEZE[$i]}))${RESET}"
    elif [ "${SQUEEZE[$i]}" -ge 10 ]; then
        sq_s="${YELLOW}$(printf '%14s' $(commify ${SQUEEZE[$i]}))${RESET}"
    else
        sq_s="$(printf '%14s' $(commify ${SQUEEZE[$i]}))"
    fi

    # rps
    if [ "${RPS[$i]}" -gt 0 ]; then
        rps_s="${CYAN}$(printf '%14s' $(commify ${RPS[$i]}))${RESET}"
    else
        rps_s="$(printf '%14s' 0)"
    fi

    printf "%-5s %14s %s %s %s %12s %10s\n" \
        "$cpu" "$total" "$drop_s" "$sq_s" "$rps_s" \
        "$(commify ${FLOW[$i]})" "$(commify ${THROTTLED[$i]})"
done

echo "$SEP"
printf "${BOLD}%-5s %14s %10s %14s %14s${RESET}\n" \
    "ALL" "$(commify $sum_total)" "$(commify $sum_drop)" \
    "$(commify $sum_squeeze)" "$(commify $sum_rps)"
echo

# ── time_squeeze bars ──────────────────────────────────────────────────────────
echo "${BOLD}time_squeeze severity${RESET}"
echo
max_sq=$(( sum_squeeze > 0 ? max_total : 1 ))
max_sq=0
for i in "${!SQUEEZE[@]}"; do (( SQUEEZE[$i] > max_sq )) && max_sq=${SQUEEZE[$i]}; done
[ "$max_sq" -eq 0 ] && max_sq=1

for i in "${!CPU[@]}"; do
    sq=${SQUEEZE[$i]}
    if   [ $sq -ge 50 ]; then color=$RED    level="HIGH    "
    elif [ $sq -ge 10 ]; then color=$YELLOW level="MODERATE"
    else                       color=$GREEN  level="LOW     "
    fi
    bar=$(sparkbar $sq $max_sq 30)
    printf "  CPU %-2s │ ${color}%s${RESET} │ %4d  ${color}%s${RESET}\n" \
        "${CPU[$i]}" "$bar" "$sq" "$level"
done
echo

# ── rps distribution ──────────────────────────────────────────────────────────
echo "${BOLD}RPS steered frames${RESET}"
echo
if [ "$sum_rps" -gt 0 ]; then
    for i in "${!CPU[@]}"; do
        [ "${RPS[$i]}" -eq 0 ] && continue
        bar=$(sparkbar ${RPS[$i]} $sum_rps 30)
        printf "  CPU %-2s │ ${CYAN}%s${RESET} │ %s\n" \
            "${CPU[$i]}" "$bar" "$(commify ${RPS[$i]})"
    done
else
    echo "  ${DIM}No RPS activity — RPS may not be configured${RESET}"
fi
echo

# ── recommendations ────────────────────────────────────────────────────────────
echo "${BOLD}Recommendations${RESET}"
echo
rec=0

if [ "$sum_squeeze" -gt 50 ]; then
    rec=$(( rec + 1 ))
    echo "  ${YELLOW}[${rec}] time_squeeze=${sum_squeeze} — NAPI budget too low${RESET}"
    echo "      sysctl -w net.core.netdev_budget=600"
    echo "      sysctl -w net.core.netdev_budget_usecs=4000"
    echo "      # persist:"
    echo "      echo 'net.core.netdev_budget=600' >> /etc/sysctl.conf"
    echo "      echo 'net.core.netdev_budget_usecs=4000' >> /etc/sysctl.conf"
    echo
fi

if [ "$sum_drop" -gt 0 ]; then
    rec=$(( rec + 1 ))
    echo "  ${RED}[${rec}] DROPS=${sum_drop} — backlog overflow${RESET}"
    echo "      sysctl -w net.core.netdev_max_backlog=5000"
    echo
fi

if [ "$(awk "BEGIN{print ($imbalance > 2.0)}")" -eq 1 ]; then
    rec=$(( rec + 1 ))
    echo "  ${YELLOW}[${rec}] CPU ${heavy_cpu} handles ${imbalance}× more traffic — check IRQ affinity${RESET}"
    echo "      grep ${NIC} /proc/interrupts"
    echo "      cat /proc/irq/*/smp_affinity_list"
    echo "      # check queue count:"
    echo "      ethtool -l ${NIC}"
    echo
fi

if [ "$sum_rps" -eq 0 ]; then
    rec=$(( rec + 1 ))
    echo "  ${CYAN}[${rec}] No RPS activity — enable to spread load across all CPUs${RESET}"
    echo "      echo f > /sys/class/net/${NIC}/queues/rx-0/rps_cpus"
    echo "      # for RFS (flow steering) also set:"
    echo "      sysctl -w net.core.rps_sock_flow_entries=32768"
    echo "      echo 32768 > /sys/class/net/${NIC}/queues/rx-0/rps_flow_cnt"
    echo
fi

rec=$(( rec + 1 ))
echo "  [${rec}] Increase RX ring buffer to absorb bursts"
echo "      ethtool -g ${NIC}                   # check current/max"
echo "      ethtool -G ${NIC} rx 4096"
echo

echo "${DIM}── NIC: ${NIC}  |  tip: NIC=eth0 bash $0 to override ──${RESET}"
echo