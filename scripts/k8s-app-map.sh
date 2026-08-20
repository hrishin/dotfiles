#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  k8s-app-map.sh
#  Traces the full request path for an app, in sequence:
#    Ingress/HTTPRoute -> Service (name, path, port, targetPort)
#    -> Endpoints (ip) -> Pod (name, container, listening port, node name)
#    -> Node (ip, status) -> NetworkPolicy (ingress rules reaching the pod)
#  Along the way it flags likely misconfigurations: a Service selector that
#  matches no Pods, a targetPort that no container actually listens on, an
#  Ingress/HTTPRoute backend port that isn't one of the Service's ports, a
#  readiness/liveness probe port that doesn't match a container port, and
#  (with --from-*) a NetworkPolicy that would block the given caller.
#
#  Usage: ./k8s-app-map.sh <app> [-n|--namespace <ns>] [-A|--all-namespaces]
#                           [-l|--selector <key=value>] [-c|--context <kube-context>]
#                           [--from-ns <namespace>] [--from-labels <k=v,k=v>]
#                           [--from-ip <ip>]
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
err() { echo -e "  ${RED}✖${RESET}  $*" >&2; }
issue() { echo -e "  ${RED}${BOLD}✖ MISMATCH${RESET}  $*"; }

APP=""
NAMESPACE=""
ALL_NAMESPACES=0
SELECTOR=""
CONTEXT=""
FROM_NS=""
FROM_LABELS=""
FROM_IP=""

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 <app> [-n|--namespace <ns>] [-A|--all-namespaces] [-l|--selector <key=value>] [-c|--context <kube-context>]"
    echo "         [--from-ns <namespace>] [--from-labels <k=v,k=v>] [--from-ip <ip>]"
    echo "  $0 -h | --help"
    echo
    echo "  <app>                    app name; matched against the app / app.kubernetes.io/name /"
    echo "                           app.kubernetes.io/instance labels on Services, falling back to"
    echo "                           a substring match on Service name if none of those hit"
    echo "  -n, --namespace <ns>     namespace to search (default: current kubectl context namespace)"
    echo "  -A, --all-namespaces     search Services across all namespaces"
    echo "  -l, --selector <k=v>     use this exact label selector instead of the app-name guesswork"
    echo "  -c, --context <ctx>      kubectl context to use (default: current context)"
    echo "  --from-ns <ns>           caller's namespace, to test NetworkPolicy ingress rules against"
    echo "  --from-labels <k=v,..>   caller's pod labels, to test NetworkPolicy podSelector rules against"
    echo "  --from-ip <ip>           caller's IP, to test NetworkPolicy ipBlock rules against"
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
    -A | --all-namespaces)
        ALL_NAMESPACES=1
        shift
        ;;
    -l | --selector)
        [[ -z "${2:-}" ]] && {
            err "--selector requires a value"
            exit 1
        }
        SELECTOR="$2"
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
    --from-ns)
        [[ -z "${2:-}" ]] && {
            err "--from-ns requires a value"
            exit 1
        }
        FROM_NS="$2"
        shift 2
        ;;
    --from-labels)
        [[ -z "${2:-}" ]] && {
            err "--from-labels requires a value"
            exit 1
        }
        FROM_LABELS="$2"
        shift 2
        ;;
    --from-ip)
        [[ -z "${2:-}" ]] && {
            err "--from-ip requires a value"
            exit 1
        }
        FROM_IP="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    -*)
        err "Unknown argument: $1"
        usage
        ;;
    *)
        if [[ -n "$APP" ]]; then
            err "Unexpected extra argument: $1"
            usage
        fi
        APP="$1"
        shift
        ;;
    esac
done

if [[ -z "$APP" ]]; then
    err "Missing required <app> argument."
    usage
fi

# ── check dependencies ───────────────────────
missing=()
for dep in kubectl jq; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
fi

KCTL=(kubectl)
[[ -n "$CONTEXT" ]] && KCTL+=(--context "$CONTEXT")

if ! "${KCTL[@]}" cluster-info --request-timeout=5s &>/dev/null; then
    err "Cannot reach the cluster (check kubeconfig/context/VPN)."
    exit 1
fi

FROM_NS_LABELS_JSON="{}"
if [[ -n "$FROM_NS" ]]; then
    FROM_NS_LABELS_JSON="$("${KCTL[@]}" get ns "$FROM_NS" -o json 2>/dev/null | jq -c '.metadata.labels // {}')"
    if [[ -z "$FROM_NS_LABELS_JSON" || "$FROM_NS_LABELS_JSON" == "null" ]]; then
        warn "--from-ns '$FROM_NS' not found on the cluster; namespaceSelector rules won't match it."
        FROM_NS_LABELS_JSON="{}"
    fi
