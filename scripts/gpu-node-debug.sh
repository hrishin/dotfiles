#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  gpu-node-debug.sh
#  Diagnoses GPU issues on Kubernetes GPU nodes:
#    - lists GPU nodes cluster-wide and GPU Operator daemonset/Helm config
#    - on a GPU node (or a `kubectl debug node/<name>` session), figures out
#      which containerd instance kubelet actually talks to (a node can run
#      more than one containerd), checks that instance's config for the
#      NVIDIA runtime class and verifies its runtime binary exists
#    - cross-checks GPU Operator Helm toolkit.env against what's actually
#      running, since a mismatched CONTAINERD_CONFIG/CONTAINERD_SOCKET means
#      the operator is patching a containerd instance kubelet never uses
#
#  Usage: ./gpu-node-debug.sh [-n|--namespace <ns>] [-c|--context <ctx>]
#                              [--host-root <path>] [-s|--since <journalctl-since>]
#                              [--nodes-only | --local-only]
# ─────────────────────────────────────────────
set -euo pipefail

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
err() { echo -e "  ${RED}✖${RESET}  $*"; }
row() { printf "  %-32s %s\n" "$1" "$2"; }

# Canonicalizes a socket/file path so e.g. /var/run/x and /run/x (a near-universal
# symlink on modern Linux) compare equal instead of looking like a mismatch.
resolve_path() {
    local p="$1" resolved
    resolved=$(readlink -f "$p" 2>/dev/null || true)
    if [[ -n "$resolved" ]]; then
        echo "$resolved"
    else
        echo "${p/#\/var\/run\//\/run\/}"
    fi
}

# Follows containerd v2's `imports = [...]` drop-in mechanism: GPU Operator's
# container-toolkit commonly writes the nvidia runtime block to a separate
# imported file (e.g. /etc/containerd/conf.d/99-nvidia.toml) rather than
# patching the top-level config.toml directly, so checking only that one
# file misses it. Prints each resolved, existing imported file, one per line.
expand_config_imports() {
    local cfg="$1" imports_line entry
    imports_line=$(grep -E '^[ \t]*imports[ \t]*=' "$cfg" 2>/dev/null | head -1)
    [[ -z "$imports_line" ]] && return 0
    imports_line=$(echo "$imports_line" | sed -E 's/.*\[(.*)\].*/\1/')
    IFS=',' read -ra entries <<<"$imports_line"
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | tr -d "\"'" | xargs)
        [[ -z "$entry" ]] && continue
        # shellcheck disable=SC2086 # intentional glob expansion of a conf.d/*.toml-style entry
        for f in ${HOST_ROOT}${entry}; do
            [[ -f "$f" ]] && echo "$f"
        done
    done
}

