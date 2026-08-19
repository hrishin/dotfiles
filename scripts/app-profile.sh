#!/usr/bin/env bash
# Standalone: runs on the remote host via `ssh ... 'bash -s' < this-file`,
# so it must not depend on anything from this repo (e.g. util.sh).
#
# app-profile.sh
# Resolves a target process (by PID or name), walks its full descendant
# tree, and samples CPU, memory, and disk I/O for that whole tree over a
# fixed window. Network I/O is best-effort: an approximate figure derived
# from /proc/<pid>/io always ships, an accurate nethogs-based capture ships
# when nethogs is installed and we're root, and active socket connections
# are always listed for qualitative context.
#
# Usage: ./app-profile.sh -t|--target <pid|name> [-d|--duration <seconds>]
#                          [-i|--interval <seconds>] [-n|--top <N>]
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

sep() { echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"; }
hdr() {
    echo -e "\n${BOLD}${CYAN}$1${RESET}"
    sep
}
ok() { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}   $*"; }
err() { echo -e "  ${RED}✖${RESET}  $*" >&2; }

TARGET=""
DURATION=10
INTERVAL=1
TOP_N=5

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 -t|--target <pid|name> [-d|--duration <seconds>] [-i|--interval <seconds>] [-n|--top <N>]"
    echo "  $0 -h | --help"
    echo
    echo "  -t, --target <pid|name>   process to profile: a numeric PID, or a name"
    echo "                            resolved via pgrep (exact comm match first, then"
    echo "                            full-cmdline substring match)"
    echo "  -d, --duration <seconds>  total sampling window (default: 10)"
    echo "  -i, --interval <seconds>  seconds between samples (default: 1)"
    echo "  -n, --top <N>             number of top CPU contributors to report (default: 5)"
    exit 0
}

[[ $# -eq 0 ]] && usage
while [[ $# -gt 0 ]]; do
    case "$1" in
    -t | --target)
        [[ -z "${2:-}" ]] && {
            err "--target requires a value"
            exit 1
        }
        TARGET="$2"
        shift 2
        ;;
    -d | --duration)
        [[ -z "${2:-}" ]] && {
            err "--duration requires a value"
            exit 1
        }
        DURATION="$2"
        shift 2
        ;;
    -i | --interval)
        [[ -z "${2:-}" ]] && {
            err "--interval requires a value"
            exit 1
        }
        INTERVAL="$2"
        shift 2
        ;;
    -n | --top)
        [[ -z "${2:-}" ]] && {
            err "--top requires a value"
            exit 1
        }
        TOP_N="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *)
        err "Unknown argument: $1"
        usage
        ;;
    esac
done

[[ -n "$TARGET" ]] || {
    err "--target is required (PID or process name)"
    exit 1
}
[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 1 ]] || {
    err "--duration must be a positive integer"
    exit 1
}
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || {
    err "--interval must be a positive integer"
    exit 1
}
[[ "$TOP_N" =~ ^[0-9]+$ && "$TOP_N" -ge 1 ]] || {
    err "--top must be a positive integer"
    exit 1
}

[[ "$(uname)" == "Linux" ]] || {
    err "This script targets Linux hosts (relies on /proc, pgrep, ss)."
    exit 1
}
command -v pgrep &>/dev/null || {
    err "pgrep not found (procps package) — required to resolve process trees."
    exit 1
}
[[ "$EUID" -eq 0 ]] || warn "Not running as root — CPU/memory/I/O for processes owned by other users won't be readable. Re-run with sudo for a complete picture."

command -v ss &>/dev/null && HAVE_SS=1 || HAVE_SS=0
[[ "$HAVE_SS" -eq 0 ]] && warn "ss not found (iproute2 package) — active network connections won't be listed."

command -v numfmt &>/dev/null && HAVE_NUMFMT=1 || HAVE_NUMFMT=0
human() {
    local bytes=${1:-0}
    if [[ "$HAVE_NUMFMT" -eq 1 ]]; then
        numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        awk -v b="$bytes" 'BEGIN{
            split("B KB MB GB TB PB", u, " ");
            i=1; v=b;
            while (v>=1024 && i<6) { v/=1024; i++ }
            printf "%.1f%s", v, u[i]
        }'
    fi
}

CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

# ── resolve target -> ROOT_PID ───────────────────────────────
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    ROOT_PID="$TARGET"
    [[ -d "/proc/$ROOT_PID" ]] || {
        err "No such PID: $ROOT_PID"
        exit 1
    }
