#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  disk-usage-report.sh
#  Top disk consumers on a Linux host, plus a df-vs-du drift check that
#  finds processes still holding deleted files open (the classic cause
#  of "du says X free but df says less").
#
#  Usage: ./disk-usage-report.sh [-p|--path <dir>] [-n|--top <N>] [-m|--mount <mountpoint>]
# ─────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

sep()  { echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"; }
hdr()  { echo -e "\n${BOLD}${CYAN}$1${RESET}"; sep; }
ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}   $*"; }
err()  { echo -e "  ${RED}✖${RESET}  $*" >&2; }

PATH_ARG="/"
TOP_N=15
MOUNT=""

usage() {
  echo -e "${BOLD}Usage:${RESET}"
  echo "  $0 [-p|--path <dir>] [-n|--top <N>] [-m|--mount <mountpoint>]"
  echo "  $0 -h | --help"
  echo
  echo "  -p, --path <dir>          directory to scan for top consumers (default: /)"
  echo "  -n, --top <N>             number of top consumers / offenders to list (default: 15)"
  echo "  -m, --mount <mountpoint>  filesystem to run the df-vs-du drift check on"
  echo "                            (default: the filesystem that --path lives on)"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path) [[ -z "${2:-}" ]] && { err "--path requires a value"; exit 1; }; PATH_ARG="$2"; shift 2 ;;
    -n|--top)  [[ -z "${2:-}" ]] && { err "--top requires a value"; exit 1; }; TOP_N="$2"; shift 2 ;;
    -m|--mount) [[ -z "${2:-}" ]] && { err "--mount requires a value"; exit 1; }; MOUNT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) err "Unknown argument: $1"; usage ;;
  esac
done

[[ "$(uname)" == "Linux" ]] || { err "This script targets Linux hosts (relies on /proc and GNU du/find)."; exit 1; }
[[ -d "$PATH_ARG" ]] || { err "Path not found: $PATH_ARG"; exit 1; }
[[ "$EUID" -eq 0 ]] || warn "Not running as root — the open-file scan will only see your own processes. Re-run with sudo for a complete picture."

HAVE_LSOF=0
command -v lsof &>/dev/null && HAVE_LSOF=1
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

[[ -z "$MOUNT" ]] && MOUNT=$(df -P "$PATH_ARG" | tail -n1 | awk '{print $NF}')

# ── filesystem overview ──────────────────────────────────────
hdr "Filesystem usage overview (df -h)"
df -hP | while IFS= read -r line; do
  if [[ "$line" == Filesystem* ]]; then
    echo -e "  ${BOLD}${line}${RESET}"
    continue
  fi
  pct=$(awk '{print $5}' <<<"$line" | tr -d '%')
  if [[ "$pct" =~ ^[0-9]+$ ]] && [[ "$pct" -ge 90 ]]; then
    echo -e "  ${RED}${line}${RESET}"
  elif [[ "$pct" =~ ^[0-9]+$ ]] && [[ "$pct" -ge 75 ]]; then
    echo -e "  ${YELLOW}${line}${RESET}"
  else
    echo "  $line"
  fi
done

# ── top consumers under --path ───────────────────────────────
hdr "Top $TOP_N directories under $PATH_ARG (one level, same filesystem)"
{ du -x -d1 -B1 "$PATH_ARG" 2>/dev/null | sort -k1,1nr | head -n "$TOP_N" || true; } | \
  while IFS=$'\t' read -r size dir; do
    printf "  %10s  %s\n" "$(human "$size")" "$dir"
  done

hdr "Top $TOP_N largest files under $PATH_ARG (same filesystem)"
{ find "$PATH_ARG" -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -t$'\t' -k1,1nr | head -n "$TOP_N" || true; } | \
  while IFS=$'\t' read -r size file; do
    printf "  %10s  %s\n" "$(human "$size")" "$file"
  done

# ── df vs du drift check ─────────────────────────────────────
hdr "df vs du drift check on $MOUNT"
echo -e "  ${DIM}Walking $MOUNT with du — this can take a while on large filesystems...${RESET}"
echo -e "  ${DIM}(permission-denied directories are skipped rather than aborting the scan)${RESET}"

df_used=$(df -P -B1 "$MOUNT" | tail -n1 | awk '{print $3}' || true)
du_used=$(du -sx -B1 "$MOUNT" 2>/dev/null | awk '{print $1}' || true)

if [[ -z "$df_used" || -z "$du_used" ]]; then
  err "Could not compute df/du totals for $MOUNT — skipping drift check."
  drift=0
