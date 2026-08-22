#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  container-enter.sh
#  Enters a running container's namespaces via nsenter, given its container
#  name (not full ID) as known to the container runtime — resolved via
#  crictl, same mechanism container-inspect.sh uses. Tries the container's
#  own shell first (bash, then sh); if it has none (e.g. a distroless/scratch
#  image), falls back to the HOST's shell running inside the container's
#  PID/UTS/IPC/network namespaces only — mount namespace left as the host's,
#  so the host shell binary can actually be found and exec'd. Same trick
#  container-inspect.sh's network section uses for `ss`.
#
#  Usage: ./container-enter.sh <container-name> [-s|--shell <path>] [--host-shell]
# ─────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok() { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}   $*"; }
err() { echo -e "  ${RED}✖${RESET}  $*" >&2; }

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 <container-name> [-s|--shell <path>] [--host-shell]"
    echo "  $0 -h | --help"
    echo
    echo "  <container-name>     container name as known to crictl (e.g. 'app', not the pod name)"
    echo "  -s, --shell <path>   shell to exec, skipping the bash/sh auto-probe"
    echo "  --host-shell         skip the container's own shell entirely; run the"
    echo "                       host's shell in the container's PID/UTS/IPC/net"
    echo "                       namespaces only (works even with no shell in the"
    echo "                       container image, e.g. distroless/scratch)"
    echo "  -h, --help"
    exit 0
}

NAME=""
SHELL_OVERRIDE=""
HOST_SHELL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
    -s | --shell)
        [[ -z "${2:-}" ]] && {
            err "--shell requires a value"
            exit 1
        }
        SHELL_OVERRIDE="$2"
        shift 2
        ;;
    --host-shell)
        HOST_SHELL=1
        shift
        ;;
    -h | --help) usage ;;
    -*)
        err "Unknown argument: $1"
        usage
        ;;
    *)
        if [[ -n "$NAME" ]]; then
            err "Unexpected extra argument: $1"
            usage
        fi
        NAME="$1"
        shift
        ;;
    esac
done

if [[ -z "$NAME" ]]; then
    err "Missing required <container-name> argument."
    usage
fi

missing=()
for dep in crictl jq nsenter; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    err "Must run as root (nsenter needs to attach to another process's namespaces) — try sudo."
    exit 1
fi

# ── resolve container name -> id -> pid ──────
matches_json="$(crictl ps --name "$NAME" -o json 2>/dev/null || echo '{"containers":[]}')"
match_count="$(echo "$matches_json" | jq '.containers | length')"

if [[ "$match_count" -eq 0 ]]; then
    err "No running container matching name '$NAME'. Try: crictl ps"
    exit 1
elif [[ "$match_count" -gt 1 ]]; then
    err "Multiple running containers match '$NAME' — be more specific:"
    echo "$matches_json" | jq -r '.containers[] | "  \(.id[0:13])  \(.metadata.name)  pod=\(.labels["io.kubernetes.pod.name"] // "-")"'
    exit 1
fi

container_id="$(echo "$matches_json" | jq -r '.containers[0].id')"
pid="$(crictl inspect "$container_id" 2>/dev/null | jq -r '.info.pid')"

if [[ -z "$pid" || "$pid" == "null" || ! -d "/proc/$pid" ]]; then
    err "Could not resolve a live PID for container '$NAME' ($container_id)."
    exit 1
fi

ok "Container: $NAME  (id: ${container_id:0:13}, pid: $pid)"

# ── enter ─────────────────────────────────────
if [[ -n "$SHELL_OVERRIDE" ]]; then
    exec nsenter --target "$pid" --mount --uts --ipc --net --pid -- "$SHELL_OVERRIDE"
fi

if [[ "$HOST_SHELL" -eq 0 ]]; then
    for sh in /bin/bash /bin/sh; do
        ok "Trying the container's own $sh"
        if nsenter --target "$pid" --mount --uts --ipc --net --pid -- "$sh"; then
            exit 0
        fi
    done
    warn "No shell found in the container (bash/sh) — falling back to the host's shell in its PID/UTS/IPC/net namespaces only."
fi

host_sh="${SHELL:-/bin/bash}"
command -v "$host_sh" &>/dev/null || host_sh="/bin/sh"
ok "Entering with host $host_sh (mount namespace left as the host's, so the host binary can exec)"
exec nsenter --target "$pid" --uts --ipc --net --pid -- "$host_sh"