else
    # A pgrep search for $TARGET can transiently match one of our OWN
    # subshells (e.g. the pipe/process-substitution plumbing used to run
    # pgrep itself): its argv is inherited from this script's, which
    # literally contains $TARGET since it was passed as our own -t
    # argument. Filter those out by walking each candidate's PPid chain
    # back to see if it resolves to us — a plain "$pid == $$" check isn't
    # enough since these are distinct, transient child PIDs, not $$ itself.
    is_own() {
        local cur="$1"
        while [[ -n "$cur" && "$cur" != "0" && "$cur" != "1" ]]; do
            [[ "$cur" == "$$" ]] && return 0
            cur=$(awk '/^PPid:/{print $2}' "/proc/$cur/status" 2>/dev/null)
        done
        return 1
    }

    resolve_matches() {
        local flag="$1" pattern="$2" pid
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            is_own "$pid" || echo "$pid"
        done < <(pgrep "$flag" "$pattern" 2>/dev/null)
    }

    mapfile -t matches < <(resolve_matches -x "$TARGET")
    [[ ${#matches[@]} -eq 0 ]] && mapfile -t matches < <(resolve_matches -f "$TARGET")

    if [[ ${#matches[@]} -eq 0 ]]; then
        err "No process matching '$TARGET' found."
        exit 1
    elif [[ ${#matches[@]} -gt 1 ]]; then
        warn "Multiple processes match '$TARGET' — pick one with -t <pid>:"
        ps -o pid,ppid,cmd -p "$(
            IFS=,
            echo "${matches[*]}"
        )" 2>/dev/null | sed 's/^/  /'
        exit 1
    else
        ROOT_PID="${matches[0]}"
    fi
fi

# ── walk the descendant tree ─────────────────────────────────
collect_tree() {
    local root="$1"
    TREE_PIDS=()
    [[ -d "/proc/$root" ]] || return 1
    local queue=("$root") pid children c
    while [[ ${#queue[@]} -gt 0 ]]; do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -d "/proc/$pid" ]] || continue
        TREE_PIDS+=("$pid")
        children=$(pgrep -P "$pid" 2>/dev/null || true)
        for c in $children; do
            queue+=("$c")
        done
    done
}

collect_tree "$ROOT_PID" || {
    err "No such PID: $ROOT_PID"
    exit 1
}
[[ ${#TREE_PIDS[@]} -eq 0 ]] && {
    err "Target process $ROOT_PID is gone."
    exit 1
}

NPROC=$(nproc 2>/dev/null || echo "?")
hdr "Process tree for PID $ROOT_PID (${#TREE_PIDS[@]} process(es), host has $NPROC core(s))"
ps -o pid,ppid,user,%cpu,%mem,etimes,stat,cmd --pid "$(
    IFS=,
    echo "${TREE_PIDS[*]}"
)" 2>/dev/null | sed 's/^/  /'

[[ ${#TREE_PIDS[@]} -gt 30 ]] && warn "Tree has ${#TREE_PIDS[@]} processes — this tool forks several helper processes per PID per sample, so it adds nontrivial overhead of its own on an already-loaded host."

# ── /proc readers ─────────────────────────────────────────────
# Prints "<state> <utime+stime ticks>" in one /proc/<pid>/stat read, so
# zombie detection (state == Z) doesn't need a second fork per PID.
read_stat() {
    local pid="$1" stat rest
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest="${stat##*) }"
    awk '{print $1, $12+$13}' <<<"$rest"
}

read_io() {
    local f="/proc/$1/io"
    [[ -r "$f" ]] || return 1
    awk '
        /^rchar:/ {rc=$2} /^wchar:/ {wc=$2}
        /^read_bytes:/ {rb=$2} /^write_bytes:/ {wb=$2}
        END { if (rb=="") exit 1; print rc, wc, rb, wb }
    ' "$f"
}

# ── optional: nethogs for accurate per-process bandwidth ─────
NETHOGS_LOG=""
NETHOGS_BGPID=""
# Safety net: if this script is killed (Ctrl-C, dropped SSH session, an
# unanticipated early exit) before the normal nethogs teardown below runs,
# don't leave a root packet-capture process and its log orphaned on the
# target host. Idempotent — the normal teardown clears both vars first,
# so this is a no-op on the happy path.
cleanup() {
    [[ -n "$NETHOGS_BGPID" ]] && kill "$NETHOGS_BGPID" 2>/dev/null
    [[ -n "$NETHOGS_BGPID" ]] && wait "$NETHOGS_BGPID" 2>/dev/null
    [[ -n "$NETHOGS_LOG" ]] && rm -f "$NETHOGS_LOG"
    return 0
}
trap cleanup EXIT

if command -v nethogs &>/dev/null && [[ "$EUID" -eq 0 ]]; then
    # All non-loopback UP interfaces, not just the default route's — a
    # k8s node's app traffic often rides an overlay/CNI interface
    # (cni0, flannel.1, ...) rather than the default egress NIC.
    mapfile -t ifaces < <(ip -o link show up 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}' | grep -vx 'lo')
    if [[ ${#ifaces[@]} -gt 0 ]]; then
        NETHOGS_LOG="$(mktemp)"
        nethogs -t -d "$INTERVAL" "${ifaces[@]}" >"$NETHOGS_LOG" 2>/dev/null &
        NETHOGS_BGPID=$!
        ok "Capturing per-process bandwidth on ${ifaces[*]} via nethogs."
    else
        warn "Could not detect any non-loopback network interface — skipping nethogs capture."
    fi
elif command -v nethogs &>/dev/null; then
    warn "nethogs found but not running as root — skipping accurate network capture."
else
    warn "nethogs not installed — network I/O below is an approximation. Install nethogs for accurate per-process bandwidth."
fi

# ── prime baseline, then sample ───────────────────────────────
declare -A PREV_TICKS PREV_RB PREV_WB PREV_RC PREV_WC SEEN
declare -A CMD PEAK_RSS CUM_TICKS CUM_RB CUM_WB

prime_pid() {
    local pid="$1" out io
    CMD[$pid]=$(ps -o cmd= -p "$pid" 2>/dev/null | cut -c1-60)
    out=$(read_stat "$pid") && read -r _ PREV_TICKS["$pid"] <<<"$out"
    io=$(read_io "$pid") && read -r PREV_RC["$pid"] PREV_WC["$pid"] PREV_RB["$pid"] PREV_WB["$pid"] <<<"$io"
    SEEN[$pid]=1
}

for pid in "${TREE_PIDS[@]}"; do prime_pid "$pid"; done

SAMPLES=$((DURATION / INTERVAL))
[[ "$SAMPLES" -lt 1 ]] && SAMPLES=1

hdr "Sampling PID $ROOT_PID and descendants — ${DURATION}s window, ${INTERVAL}s interval"
printf "  %-9s %-6s %8s %10s %12s %12s %14s\n" "TIME" "PROCS" "CPU%" "MEM(MB)" "DISK R/s" "DISK W/s" "OTHER I/O/s*"

sleep "$INTERVAL"

for ((s = 1; s <= SAMPLES; s++)); do
    collect_tree "$ROOT_PID" || break
    [[ ${#TREE_PIDS[@]} -eq 0 ]] && break

    total_cpu_ticks=0 total_rss_kb=0 total_rb=0 total_wb=0 total_other=0 alive=0 zombies=0

    for pid in "${TREE_PIDS[@]}"; do
        [[ -d "/proc/$pid" ]] || continue

        out=$(read_stat "$pid") || out=""
        state="" ticks=""
        [[ -n "$out" ]] && read -r state ticks <<<"$out"

        # A zombie still has a /proc entry (it's an exit-status slot the
        # parent hasn't reaped) but holds no real CPU/memory/I/O — count
        # it separately rather than let it pad the "alive" total or dilute
        # the sums with stale numbers.
        if [[ "$state" == "Z" ]]; then
            zombies=$((zombies + 1))
            continue
        fi

        alive=$((alive + 1))
        [[ -z "${SEEN[$pid]:-}" ]] && prime_pid "$pid" && continue

        if [[ -n "$ticks" ]]; then
            delta=$((ticks - ${PREV_TICKS[$pid]:-$ticks}))
            ((delta < 0)) && delta=0
            total_cpu_ticks=$((total_cpu_ticks + delta))
            CUM_TICKS[$pid]=$((${CUM_TICKS[$pid]:-0} + delta))
            PREV_TICKS[$pid]=$ticks
        fi

        rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null)
        if [[ -n "$rss" ]]; then
            total_rss_kb=$((total_rss_kb + rss))
            [[ -z "${PEAK_RSS[$pid]:-}" || "$rss" -gt "${PEAK_RSS[$pid]}" ]] && PEAK_RSS[$pid]=$rss
        fi

        io=$(read_io "$pid") || io=""
        if [[ -n "$io" ]]; then
            read -r rc wc rb wb <<<"$io"
            d_rb=$((rb - ${PREV_RB[$pid]:-$rb})) && ((d_rb < 0)) && d_rb=0
            d_wb=$((wb - ${PREV_WB[$pid]:-$wb})) && ((d_wb < 0)) && d_wb=0
            d_rc=$((rc - ${PREV_RC[$pid]:-$rc})) && ((d_rc < 0)) && d_rc=0
            d_wc=$((wc - ${PREV_WC[$pid]:-$wc})) && ((d_wc < 0)) && d_wc=0
            total_rb=$((total_rb + d_rb))
            total_wb=$((total_wb + d_wb))
            other=$(((d_rc + d_wc) - (d_rb + d_wb)))
            ((other < 0)) && other=0
            total_other=$((total_other + other))
            CUM_RB[$pid]=$((${CUM_RB[$pid]:-0} + d_rb))
            CUM_WB[$pid]=$((${CUM_WB[$pid]:-0} + d_wb))
            PREV_RB[$pid]=$rb
            PREV_WB[$pid]=$wb
            PREV_RC[$pid]=$rc
            PREV_WC[$pid]=$wc
        fi
    done

    cpu_pct=$(awk -v t="$total_cpu_ticks" -v hz="$CLK_TCK" -v iv="$INTERVAL" 'BEGIN{ printf "%.1f", t/(hz*iv)*100 }')
    mem_mb=$(awk -v k="$total_rss_kb" 'BEGIN{ printf "%.1f", k/1024 }')
    rb_s=$((total_rb / INTERVAL))
    wb_s=$((total_wb / INTERVAL))
    other_s=$((total_other / INTERVAL))
    procs_str="$alive"
    [[ "$zombies" -gt 0 ]] && procs_str="${alive}+${zombies}Z"

    printf "  %-9s %-6s %7s%% %10s %12s %12s %14s\n" \
        "$(date +%H:%M:%S)" "$procs_str" "$cpu_pct" "$mem_mb" "$(human "$rb_s")/s" "$(human "$wb_s")/s" "$(human "$other_s")/s"

    ((s < SAMPLES)) && sleep "$INTERVAL"
done
echo -e "  ${DIM}* OTHER I/O/s approximates non-disk I/O (network, pipes, sockets) as${RESET}"
echo -e "  ${DIM}  (Δrchar+Δwchar) − (Δread_bytes+Δwrite_bytes); it's a heuristic, not a${RESET}"
echo -e "  ${DIM}  precise network figure — see the network sections below for that.${RESET}"

# ── network: active connections + optional nethogs capture ───
pid_alt=""
[[ ${#TREE_PIDS[@]} -gt 0 ]] && pid_alt=$(
    IFS='|'
    echo "${TREE_PIDS[*]}"
)

hdr "Active network connections for the tree"
if [[ "$HAVE_SS" -eq 0 ]]; then
    echo "  (ss not installed — cannot list active connections)"
elif [[ -z "$pid_alt" ]]; then
    echo "  (target process is gone — no PIDs left to check)"
else
    conns=$(ss -tunp 2>/dev/null | grep -E "pid=($pid_alt)," || true)
    if [[ -n "$conns" ]]; then
        echo "  ${conns//$'\n'/$'\n'  }"
    else
        echo "  (none found, or not visible without root)"
    fi
fi

if [[ -n "$NETHOGS_BGPID" ]]; then
    kill "$NETHOGS_BGPID" 2>/dev/null || true
    wait "$NETHOGS_BGPID" 2>/dev/null || true
    NETHOGS_BGPID=""
    hdr "Network I/O (nethogs capture — program/pid/uid, sent KB/s, recv KB/s per refresh)"
    matched=""
    [[ -n "$pid_alt" ]] && matched=$(grep -E "/($pid_alt)/[0-9]+" "$NETHOGS_LOG" 2>/dev/null || true)
    if [[ -n "$matched" ]]; then
        echo "  ${matched//$'\n'/$'\n'  }"
    else
        echo "  (no matching traffic captured during the window)"
    fi
    rm -f "$NETHOGS_LOG"
    NETHOGS_LOG=""
fi

# ── top CPU contributors over the window ──────────────────────
hdr "Top $TOP_N contributors by CPU time over the window"
printf "  %-8s %10s %10s %12s %12s %s\n" "PID" "CPU(s)" "PEAK_MEM" "DISK_R" "DISK_W" "CMD"
for pid in "${!CUM_TICKS[@]}"; do
    printf "%s\t%s\n" "${CUM_TICKS[$pid]}" "$pid"
done | sort -t$'\t' -k1,1nr | head -n "$TOP_N" | while IFS=$'\t' read -r ticks pid; do
    cpu_s=$(awk -v t="$ticks" -v hz="$CLK_TCK" 'BEGIN{ printf "%.1f", t/hz }')
    peak_mb=$(awk -v k="${PEAK_RSS[$pid]:-0}" 'BEGIN{ printf "%.1f", k/1024 }')
    printf "  %-8s %9ss %9sMB %12s %12s %s\n" \
        "$pid" "$cpu_s" "$peak_mb" "$(human "${CUM_RB[$pid]:-0}")" "$(human "${CUM_WB[$pid]:-0}")" "${CMD[$pid]:-?}"
done