else
  drift=$(( df_used - du_used ))
  row_fmt="  %-14s %s\n"
  printf "$row_fmt" "df used:" "$(human "$df_used")"
  printf "$row_fmt" "du used:" "$(human "$du_used")"
  if [[ "$drift" -gt 0 ]]; then
    pct_drift=$(awk -v d="$drift" -v t="$df_used" 'BEGIN{ printf "%.1f", (t>0 ? d/t*100 : 0) }')
    echo -e "  ${YELLOW}gap:            $(human "$drift")  (${pct_drift}% of df-reported usage)${RESET}"
  else
    printf "$row_fmt" "gap:" "$(human 0)"
  fi
fi

if [[ "$drift" -gt 104857600 ]]; then
  warn "df reports notably more used space than du can account for."
  warn "This usually means a process is holding an unlinked (deleted) file open — the space isn't freed until the file descriptor closes."
else
  ok "No significant df/du drift on $MOUNT."
fi

# ── open files with no remaining links (the actual culprits) ─
hdr "Open files with no remaining links (deleted-but-open) under $MOUNT"

TMP_HITS="$(mktemp)"
trap 'rm -f "$TMP_HITS"' EXIT

if [[ "$HAVE_LSOF" -eq 1 ]]; then
  # +L1 lists open files whose link count dropped below 1, i.e. unlinked-but-open.
  lsof +L1 2>/dev/null | awk 'NR>1 && $8==0 {
      name=""; for (i=10; i<=NF; i++) name = name (name=="" ? "" : " ") $i;
      printf "%s\t%s\t%s\t%s\t%s\n", $7, $1, $2, $4, name
    }' >> "$TMP_HITS" || true
else
  warn "lsof not found — falling back to a /proc/*/fd scan (slower, misses some edge cases)."
  for fd_dir in /proc/[0-9]*/fd; do
    pid_dir=${fd_dir%/fd}
    pid=${pid_dir#/proc/}
    [[ -d "$fd_dir" ]] || continue
    comm=$(cat "$pid_dir/comm" 2>/dev/null || echo "?")
    for fd in "$fd_dir"/*; do
      [[ -e "$fd" ]] || continue
      target=$(readlink "$fd" 2>/dev/null) || continue
      [[ "$target" == *" (deleted)" ]] || continue
      size=$(stat -L -c %s "$fd" 2>/dev/null) || continue
      [[ "$size" -gt 0 ]] || continue
      printf "%s\t%s\t%s\t%s\t%s\n" "$size" "$comm" "$pid" "${fd##*/}" "$target" >> "$TMP_HITS"
    done
  done 2>/dev/null
fi

# Restrict to files whose (former) path lived under $MOUNT, unless MOUNT is "/"
if [[ "$MOUNT" != "/" ]]; then
  grep -F "$MOUNT" "$TMP_HITS" > "${TMP_HITS}.filtered" 2>/dev/null || true
  mv "${TMP_HITS}.filtered" "$TMP_HITS"
fi

sort -t$'\t' -k1,1nr "$TMP_HITS" | head -n "$TOP_N" > "${TMP_HITS}.top" || true

if [[ ! -s "${TMP_HITS}.top" ]]; then
  ok "No open-but-deleted files found (or none visible without root)."
else
  printf "  %-10s %-16s %-8s %-6s %s\n" "SIZE" "COMMAND" "PID" "FD" "PATH (deleted)"
  total=0
  while IFS=$'\t' read -r size cmd pid fd name; do
    printf "  %-10s %-16s %-8s %-6s %s\n" "$(human "$size")" "$cmd" "$pid" "$fd" "$name"
    total=$(( total + size ))
  done < "${TMP_HITS}.top"
  echo
  echo -e "  ${BOLD}Total reclaimable from listed entries: $(human "$total")${RESET}"
  if [[ "$drift" -gt 0 ]]; then
    accounted=$(awk -v a="$total" -v d="$drift" 'BEGIN{ printf "%.0f", (d>0 ? a/d*100 : 0) }')
    echo -e "  ${DIM}That's ~${accounted}% of the $(human "$drift") df/du gap above.${RESET}"
  fi
fi
rm -f "${TMP_HITS}.top"

# ── remediation ───────────────────────────────────────────────
hdr "Reclaiming the space"
echo "  1. Preferred: restart/reload the owning process (log rotation daemons usually"
echo "     support a reload signal, e.g. 'kill -HUP <pid>' or 'systemctl reload <svc>')."
echo "     That makes it reopen its file and drop the handle to the deleted one."
echo
echo "  2. If the file is an append-only log and a restart isn't an option, you can"
echo "     truncate it in place without touching the process:"
echo -e "       ${DIM}: > /proc/<pid>/fd/<fd>${RESET}"
echo -e "     ${YELLOW}Only do this for logs — truncating an open database/data file will corrupt it.${RESET}"
echo
echo "  3. As a last resort, kill/restart the process itself once you've confirmed"
echo "     what it is and that it's safe to bounce."
echo
