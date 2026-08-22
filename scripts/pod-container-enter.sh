#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  pod-container-enter.sh
#  Resolves a Kubernetes pod + container name to the node it's running on
#  and its exact container ID (via kubectl), SSHes onto that node, and runs
#  container-enter.sh there with --id (skipping crictl's name-based lookup
#  and its ambiguity entirely, since kubectl already gave an exact ID).
#
#  container-enter.sh is scp'd over rather than piped through the SSH
#  connection's stdin: piping a script via `ssh ... bash -s -- args < script`
#  consumes stdin transferring the script itself, so the interactive shell
#  nsenter hands back at the end would inherit an already-exhausted stdin,
#  not the terminal. scp keeps stdin free for that.
#
#  Usage: ./pod-container-enter.sh <pod> <container> [-n|--namespace <ns>]
#                                   [-c|--context <ctx>] [--ssh-user <user>]
#                                   [--ssh-key <path>] [--ssh-jump <host>]
#                                   [-s|--shell <path>] [--host-shell]
# ─────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok() { echo -e "  ${GREEN}✔${RESET}  $*"; }
err() { echo -e "  ${RED}✖${RESET}  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POD=""
CONTAINER=""
NAMESPACE=""
CONTEXT=""
SSH_USER=""
SSH_KEY=""
SSH_JUMP=""
SHELL_OVERRIDE=""
HOST_SHELL=0

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 <pod> <container> [-n|--namespace <ns>] [-c|--context <ctx>]"
    echo "         [--ssh-user <user>] [--ssh-key <path>] [--ssh-jump <host>]"
    echo "         [-s|--shell <path>] [--host-shell]"
    echo "  $0 -h | --help"
    echo
    echo "  <pod>                pod name"
    echo "  <container>          container name within that pod"
    echo "  -n, --namespace <ns> namespace the pod is in (default: current kubectl context namespace)"
    echo "  -c, --context <ctx>  kubectl context to use (default: current context)"
    echo "  --ssh-user <user>    SSH user for the node (default: none, i.e. your local default)"
    echo "  --ssh-key <path>     SSH private key to use"
    echo "  --ssh-jump <host>    SSH ProxyJump host (bastion), if the node isn't directly reachable"
    echo "  -s, --shell <path>   shell to exec in the container, skipping the bash/sh auto-probe"
    echo "  --host-shell         skip the container's own shell; use the node's shell instead"
    echo "                       (works even with no shell in the container image)"
    echo "  -h, --help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    -n | --namespace)
        [[ -z "${2:-}" ]] && {
            err "--namespace requires a value"
            exit 1
        }
        NAMESPACE="$2"
        shift 2
        ;;
    -c | --context)
        [[ -z "${2:-}" ]] && {
            err "--context requires a value"
            exit 1
        }
        CONTEXT="$2"
        shift 2
        ;;
    --ssh-user)
        [[ -z "${2:-}" ]] && {
            err "--ssh-user requires a value"
            exit 1
        }
        SSH_USER="$2"
        shift 2
        ;;
    --ssh-key)
        [[ -z "${2:-}" ]] && {
            err "--ssh-key requires a value"
            exit 1
        }
        SSH_KEY="$2"
        shift 2
        ;;
    --ssh-jump)
        [[ -z "${2:-}" ]] && {
            err "--ssh-jump requires a value"
            exit 1
        }
        SSH_JUMP="$2"
        shift 2
        ;;
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
        if [[ -z "$POD" ]]; then
            POD="$1"
        elif [[ -z "$CONTAINER" ]]; then
            CONTAINER="$1"
        else
            err "Unexpected extra argument: $1"
            usage
        fi
        shift
        ;;
    esac
done

if [[ -z "$POD" || -z "$CONTAINER" ]]; then
    err "Both <pod> and <container> are required."
    usage
fi

missing=()
for dep in kubectl jq ssh scp; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
fi

KCTL=(kubectl)
[[ -n "$CONTEXT" ]] && KCTL+=(--context "$CONTEXT")

if [[ -z "$NAMESPACE" ]]; then
    NAMESPACE="$("${KCTL[@]}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
    [[ -z "$NAMESPACE" ]] && NAMESPACE="default"
fi

# ── resolve pod -> node, container -> id ──────
pod_json="$("${KCTL[@]}" get pod "$POD" -n "$NAMESPACE" -o json 2>/dev/null)" || {
    err "Pod '$NAMESPACE/$POD' not found."
    exit 1
}

node_name="$(echo "$pod_json" | jq -r '.spec.nodeName // empty')"
if [[ -z "$node_name" ]]; then
    err "Pod '$NAMESPACE/$POD' has no assigned node yet (still Pending?)."
    exit 1
fi

container_id="$(echo "$pod_json" | jq -r --arg c "$CONTAINER" '
    [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[], (.status.ephemeralContainerStatuses // [])[]]
    | map(select(.name == $c)) | .[0].containerID // empty
    | sub("^[a-zA-Z0-9_-]+://"; "")')"

if [[ -z "$container_id" ]]; then
    err "No container named '$CONTAINER' in pod '$NAMESPACE/$POD'. Available containers:"
    echo "$pod_json" | jq -r '
        [(.spec.containers // [])[], (.spec.initContainers // [])[], (.spec.ephemeralContainers // [])[]]
        | .[].name' | sed 's/^/    /'
    exit 1
fi

# ── resolve node -> ssh target ────────────────
node_json="$("${KCTL[@]}" get node "$node_name" -o json 2>/dev/null)" || {
    err "Could not fetch node '$node_name'."
    exit 1
}
ssh_host="$(echo "$node_json" | jq -r '
    ([.status.addresses[]? | select(.type == "ExternalIP") | .address][0])
    // ([.status.addresses[]? | select(.type == "InternalIP") | .address][0])
    // empty')"

if [[ -z "$ssh_host" ]]; then
    err "Could not resolve an SSH-reachable address for node '$node_name' (no ExternalIP/InternalIP)."
    exit 1
fi

ok "Pod: $NAMESPACE/$POD  container: $CONTAINER  (id: ${container_id:0:13})"
ok "Node: $node_name  ($ssh_host)"

# ── ship container-enter.sh over and run it ──
ssh_target="${SSH_USER:+$SSH_USER@}$ssh_host"
SSH_ARGS=()
SCP_ARGS=()
[[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY") && SCP_ARGS+=(-i "$SSH_KEY")
[[ -n "$SSH_JUMP" ]] && SSH_ARGS+=(-J "$SSH_JUMP") && SCP_ARGS+=(-J "$SSH_JUMP")

remote_path="/tmp/.container-enter-$$.sh"
echo -e "  ${DIM}Copying container-enter.sh to $ssh_target:$remote_path${RESET}"
scp -q "${SCP_ARGS[@]}" "$SCRIPT_DIR/container-enter.sh" "$ssh_target:$remote_path"

remote_args=(--id "$container_id")
[[ -n "$SHELL_OVERRIDE" ]] && remote_args+=(-s "$SHELL_OVERRIDE")
[[ "$HOST_SHELL" -eq 1 ]] && remote_args+=(--host-shell)

trap 'ssh "${SSH_ARGS[@]}" "$ssh_target" rm -f "$remote_path" &>/dev/null || true' EXIT

ssh -t "${SSH_ARGS[@]}" "$ssh_target" sudo bash "$remote_path" "${remote_args[@]}"