fi

if [[ "$ALL_NAMESPACES" -eq 1 ]]; then
    NS_ARGS=(-A)
else
    if [[ -z "$NAMESPACE" ]]; then
        NAMESPACE="$("${KCTL[@]}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
        [[ -z "$NAMESPACE" ]] && NAMESPACE="default"
    fi
    NS_ARGS=(-n "$NAMESPACE")
fi

HAS_HTTPROUTE=0
if "${KCTL[@]}" api-resources --api-group=gateway.networking.k8s.io -o name 2>/dev/null | grep -q '^httproutes\.'; then
    HAS_HTTPROUTE=1
fi

HAS_CILIUM_NP=0
HAS_CILIUM_CCNP=0
if "${KCTL[@]}" api-resources --api-group=cilium.io -o name 2>/dev/null | grep -q '^ciliumnetworkpolicies\.'; then
    HAS_CILIUM_NP=1
fi
if "${KCTL[@]}" api-resources --api-group=cilium.io -o name 2>/dev/null | grep -q '^ciliumclusterwidenetworkpolicies\.'; then
    HAS_CILIUM_CCNP=1
fi

NODES_JSON="$("${KCTL[@]}" get nodes -o json 2>/dev/null || echo '{"items":[]}')"

node_info() {
    local name="$1"
    echo "$NODES_JSON" | jq -r --arg n "$name" '
        .items[] | select(.metadata.name == $n)
        | ([.status.addresses[]? | select(.type == "InternalIP") | .address][0] // "-") as $ip
        | ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown") as $ready
        | "\($ip)\t\($ready)"' | head -n1
}

# Flags when a probe's port doesn't resolve to any of the container's declared
# ports/port-names. Skipped (not flagged) when the container declares no
# ports at all, since that's optional in Kubernetes and not itself a problem.
check_probe_port() {
    local kind="$1" cname="$2" pval="$3" cports="$4" cportnames="$5"
    [[ "$pval" == "-" || -z "$cports" ]] && return 0
    local match=0 p n
    IFS=',' read -ra _ports <<<"$cports"
    IFS=',' read -ra _names <<<"$cportnames"
    for p in "${_ports[@]}"; do [[ "$p" == "$pval" ]] && match=1; done
    for n in "${_names[@]}"; do [[ -n "$n" && "$n" == "$pval" ]] && match=1; done
    if [[ "$match" -eq 0 ]]; then
        issue "$kind probe on container '$cname' targets port '$pval', not among its declared ports [$cports] — verify the probe points at the port the container actually listens on."
    fi
}

ip_to_int() {
    local IFS=. o
    read -ra o <<<"$1"
    echo $(((o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3]))
}

ip_in_cidr() {
    local ip="$1" cidr="$2"
    local net="${cidr%/*}" bits="${cidr#*/}"
    [[ "$bits" == "$cidr" ]] && bits=32
    local ip_int net_int mask
    ip_int="$(ip_to_int "$ip")"
    net_int="$(ip_to_int "$net")"
    if [[ "$bits" -eq 0 ]]; then
        mask=0
    else
        mask=$((0xFFFFFFFF << (32 - bits) & 0xFFFFFFFF))
    fi
    [[ $((ip_int & mask)) -eq $((net_int & mask)) ]]
}

FROM_LABELS_JSON="{}"
[[ -n "$FROM_LABELS" ]] && FROM_LABELS_JSON="$(jq -n --arg s "$FROM_LABELS" '
    ($s | split(",") | map(select(length > 0) | split("=")) | map({(.[0]): (.[1] // "")}) | add) // {}')"

# Evaluates whether NetworkPolicies in $1's namespace that select the given
# pod ($2, full pod JSON) would let traffic reach $3 (space-separated target
# ports). Only matchLabels selectors are evaluated (matchExpressions are
# flagged as unverifiable, not silently ignored); ipBlock.except is not
# evaluated. With no --from-* given this is purely informational: it lists
# the applicable policies/rules without judging whether any specific caller
# is allowed through.
check_network_policy() {
    local ns="$1" pod_obj="$2" target_ports="$3"
    local pod_labels
    pod_labels="$(echo "$pod_obj" | jq -c '.metadata.labels // {}')"

    local np_json np_count
    np_json="$("${KCTL[@]}" get networkpolicy -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')"
    np_count="$(echo "$np_json" | jq '.items | length')"
    if [[ "$np_count" -eq 0 ]]; then
        ok "No NetworkPolicy objects in $ns — ingress to this pod is unrestricted by NetworkPolicy."
        return 0
    fi

    local skipped
    skipped="$(echo "$np_json" | jq -r --argjson labels "$pod_labels" '
        [.items[]
         | select((.spec.policyTypes // ["Ingress"]) | index("Ingress"))
         | select((.spec.podSelector.matchExpressions // []) | length > 0)
         | .metadata.name] | join(", ")')"
    [[ -n "$skipped" ]] && warn "Cannot evaluate podSelector matchExpressions on: $skipped (skipped)."

    local applicable applicable_count
    applicable="$(echo "$np_json" | jq -c --argjson labels "$pod_labels" '
        [.items[]
         | select((.spec.policyTypes // ["Ingress"]) | index("Ingress"))
         | select((.spec.podSelector.matchExpressions // []) | length == 0)
         | select((.spec.podSelector.matchLabels // {}) as $sel | ($sel | to_entries | all(.value == $labels[.key])))]')"
    applicable_count="$(echo "$applicable" | jq 'length')"

    if [[ "$applicable_count" -eq 0 ]]; then
        ok "No Ingress NetworkPolicy selects this pod's labels — ingress is unrestricted by NetworkPolicy."
        return 0
    fi

    local have_caller=0
    [[ -n "$FROM_NS" || -n "$FROM_LABELS" || -n "$FROM_IP" ]] && have_caller=1
    local overall_allowed=0

    local pol
    while IFS= read -r pol; do
        [[ -z "$pol" ]] && continue
        local pol_name rule_count
        pol_name="$(echo "$pol" | jq -r '.metadata.name')"
        rule_count="$(echo "$pol" | jq '.spec.ingress // [] | length')"

        if [[ "$rule_count" -eq 0 ]]; then
            if [[ "$applicable_count" -eq 1 ]]; then
                issue "NetworkPolicy '$pol_name' selects this pod and has 0 ingress rules — denies all ingress."
            else
                warn "NetworkPolicy '$pol_name' selects this pod with 0 ingress rules (adds no allowed traffic; other policies below may still allow it)."
            fi
            continue
        fi

        echo -e "  ${CYAN}NetworkPolicy/$pol_name${RESET}"
        local rule rule_idx=0
        while IFS= read -r rule; do
            rule_idx=$((rule_idx + 1))
            local ports_desc peers_desc
            ports_desc="$(echo "$rule" | jq -r '
                (.ports // []) | if length == 0 then "all ports"
                else (map("\(.protocol // "TCP")/\(.port)") | join(",")) end')"
            peers_desc="$(echo "$rule" | jq -r '
                (.from // []) | if length == 0 then "any source"
                else (map(
                    if has("namespaceSelector") then "ns:" + ((.namespaceSelector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(","))
                    elif has("podSelector") then "pod:" + ((.podSelector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(","))
                    elif has("ipBlock") then "cidr:" + .ipBlock.cidr
                    else "unknown" end
                ) | join(" OR ")) end')"
            echo "    rule $rule_idx: from [$peers_desc]  ports [$ports_desc]"

            if [[ "$have_caller" -eq 1 ]]; then
                local port_ok=1
                if echo "$rule" | jq -e '(.ports // []) | length > 0' >/dev/null 2>&1; then
                    port_ok=0
                    local tp
                    for tp in $target_ports; do
                        echo "$rule" | jq -e --arg p "$tp" '.ports[]? | select((.port | tostring) == $p)' >/dev/null 2>&1 && port_ok=1
                    done
                fi

                local peer_ok=1
                if echo "$rule" | jq -e '(.from // []) | length > 0' >/dev/null 2>&1; then
                    peer_ok=0
                    local peer
                    while IFS= read -r peer; do
                        local this_peer_ok=1
                        if echo "$peer" | jq -e 'has("namespaceSelector")' >/dev/null 2>&1; then
                            if [[ -z "$FROM_NS" ]]; then
                                this_peer_ok=0
                            else
                                local sel_match
                                sel_match="$(echo "$peer" | jq -r --argjson nl "${FROM_NS_LABELS_JSON:-{\}}" '(.namespaceSelector.matchLabels // {}) as $sel | ($sel | to_entries | all(.value == $nl[.key]))')"
                                [[ "$sel_match" != "true" ]] && this_peer_ok=0
                            fi
                        fi
                        if echo "$peer" | jq -e 'has("podSelector")' >/dev/null 2>&1; then
                            if [[ -z "$FROM_LABELS" ]]; then
                                this_peer_ok=0
                            else
                                local sel_match2
                                sel_match2="$(echo "$peer" | jq -r --argjson pl "$FROM_LABELS_JSON" '(.podSelector.matchLabels // {}) as $sel | ($sel | to_entries | all(.value == $pl[.key]))')"
                                [[ "$sel_match2" != "true" ]] && this_peer_ok=0
                                # A podSelector with no sibling namespaceSelector matches only
                                # the policy's own namespace (k8s NetworkPolicy semantics) —
                                # not "any namespace". Without --from-ns we can't confirm that,
                                # so don't count it as a match.
                                if ! echo "$peer" | jq -e 'has("namespaceSelector")' >/dev/null 2>&1; then
                                    [[ -z "$FROM_NS" || "$FROM_NS" != "$ns" ]] && this_peer_ok=0
                                fi
                            fi
                        fi
                        if echo "$peer" | jq -e 'has("ipBlock")' >/dev/null 2>&1; then
                            if [[ -z "$FROM_IP" ]]; then
                                this_peer_ok=0
                            else
                                local cidr
                                cidr="$(echo "$peer" | jq -r '.ipBlock.cidr')"
                                ip_in_cidr "$FROM_IP" "$cidr" || this_peer_ok=0
                            fi
                        fi
                        [[ "$this_peer_ok" -eq 1 ]] && peer_ok=1
                    done < <(echo "$rule" | jq -c '.from[]?')
                fi

                [[ "$port_ok" -eq 1 && "$peer_ok" -eq 1 ]] && overall_allowed=1
            fi
        done < <(echo "$pol" | jq -c '.spec.ingress[]')
    done < <(echo "$applicable" | jq -c '.[]')

    if [[ "$have_caller" -eq 1 ]]; then
        if [[ "$overall_allowed" -eq 1 ]]; then
            ok "NetworkPolicy allows traffic from the specified caller (ns=${FROM_NS:-*} labels=${FROM_LABELS:-*} ip=${FROM_IP:-*})."
        else
            issue "NetworkPolicy blocks traffic from the specified caller (ns=${FROM_NS:-*} labels=${FROM_LABELS:-*} ip=${FROM_IP:-*}) — no ingress rule matches."
        fi
    fi
}

# Cilium's native policies (CiliumNetworkPolicy is namespaced,
# CiliumClusterwideNetworkPolicy is cluster-scoped) use a different schema
# (endpointSelector/fromEndpoints/fromCIDR/fromEntities/toPorts) than
# upstream Kubernetes NetworkPolicy, so this is evaluated and reported as its
# own separate verdict rather than merged into the Kubernetes NetworkPolicy
# check above. How Cilium combines rules from both sources for the same pod
# (union vs. intersection, and any Deny-policy precedence) depends on your
# Cilium version/config — treat each verdict here as one input to check, not
# a final combined answer; don't assume "blocked" in one implies the other
# doesn't matter, or that "allowed" in one overrides a Deny elsewhere.
# fromEntities (e.g. cluster/host/world) is reported but not evaluated.
check_cilium_policy() {
    local kind="$1" resource="$2" namespaced="$3" pod_obj="$4" pod_ns="$5" target_ports="$6"
    local pod_labels
    pod_labels="$(echo "$pod_obj" | jq -c --arg ns "$pod_ns" '(.metadata.labels // {}) + {"k8s:io.kubernetes.pod.namespace": $ns, "io.kubernetes.pod.namespace": $ns}')"

    local get_args=("$resource")
    [[ "$namespaced" -eq 1 ]] && get_args+=(-n "$pod_ns")

    local cnp_json cnp_count
    cnp_json="$("${KCTL[@]}" get "${get_args[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
    cnp_count="$(echo "$cnp_json" | jq '.items | length')"
    [[ "$cnp_count" -eq 0 ]] && return 0

    local skipped
    skipped="$(echo "$cnp_json" | jq -r '
        [.items[] | select((.spec.endpointSelector.matchExpressions // []) | length > 0) | .metadata.name] | join(", ")')"
    [[ -n "$skipped" ]] && warn "$kind: cannot evaluate endpointSelector matchExpressions on: $skipped (skipped)."

    local applicable applicable_count
    applicable="$(echo "$cnp_json" | jq -c --argjson labels "$pod_labels" '
        [.items[]
         | select((.spec.endpointSelector.matchExpressions // []) | length == 0)
         | select((.spec.endpointSelector.matchLabels // {}) as $sel
                   | ($sel | to_entries | all($labels[(.key | sub("^k8s:"; ""))] == .value)))]')"
    applicable_count="$(echo "$applicable" | jq 'length')"
    [[ "$applicable_count" -eq 0 ]] && return 0

    echo -e "  ${BOLD}$kind${RESET}"
    local have_caller=0
    [[ -n "$FROM_NS" || -n "$FROM_LABELS" || -n "$FROM_IP" ]] && have_caller=1
    local overall_allowed=0 saw_entities=0

    local pol
    while IFS= read -r pol; do
        [[ -z "$pol" ]] && continue
        local pol_name rule_count
        pol_name="$(echo "$pol" | jq -r '.metadata.name')"
        rule_count="$(echo "$pol" | jq '.spec.ingress // [] | length')"

        if [[ "$rule_count" -eq 0 ]]; then
            if [[ "$applicable_count" -eq 1 ]]; then
                issue "$kind '$pol_name' selects this pod and has 0 ingress rules — denies all ingress."
            else
                warn "$kind '$pol_name' selects this pod with 0 ingress rules (adds no allowed traffic)."
            fi
            continue
        fi

        echo -e "    ${CYAN}$pol_name${RESET}"
        local rule rule_idx=0
        while IFS= read -r rule; do
            rule_idx=$((rule_idx + 1))
            local ports_desc peers_desc entities_desc
            ports_desc="$(echo "$rule" | jq -r '
                [(.toPorts // [])[].ports[]? | "\(.protocol // "TCP")/\(.port)"] | if length == 0 then "all ports" else join(",") end')"
            peers_desc="$(echo "$rule" | jq -r '
                ([(.fromEndpoints // [])[] | "endpoints:" + ((.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(","))]
                 + [(.fromCIDR // [])[] | "cidr:" + .]
                 + [(.fromEntities // [])[] | "entity:" + .])
                | if length == 0 then "any source" else join(" OR ") end')"
            entities_desc="$(echo "$rule" | jq -r '(.fromEntities // []) | join(",")')"
            echo "      rule $rule_idx: from [$peers_desc]  ports [$ports_desc]"
            [[ -n "$entities_desc" ]] && saw_entities=1

            if [[ "$have_caller" -eq 1 ]]; then
                local port_ok=1
                if echo "$rule" | jq -e '[(.toPorts // [])[].ports[]?] | length > 0' >/dev/null 2>&1; then
                    port_ok=0
                    local tp
                    for tp in $target_ports; do
                        echo "$rule" | jq -e --arg p "$tp" '[(.toPorts // [])[].ports[]?] | any((.port | tostring) == $p)' >/dev/null 2>&1 && port_ok=1
                    done
                fi

                local peer_ok=0
                local has_peers
                has_peers="$(echo "$rule" | jq -r '((.fromEndpoints // []) | length) + ((.fromCIDR // []) | length) + ((.fromEntities // []) | length)')"
                if [[ "$has_peers" -eq 0 ]]; then
                    peer_ok=1
                else
                    if [[ -n "$FROM_NS$FROM_LABELS" ]]; then
                        local caller_json
                        caller_json="$(echo "$FROM_LABELS_JSON" | jq -c --arg ns "$FROM_NS" \
                            'if $ns != "" then . + {"k8s:io.kubernetes.pod.namespace": $ns, "io.kubernetes.pod.namespace": $ns} else . end')"
                        local peer
                        while IFS= read -r peer; do
                            local sel_match
                            sel_match="$(echo "$peer" | jq -r --argjson caller "$caller_json" '
                                (.matchLabels // {}) as $sel
                                | ($sel | to_entries | all($caller[(.key | sub("^k8s:"; ""))] == .value))')"
                            [[ "$sel_match" == "true" ]] && peer_ok=1
                        done < <(echo "$rule" | jq -c '.fromEndpoints[]? // empty')
                    fi

                    if [[ -n "$FROM_IP" ]]; then
                        while IFS= read -r cidr; do
                            [[ -z "$cidr" ]] && continue
                            ip_in_cidr "$FROM_IP" "$cidr" && peer_ok=1
                        done < <(echo "$rule" | jq -r '(.fromCIDR // [])[]?')
                    fi
                fi

                [[ "$port_ok" -eq 1 && "$peer_ok" -eq 1 ]] && overall_allowed=1
            fi
        done < <(echo "$pol" | jq -c '.spec.ingress[]')
    done < <(echo "$applicable" | jq -c '.[]')

    [[ "$saw_entities" -eq 1 ]] && warn "$kind: one or more rules use fromEntities (e.g. cluster/host/world) — not evaluated against --from-*, verify manually."

    if [[ "$have_caller" -eq 1 ]]; then
        if [[ "$overall_allowed" -eq 1 ]]; then
            ok "$kind allows traffic from the specified caller."
        else
            issue "$kind blocks traffic from the specified caller — no $kind ingress rule matches. Check how your Cilium setup combines this with the Kubernetes NetworkPolicy verdict above before concluding traffic is blocked overall."
        fi
    fi
}

# ── resolve matching Services ────────────────
SVC_JSON=""
MATCH_DESC=""

if [[ -n "$SELECTOR" ]]; then
    SVC_JSON="$("${KCTL[@]}" get svc "${NS_ARGS[@]}" -l "$SELECTOR" -o json 2>/dev/null || echo '{"items":[]}')"
    MATCH_DESC="selector '$SELECTOR'"
else
    for key in app app.kubernetes.io/name app.kubernetes.io/instance; do
        candidate="$("${KCTL[@]}" get svc "${NS_ARGS[@]}" -l "${key}=${APP}" -o json 2>/dev/null || echo '{"items":[]}')"
        count="$(echo "$candidate" | jq '.items | length')"
        if [[ "$count" -gt 0 ]]; then
            SVC_JSON="$candidate"
            MATCH_DESC="label '${key}=${APP}'"
            break
        fi
    done

    if [[ -z "$SVC_JSON" ]]; then
        all_svc="$("${KCTL[@]}" get svc "${NS_ARGS[@]}" -o json 2>/dev/null || echo '{"items":[]}')"
        candidate="$(echo "$all_svc" | jq --arg app "$APP" '{items: [.items[] | select(.metadata.name | test($app))]}')"
        count="$(echo "$candidate" | jq '.items | length')"
        if [[ "$count" -gt 0 ]]; then
            SVC_JSON="$candidate"
            MATCH_DESC="name containing '${APP}'"
        fi
    fi
fi

SVC_COUNT="$(echo "${SVC_JSON:-{\"items\":[]\}}" | jq '.items | length' 2>/dev/null || echo 0)"
if [[ -z "$SVC_JSON" || "$SVC_COUNT" -eq 0 ]]; then
    err "No Services found matching '$APP' (tried labels app / app.kubernetes.io/name / app.kubernetes.io/instance, then name substring)."
    exit 1
fi

hdr "App map for '$APP'  (matched via $MATCH_DESC)"

while IFS= read -r svc; do
    svc_name="$(echo "$svc" | jq -r '.metadata.name')"
    svc_ns="$(echo "$svc" | jq -r '.metadata.namespace')"
    svc_ports_desc="$(echo "$svc" | jq -r '[.spec.ports[]? | "\(.port)/\(.protocol)->\(.targetPort)"] | join(", ")')"
    svc_selector_str="$(echo "$svc" | jq -r '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")')"

    # ── 1. Ingress / HTTPRoute ──
    echo
    echo -e "${BOLD}[1] Ingress / HTTPRoute${RESET}"

    ing_json="$("${KCTL[@]}" get ingress -n "$svc_ns" -o json 2>/dev/null || echo '{"items":[]}')"
    ing_rows="$(echo "$ing_json" | jq -r --arg svc "$svc_name" '
        .items[] as $i
        | (($i.status.loadBalancer.ingress[0].hostname // $i.status.loadBalancer.ingress[0].ip) // "-") as $lb
        | (
            [ ($i.spec.rules // [])[] as $r
              | ($r.http.paths // [])[] as $p
              | select((($p.backend.service.name // $p.backend.serviceName) // "") == $svc)
              | [$i.metadata.name, ($r.host // "*"), ($p.path // "/"),
                 (($p.backend.service.port.number // $p.backend.service.port.name // $p.backend.servicePort) // "-" | tostring), $lb] ]
            + ( [$i] | map(select((($i.spec.defaultBackend.service.name // $i.spec.backend.serviceName) // "") == $svc))
                | map([.metadata.name, "*", "/* (default backend)",
                       ((.spec.defaultBackend.service.port.number // .spec.defaultBackend.service.port.name // .spec.backend.servicePort) // "-" | tostring), $lb]) )
          )[]
        | @tsv' 2>/dev/null || true)"

    route_rows=""
    if [[ "$HAS_HTTPROUTE" -eq 1 ]]; then
        route_json="$("${KCTL[@]}" get httproute -n "$svc_ns" -o json 2>/dev/null || echo '{"items":[]}')"
        route_rows="$(echo "$route_json" | jq -r --arg svc "$svc_name" '
            .items[] as $i
            | (($i.spec.hostnames // ["*"]) | join(",")) as $hosts
            | (($i.spec.parentRefs // []) | map(.name) | join(",")) as $parents
            | ($i.spec.rules // [])[] as $r
            | (($r.matches // [{}]) | map(.path.value // "*") | join(",")) as $paths
            | ($r.backendRefs // [])[]
            | select(.name == $svc)
            | [$i.metadata.name, $parents, $hosts, $paths, ((.port // "-") | tostring)]
            | @tsv' 2>/dev/null | sort -u || true)"
    fi

    if [[ -z "$ing_rows" && -z "$route_rows" ]]; then
        warn "No Ingress or HTTPRoute routes to this Service."
    fi

    ing_ports_seen=()
    if [[ -n "$ing_rows" ]]; then
        while IFS=$'\t' read -r name host path bport lb; do
            [[ -z "$name" ]] && continue
            echo -e "  ${CYAN}Ingress/$name${RESET}  host: $host  path: $path  backend: ${svc_name}:${bport}  lb: $lb"
            [[ "$bport" != "-" ]] && ing_ports_seen+=("$bport")
        done <<<"$ing_rows"
    fi
    if [[ -n "$route_rows" ]]; then
        while IFS=$'\t' read -r name parents hosts paths bport; do
            [[ -z "$name" ]] && continue
            echo -e "  ${CYAN}HTTPRoute/$name${RESET}  gateway: $parents  hostnames: $hosts  path: $paths  backend: ${svc_name}:${bport}"
            [[ "$bport" != "-" ]] && ing_ports_seen+=("$bport")
        done <<<"$route_rows"
    fi

    for bport in "${ing_ports_seen[@]+"${ing_ports_seen[@]}"}"; do
        if ! echo "$svc" | jq -e --arg p "$bport" '.spec.ports[]? | select((.port|tostring) == $p or .name == $p)' >/dev/null 2>&1; then
            issue "backend port '$bport' isn't exposed by Service $svc_ns/$svc_name (ports: $svc_ports_desc)"
        fi
    done

    # ── 2. Service ──
    echo
    echo -e "${BOLD}[2] Service${RESET}"
    echo -e "  ${CYAN}$svc_ns/$svc_name${RESET}  ports: $svc_ports_desc  selector: {${svc_selector_str:-<none>}}"

    if [[ -n "$svc_selector_str" ]]; then
        matching_pods_count="$("${KCTL[@]}" get pods -n "$svc_ns" -l "$svc_selector_str" -o json 2>/dev/null | jq '.items | length')"
        if [[ "$matching_pods_count" -eq 0 ]]; then
            issue "Service selector {$svc_selector_str} matches 0 Pods in $svc_ns — check Pod labels vs this selector."
        fi
    else
        warn "Service has no selector (likely manually-managed Endpoints or an ExternalName service)."
    fi

    # ── 3/4/5. Endpoints -> Pods -> Nodes ──
    echo
    echo -e "${BOLD}[3-5] Endpoints -> Pods -> Nodes${RESET}"

    ep_json="$("${KCTL[@]}" get endpoints "$svc_name" -n "$svc_ns" -o json 2>/dev/null || echo '{}')"
    ready_rows="$(echo "$ep_json" | jq -r '
        (.subsets // [])[] as $s | ($s.addresses // [])[]
        | [(.targetRef.name // "-"), .ip, "ready"] | @tsv' 2>/dev/null || true)"
    notready_rows="$(echo "$ep_json" | jq -r '
        (.subsets // [])[] as $s | ($s.notReadyAddresses // [])[]
        | [(.targetRef.name // "-"), .ip, "not-ready"] | @tsv' 2>/dev/null || true)"
    ep_rows="$(printf '%s\n%s\n' "$ready_rows" "$notready_rows" | grep -v '^$' || true)"

    if [[ -z "$ep_rows" ]]; then
        warn "No Endpoints (no matching backends)."
        if [[ -n "$svc_selector_str" && "${matching_pods_count:-0}" -gt 0 ]]; then
            issue "Service selector matches $matching_pods_count Pod(s) but none are Ready — check pod readiness/health."
        fi
        continue
    fi

    pods_json="$("${KCTL[@]}" get pods -n "$svc_ns" -o json 2>/dev/null || echo '{"items":[]}')"
    target_ports="$(echo "$svc" | jq -r '[.spec.ports[]?.targetPort | tostring] | join(" ")')"
    port_check_done=0
    first_pod_obj=""

    table=("IP	STATE	POD	CONTAINER(PORT)	NODE	NODE-IP	NODE-STATUS")
    while IFS=$'\t' read -r pod_name ep_ip ep_state; do
        [[ -z "$pod_name" ]] && continue
        if [[ "$pod_name" == "-" ]]; then
            table+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$ep_ip" "$ep_state" "-" "-" "-" "-" "-")")
            continue
        fi

        pod_obj="$(echo "$pods_json" | jq -c --arg n "$pod_name" '.items[] | select(.metadata.name == $n)')"
        node_name="$(echo "$pod_obj" | jq -r '.spec.nodeName // "-"')"
        containers_str="$(echo "$pod_obj" | jq -r '
            [ .spec.containers[]?
              | . as $c
              | ($c.ports // []) as $ports
              | ($ports | map(.containerPort | tostring) | join(",")) as $plist
              | "\($c.name)(\(if $plist == "" then "-" else $plist end))"
            ] | join(", ")')"

        if [[ "$port_check_done" -eq 0 ]]; then
            port_check_done=1
            first_pod_obj="$pod_obj"
            declared_ports="$(echo "$pod_obj" | jq -r '[.spec.containers[]?.ports[]?.containerPort] | join(" ")')"
            if [[ -n "$declared_ports" ]]; then
                found=0
                for tp in $target_ports; do
                    for dp in $declared_ports; do
                        [[ "$tp" == "$dp" ]] && found=1
                    done
                done
                if [[ "$found" -eq 0 ]]; then
                    issue "Service targetPort(s) [$target_ports] not found among declared container ports [$declared_ports] on pod $pod_name — verify the container actually listens on the targetPort."
                fi
            fi

            # Fields joined with \x1f (not \t): a plain tab is "IFS whitespace" to
            # bash's `read`, which silently collapses consecutive delimiters and
            # misaligns fields whenever two columns are empty back-to-back (as
            # cports/cnames are for a container with no declared ports).
            probe_rows="$(echo "$pod_obj" | jq -r '
                .spec.containers[]?
                | . as $c
                | (($c.ports // []) | map(.containerPort | tostring) | join(",")) as $ports
                | (($c.ports // []) | map(.name // "") | join(",")) as $names
                | (($c.readinessProbe.httpGet.port // $c.readinessProbe.tcpSocket.port // $c.readinessProbe.grpc.port) // "-" | tostring) as $rp
                | (($c.livenessProbe.httpGet.port // $c.livenessProbe.tcpSocket.port // $c.livenessProbe.grpc.port) // "-" | tostring) as $lp
                | [$c.name, $ports, $names, $rp, $lp]
                | join("\u001f")')"
            while IFS=$'\x1f' read -r cname cports cnames rp lp; do
                [[ -z "$cname" ]] && continue
                check_probe_port "readiness" "$cname" "$rp" "$cports" "$cnames"
                check_probe_port "liveness" "$cname" "$lp" "$cports" "$cnames"
            done <<<"$probe_rows"
        fi

        node_ip="-"
        node_ready="-"
        if [[ -n "$node_name" && "$node_name" != "-" ]]; then
            ninfo="$(node_info "$node_name")"
            IFS=$'\t' read -r node_ip node_ready <<<"${ninfo:--$'\t'-}"
        fi

        table+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$ep_ip" "$ep_state" "$pod_name" "$containers_str" "$node_name" "$node_ip" "$node_ready")")
    done <<<"$ep_rows"

    printf '%s\n' "${table[@]}" | column -t -s$'\t' | sed 's/^/  /'

    # ── 6. NetworkPolicy (ingress) ──
    echo
    echo -e "${BOLD}[6] NetworkPolicy (ingress)${RESET}"
    if [[ -z "$first_pod_obj" ]]; then
        warn "No backing Pod available to evaluate NetworkPolicy against."
    else
        check_network_policy "$svc_ns" "$first_pod_obj" "$target_ports"
        [[ "$HAS_CILIUM_NP" -eq 1 ]] && check_cilium_policy "CiliumNetworkPolicy" "ciliumnetworkpolicies.cilium.io" 1 "$first_pod_obj" "$svc_ns" "$target_ports"
        [[ "$HAS_CILIUM_CCNP" -eq 1 ]] && check_cilium_policy "CiliumClusterwideNetworkPolicy" "ciliumclusterwidenetworkpolicies.cilium.io" 0 "$first_pod_obj" "$svc_ns" "$target_ports"
    fi
done < <(echo "$SVC_JSON" | jq -c '.items[]')

echo