NAMESPACE="gpu-operator"
CONTEXT=""
HOST_ROOT=""
SINCE="1 hour ago"
RUN_CLUSTER=1
RUN_LOCAL=1
USE_DEBUG_POD=0
DEBUG_NODE=""
DEBUG_IMAGE="busybox:1.36"
DEBUG_WAIT_TIMEOUT=60
DEBUG_POD_TTL=1800

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 [-n|--namespace <ns>] [-c|--context <ctx>] [--host-root <path>]"
    echo "     [-s|--since <journalctl-since>] [--nodes-only | --local-only]"
    echo "     [--node <name> [--debug-image <image>]]"
    echo "  $0 -h | --help"
    echo
    echo "  -n, --namespace <ns>   namespace the GPU Operator runs in (default: gpu-operator)"
    echo "  -c, --context <ctx>    kubectl context to use (default: current context)"
    echo "  --host-root <path>     prefix for host paths, e.g. /host inside an unchrooted"
    echo "                         'kubectl debug node/<name>' pod (default: none — run"
    echo "                         directly on the node, or inside a chroot /host session)"
    echo "  -s, --since <since>    journalctl --since value for containerd log scan"
    echo "                         (default: \"1 hour ago\")"
    echo "  --nodes-only            only run the cluster-wide GPU node/operator overview"
    echo "  --local-only            only run the local kubelet/containerd diagnosis"
    echo "  --node <name>           run the local diagnosis on <name> via a 'kubectl debug"
    echo "                         node' session instead of SSH — no node shell access"
    echo "                         needed, just kubectl. Implies --debug-pod; the debug"
    echo "                         pod is deleted when the script exits."
    echo "  --debug-pod             same as passing --node — kept for explicitness"
    echo "  --debug-image <image>   image for the debug pod (default: busybox:1.36) —"
    echo "                         only needs a shell and 'chroot'"
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
    --host-root)
        [[ -z "${2:-}" ]] && {
            err "--host-root requires a value"
            exit 1
        }
        HOST_ROOT="${2%/}"
        shift 2
        ;;
    -s | --since)
        [[ -z "${2:-}" ]] && {
            err "--since requires a value"
            exit 1
        }
        SINCE="$2"
        shift 2
        ;;
    --nodes-only)
        RUN_LOCAL=0
        shift
        ;;
    --local-only)
        RUN_CLUSTER=0
        shift
        ;;
    --debug-pod)
        USE_DEBUG_POD=1
        shift
        ;;
    --node)
        [[ -z "${2:-}" ]] && {
            err "--node requires a value"
            exit 1
        }
        DEBUG_NODE="$2"
        USE_DEBUG_POD=1
        shift 2
        ;;
    --debug-image)
        [[ -z "${2:-}" ]] && {
            err "--debug-image requires a value"
            exit 1
        }
        DEBUG_IMAGE="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *)
        err "Unknown argument: $1"
        usage
        ;;
    esac
done

if [[ "$USE_DEBUG_POD" -eq 1 && -z "$DEBUG_NODE" ]]; then
    err "--debug-pod requires --node <name>."
    exit 1
fi

SELF_SCRIPT="${BASH_SOURCE[0]:-$0}"

KCTL=(kubectl)
[[ -n "$CONTEXT" ]] && KCTL+=(--context "$CONTEXT")

