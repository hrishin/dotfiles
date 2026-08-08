#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  container-inspect.sh
#  Inspect namespaces and cgroups for a container
#  Usage: ./container-inspect.sh <container-id>
#         ./container-inspect.sh --pid <pid>
# ─────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

sep()  { echo -e "${DIM}────────────────────────────────────────────────${RESET}"; }
hdr()  { echo -e "\n${BOLD}${CYAN}$1${RESET}"; sep; }
ok()   { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}   $1"; }
err()  { echo -e "  ${RED}✖${RESET}  $1"; }
row()  { printf "  %-18s %s\n" "$1" "$2"; }

# ── check dependencies ───────────────────────
check_deps() {
  local missing=()
  
  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi
  
  if ! command -v crictl &>/dev/null; then
    missing+=("crictl")
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    echo -e "  ${DIM}Install with: apt install jq && apt install crictl${RESET}"
    exit 1
  fi
}

usage() {
  echo -e "${BOLD}Usage:${RESET}"
  echo "  $0 <container-id>        resolve PID via crictl, then inspect"
  echo "  $0 --pid <pid>           inspect a known PID directly"
  echo "  $0 -h | --help"
  exit 0
}

# ── arg parsing ──────────────────────────────
PID=""
CONTAINER_ID=""

[[ $# -eq 0 ]] && usage
case "$1" in
  -h|--help) usage ;;
  --pid)
    [[ -z "${2:-}" ]] && { err "--pid requires a value"; exit 1; }
    PID="$2" ;;
  *)
    CONTAINER_ID="$1" ;;
esac

# ── check dependencies ──────────────────────
check_deps

# ── resolve PID from container ID ────────────
if [[ -n "$CONTAINER_ID" ]]; then
  hdr "Resolving PID for container: $CONTAINER_ID"

  PID=$(crictl inspect "$CONTAINER_ID" 2>/dev/null | jq -r '.info.pid' 2>/dev/null || true)

  if [[ -z "$PID" || "$PID" == "null" ]]; then
    err "Could not resolve PID. Container may be stopped or ID is truncated."
    echo ""
    echo -e "  ${DIM}Tip: run 'crictl ps | grep <name>' to get the full container ID${RESET}"
    exit 1
  fi
  ok "Container ID : $CONTAINER_ID"
fi

# ── validate PID ─────────────────────────────
if [[ -z "$PID" ]]; then
  err "No PID resolved"; exit 1
fi

if [[ ! -d "/proc/$PID" ]]; then
  err "PID $PID not found in /proc — process may have exited"
  exit 1
fi

COMM=$(cat /proc/"$PID"/comm 2>/dev/null || echo "unknown")
ok "PID         : $PID  ($COMM)"

# ════════════════════════════════════════════
#  SECTION 1 — NAMESPACES
# ════════════════════════════════════════════
hdr "§1  Namespace isolation  (PID $PID vs host PID 1)"

printf "  %-10s %-12s %-30s %s\n" "NS" "STATUS" "INODE" "SHARED WITH"
sep

for ns in cgroup ipc mnt net pid uts user; do
  ns_path="/proc/$PID/ns/$ns"
  host_path="/proc/1/ns/$ns"

  if [[ ! -L "$ns_path" ]]; then
    printf "  %-10s %-12s %s\n" "$ns" "n/a" "(namespace file missing)"
    continue
  fi

  container_inode=$(readlink "$ns_path")
  host_inode=$(readlink "$host_path" 2>/dev/null || echo "unknown")

  if [[ "$container_inode" == "$host_inode" ]]; then
    printf "  ${YELLOW}%-10s${RESET} ${YELLOW}%-12s${RESET} %-30s ${DIM}%s${RESET}\n" \
      "$ns" "HOST" "$container_inode" "shared with host"
  else
    printf "  ${GREEN}%-10s${RESET} ${GREEN}%-12s${RESET} %-30s\n" \
      "$ns" "ISOLATED" "$container_inode"
  fi
done

# ── raw ns symlinks ───────────────────────────
hdr "§1b Raw namespace symlinks"
ls -la /proc/"$PID"/ns/ 2>/dev/null | tail -n +2 | while read -r line; do
  echo "  $line"
done

# ════════════════════════════════════════════
#  SECTION 2 — CGROUP MEMBERSHIP
# ════════════════════════════════════════════
hdr "§2  Cgroup membership"

CGROUP_FILE="/proc/$PID/cgroup"
if [[ ! -f "$CGROUP_FILE" ]]; then
  err "Cannot read $CGROUP_FILE"
else
  while IFS= read -r line; do
    echo "  $line"
  done < "$CGROUP_FILE"