# Runs the local diagnosis (§5-§10) on a remote node without SSH, via a
# 'kubectl debug node' session: creates a short-lived debug pod (hostPID +
# host filesystem mounted at /host), chroots into /host so all host binaries
# (ps, nvidia-smi, journalctl, awk) resolve normally, then pipes this same
# script into it over `kubectl exec -i` so the local sections run unmodified.
# The debug pod is always deleted on the way out, success or failure.
run_local_via_debug_pod() {
    local node="$1" pod_name="" phase="" waited=0 create_out

    cleanup_debug_pod() {
        [[ -z "$pod_name" ]] && return
        "${KCTL[@]}" delete pod "$pod_name" --now --wait=false &>/dev/null || true
    }
    trap cleanup_debug_pod RETURN

    ok "Launching a debug pod on node '$node' (image: $DEBUG_IMAGE, profile: general)..."
    # --stdin/--tty/--attach are spelled out (not the combined `-it` shorthand,
    # which pflag can parse ambiguously) and stdin is hard-redirected from
    # /dev/null so this can never block waiting to attach to the pod.
    if ! create_out=$("${KCTL[@]}" debug "node/$node" --stdin=false --tty=false --attach=false \
        --image="$DEBUG_IMAGE" --profile=general -- sh -c "sleep $DEBUG_POD_TTL" </dev/null 2>&1); then
        err "Failed to create debug pod on node $node:"
        echo "$create_out" | sed 's/^/  /'
        return 1
    fi
    pod_name=$(echo "$create_out" | grep -oE 'node-debugger-[a-zA-Z0-9.-]+' | head -1)
    if [[ -z "$pod_name" ]]; then
        err "Could not determine the debug pod's name from kubectl output:"
        echo "$create_out" | sed 's/^/  /'
        return 1
    fi
    row "Debug pod:" "$pod_name"

    while [[ "$waited" -lt "$DEBUG_WAIT_TIMEOUT" ]]; do
        phase=$("${KCTL[@]}" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [[ "$phase" == "Running" ]] && break
        sleep 2
        waited=$((waited + 2))
    done
    if [[ "$phase" != "Running" ]]; then
        err "Debug pod did not reach Running within ${DEBUG_WAIT_TIMEOUT}s (last phase: ${phase:-unknown})."
        return 1
    fi
    ok "Debug pod is Running — chrooting into /host and running the local diagnosis..."
    echo

    "${KCTL[@]}" exec -i "$pod_name" -- chroot /host bash -s -- --local-only <"$SELF_SCRIPT" ||
        warn "Diagnostics inside the debug pod exited non-zero."
}

if [[ "$RUN_CLUSTER" -eq 1 ]]; then
    if ! command -v kubectl &>/dev/null || ! command -v jq &>/dev/null; then
        warn "kubectl and/or jq not found — skipping cluster-wide sections."
        RUN_CLUSTER=0
    elif ! "${KCTL[@]}" cluster-info --request-timeout=5s &>/dev/null; then
        warn "Cannot reach the cluster (check kubeconfig/context/VPN) — skipping cluster-wide sections."
        RUN_CLUSTER=0
    fi
fi

# Values captured below, used later for the Helm-vs-detected cross-check.
CONTAINERD_CONFIG_HELM=""
CONTAINERD_SOCKET_HELM=""
MIG_MANAGER_ENABLED_HELM=""
MIG_STRATEGY_HELM=""
SOCK_PATH=""
MATCHED_CONFIG=""

# ── §1 cluster: GPU nodes ────────────────────
if [[ "$RUN_CLUSTER" -eq 1 ]]; then
    hdr "§1  GPU nodes (cluster-wide)"
    NODES_JSON=$("${KCTL[@]}" get nodes -o json 2>/dev/null || echo '{"items":[]}')
    GPU_NODES=$(echo "$NODES_JSON" | jq -r '
        .items[]
        | select(
            (.status.allocatable["nvidia.com/gpu"] != null)
            or ((.status.allocatable // {}) | keys | any(startswith("nvidia.com/mig-")))
          )
        | .metadata.name')

    if [[ -z "$GPU_NODES" ]]; then
        warn "No nodes advertise an nvidia.com/gpu or nvidia.com/mig-* allocatable resource."
    else
        printf "  %-45s %-8s %-10s %-10s %s\n" "NODE" "READY" "GPU ALLOC" "GPU CAP" "GPU PODS"
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            ready=$(echo "$NODES_JSON" | jq -r --arg n "$node" \
                '.items[] | select(.metadata.name==$n) | .status.conditions[]? | select(.type=="Ready") | .status')
            alloc=$(echo "$NODES_JSON" | jq -r --arg n "$node" \
                '.items[] | select(.metadata.name==$n) | .status.allocatable["nvidia.com/gpu"] // "0"')
            cap=$(echo "$NODES_JSON" | jq -r --arg n "$node" \
                '.items[] | select(.metadata.name==$n) | .status.capacity["nvidia.com/gpu"] // "0"')
            mig_profiles=$(echo "$NODES_JSON" | jq -r --arg n "$node" '
                .items[] | select(.metadata.name==$n)
                | (.status.allocatable // {}) as $alloc
                | (.status.capacity // {}) as $cap
                | ($alloc | keys[] | select(startswith("nvidia.com/mig-"))) as $k
                | "\($k): \($alloc[$k])/\($cap[$k] // $alloc[$k]) allocatable/capacity"')
            gpu_pods=$("${KCTL[@]}" get pods -A --field-selector "spec.nodeName=$node" -o json 2>/dev/null | jq '[
                .items[]
                | select(
                    [.spec.containers[]?.resources.requests? // {} | keys[]?]
                    | any(. == "nvidia.com/gpu" or startswith("nvidia.com/mig-"))
                  )
              ] | length')
            display_alloc="$alloc"
            display_cap="$cap"
            [[ -n "$mig_profiles" ]] && display_alloc="MIG" && display_cap="MIG"
            color="$GREEN"
            [[ "$ready" != "True" ]] && color="$RED"
            printf "  %-45s ${color}%-8s${RESET} %-10s %-10s %s\n" "$node" "${ready:-Unknown}" "$display_alloc" "$display_cap" "$gpu_pods"
            if [[ -n "$mig_profiles" ]]; then
                echo "$mig_profiles" | sed 's/^/      /'
            fi
        done <<<"$GPU_NODES"
    fi

    # ── §2 cluster: GPU operator daemonsets ──
    hdr "§2  GPU Operator daemonsets (namespace: $NAMESPACE)"
    for ds in nvidia-device-plugin-daemonset nvidia-container-toolkit-daemonset; do
        ds_json=$("${KCTL[@]}" get daemonset "$ds" -n "$NAMESPACE" -o json 2>/dev/null || true)
        if [[ -z "$ds_json" ]]; then
            warn "$ds not found in namespace $NAMESPACE"
            continue
        fi
        desired=$(echo "$ds_json" | jq -r '.status.desiredNumberScheduled // 0')
        ready=$(echo "$ds_json" | jq -r '.status.numberReady // 0')
        avail=$(echo "$ds_json" | jq -r '.status.numberAvailable // 0')
        if [[ "$desired" -gt 0 && "$ready" -eq "$desired" ]]; then
            ok "$ds: $ready/$desired ready"
        else
            warn "$ds: $ready/$desired ready (available: $avail)"
        fi
    done

    # ── §3 cluster: GPU operator Helm config ─
    hdr "§3  GPU Operator Helm configuration (namespace: $NAMESPACE)"
    if ! command -v helm &>/dev/null; then
        warn "helm not found — skipping GPU Operator Helm configuration check."
    else
        RELEASE=$(helm list -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.[] | select(.name | test("gpu-operator")) | .name' | head -1 || true)
        if [[ -z "$RELEASE" ]]; then
            warn "No Helm release matching 'gpu-operator' found in namespace $NAMESPACE."
        else
            ok "Helm release: $RELEASE"
            VALUES_JSON=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null || true)
            if [[ -z "$VALUES_JSON" ]]; then
                warn "Could not read Helm values for release $RELEASE."
            else
                TOOLKIT_ENABLED=$(echo "$VALUES_JSON" | jq -r '.toolkit.enabled // "unset"')
                CONTAINERD_CONFIG_HELM=$(echo "$VALUES_JSON" | jq -r '.toolkit.env[]? | select(.name=="CONTAINERD_CONFIG") | .value // empty')
                CONTAINERD_SOCKET_HELM=$(echo "$VALUES_JSON" | jq -r '.toolkit.env[]? | select(.name=="CONTAINERD_SOCKET") | .value // empty')
                RUNTIME_CLASS_HELM=$(echo "$VALUES_JSON" | jq -r '.toolkit.env[]? | select(.name=="CONTAINERD_RUNTIME_CLASS") | .value // empty')
                MIG_MANAGER_ENABLED_HELM=$(echo "$VALUES_JSON" | jq -r '.migManager.enabled // "unset"')
                MIG_STRATEGY_HELM=$(echo "$VALUES_JSON" | jq -r '.mig.strategy // "unset"')
                row "toolkit.enabled:" "$TOOLKIT_ENABLED"
                row "toolkit.env CONTAINERD_CONFIG:" "${CONTAINERD_CONFIG_HELM:-<not set>}"
                row "toolkit.env CONTAINERD_SOCKET:" "${CONTAINERD_SOCKET_HELM:-<not set>}"
                row "toolkit.env CONTAINERD_RUNTIME_CLASS:" "${RUNTIME_CLASS_HELM:-<not set>}"
                row "migManager.enabled:" "$MIG_MANAGER_ENABLED_HELM"
                row "mig.strategy:" "$MIG_STRATEGY_HELM"
                if [[ "$MIG_MANAGER_ENABLED_HELM" == "false" ]]; then
                    warn "migManager disabled — MIG is managed manually on the host. After carving slices"
                    warn "with 'nvidia-smi mig -cgi ... -C', force kubelet to pick them up:"
                    warn "  kubectl rollout restart daemonset -n $NAMESPACE nvidia-device-plugin-daemonset"
                fi
            fi
        fi
    fi

    # ── §4 cluster: MIG configuration (node labels) ──
    hdr "§4  MIG configuration (node labels)"
    if [[ -z "$GPU_NODES" ]]; then
        warn "No GPU nodes to check MIG labels on."
    else
        printf "  %-40s %-18s %-14s %s\n" "NODE" "mig.config" "config.state" "NOTE"
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            node_labels=$("${KCTL[@]}" get node "$node" -o json 2>/dev/null | jq -r '.metadata.labels // {}')
            mig_config=$(echo "$node_labels" | jq -r '."nvidia.com/mig.config" // empty')
            mig_state=$(echo "$node_labels" | jq -r '."nvidia.com/mig.config.state" // empty')
            note="reconciled"
            color="$GREEN"
            if [[ -z "$mig_config" ]]; then
                note="no mig.config label — manager targets 'all-disabled' by default, will wipe manual MIG slices"
                color="$RED"
            elif [[ "$mig_state" == "failed" ]]; then
                note="reconciliation FAILED — restart nvidia-mig-manager DS or toggle the label to retrigger"
                color="$RED"
            elif [[ "$mig_state" == "pending" || "$mig_state" == "rebooting" ]]; then
                note="reconciliation in progress ($mig_state)"
                color="$YELLOW"
            elif [[ "$mig_state" != "success" ]]; then
                note="no config.state label yet"
                color="$YELLOW"
            fi
            printf "  %-40s ${color}%-18s %-14s${RESET} %s\n" "$node" "${mig_config:-<none>}" "${mig_state:-<none>}" "$note"
        done <<<"$GPU_NODES"
    fi
fi

# ── §5 local: kubelet → containerd socket ────
if [[ "$RUN_LOCAL" -eq 1 && "$USE_DEBUG_POD" -eq 1 ]]; then
    # The nested invocation below (piped into `kubectl exec`) prints its own
    # §5-§10 headers as it streams back, so no header is emitted out here.
    run_local_via_debug_pod "$DEBUG_NODE"
elif [[ "$RUN_LOCAL" -eq 1 ]]; then
    hdr "§5  Local node: kubelet's containerd endpoint"
    KUBELET_CONF="${HOST_ROOT}/var/lib/kubelet/config.yaml"

    if [[ ! -f "$KUBELET_CONF" ]]; then
        warn "No kubelet config at $KUBELET_CONF — this doesn't look like a GPU node."
        warn "SSH onto a GPU node, or pass --node <name> to run this diagnosis via a"
        warn "'kubectl debug node' session instead (no SSH needed) — or run inside"
        warn "'kubectl debug node/<name> -- chroot /host' yourself with --host-root /host."
    else
        ENDPOINT=$(awk -F': ' '/^containerRuntimeEndpoint:/{gsub(/"/, "", $2); print $2}' "$KUBELET_CONF" 2>/dev/null || true)
        if [[ -z "$ENDPOINT" ]]; then
            KUBELET_ARGS=$(ps -eo args 2>/dev/null | grep '[k]ubelet ' | head -1 || true)
            ENDPOINT=$(echo "$KUBELET_ARGS" | grep -oE -- '--container-runtime-endpoint=[^ ]+' | cut -d= -f2 || true)
        fi
        ENDPOINT="${ENDPOINT:-unix:///run/containerd/containerd.sock}"
        SOCK_PATH=$(resolve_path "${ENDPOINT#unix://}")
        ok "kubelet container runtime endpoint: $ENDPOINT"
        row "kubelet config:" "$KUBELET_CONF"

        # ── §6 local: containerd instances on this node ──
        hdr "§6  Containerd instances on this node"
        SHIM_ADDRS=$(ps -eo args 2>/dev/null | grep '[c]ontainerd-shim' |
            grep -oE -- '-address [^ ]+' | awk '{print $2}' | sort | uniq -c | sort -rn || true)

        if [[ -z "$SHIM_ADDRS" ]]; then
            warn "No containerd-shim processes found — no containers currently running under containerd?"
        else
            echo "  Sockets serving running containers (from containerd-shim -address):"
            while read -r count addr; do
                [[ -z "$addr" ]] && continue
                if [[ "$(resolve_path "$addr")" == "$SOCK_PATH" ]]; then
                    echo -e "    ${GREEN}✔${RESET} $addr  ${DIM}($count shim(s) — matches kubelet's endpoint)${RESET}"
                else
                    echo -e "    ${YELLOW}⚠${RESET} $addr  ${DIM}($count shim(s) — NOT kubelet's endpoint)${RESET}"
                fi
            done <<<"$SHIM_ADDRS"
        fi

        echo
        echo "  containerd daemon processes:"
        MATCHED_PID=""
        while read -r pid args; do
            [[ -z "$pid" ]] && continue
            cfg=$(echo "$args" | grep -oE -- '--config(=| )[^ ]+' | sed -E 's/--config(=| )//' || true)
            cfg="${cfg:-${HOST_ROOT}/etc/containerd/config.toml}"
            addr=$(echo "$args" | grep -oE -- '--address(=| )[^ ]+' | sed -E 's/--address(=| )//' || true)
            if [[ -z "$addr" && -f "$cfg" ]]; then
                addr=$(awk '
                    /^\[grpc\]/ { in_grpc=1; next }
                    /^\[/ { in_grpc=0 }
                    in_grpc && /^[ \t]*address[ \t]*=/ {
                        gsub(/["'"'"']/, "")
                        sub(/^[ \t]*address[ \t]*=[ \t]*/, "")
                        print; exit
                    }' "$cfg" 2>/dev/null || true)
            fi
            addr="${addr:-/run/containerd/containerd.sock}"
            marker=""
            if [[ "$(resolve_path "$addr")" == "$SOCK_PATH" ]]; then
                marker="${GREEN}✔ used by kubelet${RESET}"
                MATCHED_PID="$pid"
                MATCHED_CONFIG="$cfg"
            fi
            printf "    pid %-8s config=%-50s address=%-40s %b\n" "$pid" "$cfg" "$addr" "$marker"
        done < <(ps -eo pid,args 2>/dev/null | grep -E '/containerd($| )' | grep -v containerd-shim || true)

        if [[ -z "$MATCHED_PID" ]]; then
            warn "Could not determine which containerd process owns kubelet's socket ($SOCK_PATH)."
        else
            ok "kubelet's containerd instance: pid $MATCHED_PID, config: $MATCHED_CONFIG"
        fi

        # ── §7 local: NVIDIA runtime configuration ──
        hdr "§7  NVIDIA runtime configuration"
        CONFIGS_TO_CHECK=()
        if [[ -n "$MATCHED_CONFIG" ]]; then
            CONFIGS_TO_CHECK+=("$MATCHED_CONFIG")
        else
            for p in "${HOST_ROOT}/etc/containerd/config.toml" "${HOST_ROOT}/var/lib/rancher/k3s/agent/etc/containerd/config.toml"; do
                [[ -f "$p" ]] && CONFIGS_TO_CHECK+=("$p")
            done
        fi

        IMPORT_BASE_COUNT=${#CONFIGS_TO_CHECK[@]}
        for ((ci = 0; ci < IMPORT_BASE_COUNT; ci++)); do
            while IFS= read -r imported; do
                [[ -z "$imported" ]] && continue
                already=0
                for existing in "${CONFIGS_TO_CHECK[@]}"; do
                    [[ "$existing" == "$imported" ]] && already=1 && break
                done
                [[ "$already" -eq 0 ]] && CONFIGS_TO_CHECK+=("$imported")
            done < <(expand_config_imports "${CONFIGS_TO_CHECK[$ci]}")
        done

        if [[ ${#CONFIGS_TO_CHECK[@]} -eq 0 ]]; then
            warn "No containerd config.toml found to inspect."
        else
            for cfg in "${CONFIGS_TO_CHECK[@]}"; do
                echo -e "  ${BOLD}$cfg${RESET}"
                if grep -qE 'runtimes\.nvidia|"nvidia"' "$cfg" 2>/dev/null; then
                    ok "  NVIDIA runtime class found in config"
                    BINARY=$(awk '
                        /runtimes\.nvidia/ { in_nv=1 }
                        in_nv && /BinaryName/ {
                            gsub(/["'"'"']/, "")
                            sub(/.*=[ \t]*/, "")
                            print; exit
                        }' "$cfg" 2>/dev/null || true)
                    if [[ -n "$BINARY" ]]; then
                        row "  BinaryName:" "$BINARY"
                        BIN_PATH="${HOST_ROOT}${BINARY}"
                        if [[ -x "$BIN_PATH" ]]; then
                            ok "  binary exists and is executable: $BIN_PATH"
                        else
                            err "  binary NOT found/executable at: $BIN_PATH"
                        fi
                    else
                        warn "  Could not extract BinaryName from the nvidia runtime block."
                    fi
                else
                    warn "  No NVIDIA runtime class configured in this file."
                fi
            done
        fi

        # ── §8 local: NVIDIA devices & driver ──
        hdr "§8  NVIDIA devices & driver"
        DEV_LIST=$(ls -la "${HOST_ROOT}/dev"/nvidia* 2>/dev/null || true)
        if [[ -z "$DEV_LIST" ]]; then
            warn "No ${HOST_ROOT}/dev/nvidia* device nodes found."
        else
            echo "$DEV_LIST" | sed 's/^/  /'
        fi
        echo
        if command -v nvidia-smi &>/dev/null; then
            nvidia-smi 2>&1 | sed 's/^/  /' || warn "nvidia-smi failed to run."
        else
            warn "nvidia-smi not found on PATH (driver may only be installed inside the toolkit container)."
        fi

        # ── §9 local: containerd journal errors ──
        hdr "§9  containerd journal — recent NVIDIA/runtime errors (since \"$SINCE\")"
        if command -v journalctl &>/dev/null; then
            ERRORS=$(journalctl -u containerd --since "$SINCE" --no-pager -q 2>/dev/null |
                grep -iE 'nvidia|runtime' | grep -i error | tail -n 20 || true)
            if [[ -z "$ERRORS" ]]; then
                ok "No nvidia/runtime error lines in the containerd journal."
            else
                echo "$ERRORS" | sed 's/^/  /'
            fi
        else
            warn "journalctl not found — skipping (expected inside unprivileged debug containers)."
        fi

        # ── §10 local: MIG hardware state ──
        hdr "§10  MIG hardware state (this node)"
        if ! command -v nvidia-smi &>/dev/null; then
            warn "nvidia-smi not found — skipping MIG hardware state check."
        else
            MIG_MODE=$(nvidia-smi --query-gpu=index,mig.mode.current --format=csv,noheader 2>/dev/null || true)
            if [[ -z "$MIG_MODE" ]]; then
                warn "Could not query MIG mode from nvidia-smi."
            else
                echo "  MIG mode per GPU:"
                echo "$MIG_MODE" | sed 's/^/    /'
            fi

            echo
            echo "  GPU Instances (nvidia-smi mig -lgi):"
            GI_OUT=$(nvidia-smi mig -lgi 2>&1 || true)
            echo "$GI_OUT" | sed 's/^/    /'

            echo
            echo "  Compute Instances (nvidia-smi mig -lci):"
            CI_OUT=$(nvidia-smi mig -lci 2>&1 || true)
            echo "$CI_OUT" | sed 's/^/    /'

            # Pitfall A: a node with manually-carved GIs but no mig.config label will be
            # reset to 'all-disabled' the moment the MIG Manager starts watching it.
            HAS_MANUAL_GI=0
            echo "$GI_OUT" | grep -qE '^\| *[0-9]+ +MIG' && HAS_MANUAL_GI=1
            if [[ "$HAS_MANUAL_GI" -eq 1 ]]; then
                NODE_HOSTNAME=$(hostname 2>/dev/null || true)
                if [[ "$RUN_CLUSTER" -eq 1 && -n "$NODE_HOSTNAME" ]]; then
                    NODE_LABELS=$("${KCTL[@]}" get node "$NODE_HOSTNAME" -o json 2>/dev/null || true)
                    LOCAL_MIG_LABEL=""
                    LOCAL_MIG_STATE=""
                    if [[ -n "$NODE_LABELS" ]]; then
                        LOCAL_MIG_LABEL=$(echo "$NODE_LABELS" | jq -r '.metadata.labels["nvidia.com/mig.config"] // empty')
                        LOCAL_MIG_STATE=$(echo "$NODE_LABELS" | jq -r '.metadata.labels["nvidia.com/mig.config.state"] // empty')
                    fi
                    if [[ -z "$LOCAL_MIG_LABEL" ]]; then
                        err "GPU Instances exist on this host, but node '$NODE_HOSTNAME' has NO nvidia.com/mig.config label."
                        err "The MIG Manager treats 'no label' as target 'all-disabled' — it will tear these"
                        err "down the moment it starts watching this node. Label it BEFORE it reconciles:"
                        err "  kubectl label node $NODE_HOSTNAME nvidia.com/mig.config=<profile> --overwrite"
                    else
                        ok "Node '$NODE_HOSTNAME' mig.config=$LOCAL_MIG_LABEL, mig.config.state=${LOCAL_MIG_STATE:-<none>}"
                    fi
                else
                    warn "GPU Instances exist on this host — verify the node has a matching nvidia.com/mig.config"
                    warn "label (missing label = MIG Manager targets 'all-disabled' on its next reconcile)."
                fi

                # Pitfall B: the manager only reacts to node-label events, not to nvidia-smi
                # changes made directly on the host — it can't tell these GIs were hand-carved.
                warn "Reminder: the MIG Manager reacts to node-label events only, not to hardware state."
                warn "If this layout was set/changed directly via nvidia-smi (not via the mig.config"
                warn "label), the manager has no way to notice and its logs will look idle. To force"
                warn "a re-evaluation:"
                warn "  kubectl rollout restart daemonset -n $NAMESPACE nvidia-mig-manager"
                warn "  # or toggle the label to retrigger the watch loop:"
                warn "  kubectl label node <node-name> nvidia.com/mig.config=all-disabled --overwrite"
                warn "  kubectl label node <node-name> nvidia.com/mig.config=<profile> --overwrite"
            fi

            # Pitfall C: the GI/CI hierarchy is enforced — a CI must be destroyed before its
            # GI, and a GI with a running pod on it can't be destroyed until the pod is evicted.
            if echo "$GI_OUT$CI_OUT" | grep -qi 'in use by another client'; then
                err "A GPU/Compute Instance operation failed with 'In use by another client' — the"
                err "GI/CI hierarchy is enforced: delete Compute Instances first (nvidia-smi mig -dci),"
                err "then the GPU Instance (nvidia-smi mig -dgi), evicting any pod on the slice first."
            fi
        fi
    fi
fi

# ── §11 cross-check: Helm config vs. detected containerd ──
if [[ "$RUN_CLUSTER" -eq 1 && "$RUN_LOCAL" -eq 1 ]]; then
    hdr "§11  Cross-check: Helm toolkit config vs. detected containerd"
    if [[ -z "$CONTAINERD_SOCKET_HELM" && -z "$CONTAINERD_CONFIG_HELM" ]]; then
        warn "No Helm toolkit.env values captured — nothing to cross-check."
    elif [[ -z "$SOCK_PATH" ]]; then
        warn "Local kubelet/containerd detection didn't run — nothing to cross-check."
    else
        if [[ -n "$CONTAINERD_SOCKET_HELM" ]]; then
            if [[ "$CONTAINERD_SOCKET_HELM" == "$SOCK_PATH" ]]; then
                ok "Helm CONTAINERD_SOCKET matches kubelet's actual socket."
            else
                err "Helm toolkit.env CONTAINERD_SOCKET ($CONTAINERD_SOCKET_HELM) != kubelet's socket ($SOCK_PATH)."
                err "GPU Operator is likely patching a containerd instance kubelet never talks to."
            fi
        fi
        if [[ -n "$CONTAINERD_CONFIG_HELM" && -n "$MATCHED_CONFIG" ]]; then
            if [[ "$CONTAINERD_CONFIG_HELM" == "$MATCHED_CONFIG" ]]; then
                ok "Helm CONTAINERD_CONFIG matches kubelet's containerd config."
            else
                err "Helm toolkit.env CONTAINERD_CONFIG ($CONTAINERD_CONFIG_HELM) != kubelet's config ($MATCHED_CONFIG)."
            fi
        fi
    fi
fi

echo