fi

# ── detect cgroup v1 vs v2 ───────────────────
if grep -q "^0::" "$CGROUP_FILE" 2>/dev/null; then
  CGROUP_VERSION="v2 (unified)"
  CGROUP_PATH=$(awk -F: '/^0::/{print $3}' "$CGROUP_FILE")
  CGROUP_ROOT="/sys/fs/cgroup${CGROUP_PATH}"
else
  CGROUP_VERSION="v1 (legacy)"
  CGROUP_PATH=$(awk -F: '/memory/{print $3}' "$CGROUP_FILE" | head -1)
  CGROUP_ROOT="/sys/fs/cgroup/memory${CGROUP_PATH}"
fi

echo ""
ok "Cgroup version : $CGROUP_VERSION"
ok "Cgroup path    : ${CGROUP_PATH:-<not resolved>}"
ok "Cgroup root    : ${CGROUP_ROOT:-<not resolved>}"

# ════════════════════════════════════════════
#  SECTION 3 — CGROUP RESOURCE LIMITS
# ════════════════════════════════════════════
hdr "§3  Resource limits"

read_cg() {
  local file="$CGROUP_ROOT/$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo "<not set>"
  fi
}

# CPU
echo -e "  ${BOLD}CPU${RESET}"
if [[ "$CGROUP_VERSION" == v2* ]]; then
  row "cpu.max:"     "$(read_cg cpu.max)   (format: quota period)"
  row "cpu.weight:"  "$(read_cg cpu.weight)"
else
  row "cpu.cfs_quota_us:"  "$(read_cg cpu.cfs_quota_us)"
  row "cpu.cfs_period_us:" "$(read_cg cpu.cfs_period_us)"
  row "cpu.shares:"        "$(read_cg cpu.shares)"
fi

echo ""
# Memory
echo -e "  ${BOLD}Memory${RESET}"
if [[ "$CGROUP_VERSION" == v2* ]]; then
  row "memory.max:"     "$(read_cg memory.max)"
  row "memory.current:" "$(read_cg memory.current)"
  row "memory.high:"    "$(read_cg memory.high)"
  row "memory.swap.max:" "$(read_cg memory.swap.max)"
else
  row "memory.limit_in_bytes:"     "$(read_cg memory.limit_in_bytes)"
  row "memory.usage_in_bytes:"     "$(read_cg memory.usage_in_bytes)"
  row "memory.memsw.limit_in_bytes:" "$(read_cg memory.memsw.limit_in_bytes)"
fi

echo ""
# PIDs
echo -e "  ${BOLD}PIDs${RESET}"
row "pids.max:"     "$(read_cg pids.max)"
row "pids.current:" "$(read_cg pids.current)"

# ════════════════════════════════════════════
#  SECTION 4 — NETWORK (host-netns or isolated)
# ════════════════════════════════════════════
hdr "§4  Network — open ports"

NET_CONTAINER=$(readlink /proc/"$PID"/ns/net 2>/dev/null)
NET_HOST=$(readlink /proc/1/ns/net 2>/dev/null)

if [[ "$NET_CONTAINER" == "$NET_HOST" ]]; then
  warn "Container shares the HOST network namespace"
  echo -e "  ${DIM}Running ss directly on host:${RESET}"
  ss -tlnp 2>/dev/null | grep -E "(State|$(cat /proc/$PID/comm))" | while read -r line; do
    echo "  $line"
  done || true
else
  ok "Isolated network namespace — entering via nsenter"
  nsenter -t "$PID" -n -- ss -tlnp 2>/dev/null | while read -r line; do
    echo "  $line"
  done || warn "nsenter failed (distroless or permission denied)"
fi

# ════════════════════════════════════════════
#  SUMMARY
# ════════════════════════════════════════════
hdr "Summary"
row "Process:"     "$COMM  (PID $PID)"
row "Container:"   "${CONTAINER_ID:-<direct PID>}"
row "Cgroup:"      "$CGROUP_VERSION"
row "Cgroup path:" "${CGROUP_PATH:-<unknown>}"

HOST_NS_COUNT=0
ISOLATED_NS_COUNT=0
for ns in cgroup ipc mnt net pid uts user; do
  c=$(readlink /proc/"$PID"/ns/$ns 2>/dev/null || true)
  h=$(readlink /proc/1/ns/$ns 2>/dev/null || true)
  [[ "$c" == "$h" ]] && ((HOST_NS_COUNT++)) || ((ISOLATED_NS_COUNT++))
done
row "Namespaces:"  "${ISOLATED_NS_COUNT} isolated / ${HOST_NS_COUNT} shared with host"

echo ""