#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  flux-status.sh
#  Reports FluxCD install health, Kustomization/HelmRelease/source status,
#  controller pod health, and recent error lines from controller logs.
#
#  Usage: ./flux-status.sh [-n|--namespace <ns>] [-c|--context <kube-context>]
#                           [-s|--since <duration>] [-l|--log-lines <N>]
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

# Extracts container state/last-state (reason, exit code, message) and the
# tail of Events from `kubectl describe pod`, to explain why a pod is unhealthy.
# Emits an "OOM_FLAG:<container>" marker line whenever a container's last
# terminate reason was OOMKilled, so the caller can call it out by name.
pod_issue_detail() {
    local pod="$1" desc
    desc=$("${KCTL[@]}" describe pod "$pod" -n "$NAMESPACE" 2>/dev/null || true)
    [[ -z "$desc" ]] && return 0

    echo "$desc" | awk '
        /^Containers:/ { in_c=1; next }
        in_c && /^[A-Za-z]/ { in_c=0 }
        in_c && /^  [A-Za-z0-9._-]+:$/ {
            name=$0; sub(/^  /, "", name); sub(/:$/, "", name)
            print; next
        }
        in_c && /^    (State|Last State|Ready|Restart Count):/ { print; next }
        in_c && /^      Reason:[ \t]+OOMKilled/ { print; print "OOM_FLAG:" name; next }
        in_c && /^      (Reason|Exit Code|Started|Finished|Message):/ { print; next }
    '
    echo "$desc" | awk '/^Events:/{f=1} f' | tail -n 6
}

NAMESPACE="flux-system"
CONTEXT=""
SINCE="1h"
LOG_LINES=20

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 [-n|--namespace <ns>] [-c|--context <kube-context>] [-s|--since <duration>] [-l|--log-lines <N>]"
    echo "  $0 -h | --help"
    echo
    echo "  -n, --namespace <ns>   namespace the Flux controllers run in (default: flux-system)"
    echo "  -c, --context <ctx>    kubectl context to use (default: current context)"
    echo "  -s, --since <dur>      how far back to scan controller logs for errors (default: 1h)"
    echo "  -l, --log-lines <N>    max matching log lines to show per controller (default: 20)"
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
    -s | --since)
        [[ -z "${2:-}" ]] && {
            err "--since requires a value"
            exit 1
        }
        SINCE="$2"
        shift 2
        ;;
    -l | --log-lines)
        [[ -z "${2:-}" ]] && {
            err "--log-lines requires a value"
            exit 1
        }
        LOG_LINES="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *)
        err "Unknown argument: $1"
        usage
        ;;
    esac
done

# ── check dependencies ───────────────────────
missing=()
for dep in kubectl jq flux; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
fi

KCTL=(kubectl)
FLUX=(flux)
if [[ -n "$CONTEXT" ]]; then
    KCTL+=(--context "$CONTEXT")
    FLUX+=(--context "$CONTEXT")
fi

if ! "${KCTL[@]}" cluster-info --request-timeout=5s &>/dev/null; then
    err "Cannot reach the cluster (check kubeconfig/context/VPN)."
    exit 1
fi

# ── §1 controller pods ───────────────────────
hdr "§1  Controller pods (namespace: $NAMESPACE)"
if ! "${KCTL[@]}" get pods -n "$NAMESPACE" -o wide 2>/dev/null | sed 's/^/  /'; then
    err "Could not list pods in namespace $NAMESPACE."
fi

echo
BAD_PODS=$("${KCTL[@]}" get pods -n "$NAMESPACE" -o json 2>/dev/null |
    jq -r '.items[]
    | select(
        (.status.phase != "Running")
        or ([.status.containerStatuses[]?.ready] | any(. == false))
        or ([.status.containerStatuses[]?.restartCount] | any(. > 3))
      )
    | .metadata.name' || true)

if [[ -z "$BAD_PODS" ]]; then
    ok "All controller pods are Running and ready."
else
    warn "Pods not healthy:"
    while IFS= read -r pod; do
        [[ -z "$pod" ]] && continue
        echo -e "  ${RED}✖${RESET}  $pod"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" == OOM_FLAG:* ]]; then
                echo -e "      ${RED}${BOLD}⚠ container '${line#OOM_FLAG:}' is OOMKilled${RESET}"
                continue
            fi
            echo -e "      ${DIM}$line${RESET}"
        done < <(pod_issue_detail "$pod")
    done <<<"$BAD_PODS"
fi

# ── §2 kustomizations ────────────────────────
hdr "§2  Kustomizations"
"${FLUX[@]}" get kustomizations -A 2>&1 | sed 's/^/  /' || warn "No Kustomizations found or flux get failed."

# ── §3 helm releases ─────────────────────────
hdr "§3  HelmReleases"
"${FLUX[@]}" get helmreleases -A 2>&1 | sed 's/^/  /' || warn "No HelmReleases found or flux get failed."

# ── §4 sources (git / oci / helm repos / helm charts / buckets) ──
hdr "§4  Sources"
echo -e "  ${BOLD}Git repositories${RESET}"
"${FLUX[@]}" get sources git -A 2>&1 | sed 's/^/  /' || echo "  none"
echo
echo -e "  ${BOLD}OCI repositories${RESET}"
"${FLUX[@]}" get sources oci -A 2>&1 | sed 's/^/  /' || echo "  none"
echo
echo -e "  ${BOLD}Helm repositories${RESET}"
"${FLUX[@]}" get sources helm -A 2>&1 | sed 's/^/  /' || echo "  none"
echo
echo -e "  ${BOLD}Helm charts${RESET}"
"${FLUX[@]}" get sources chart -A 2>&1 | sed 's/^/  /' || echo "  none"
echo
echo -e "  ${BOLD}Buckets${RESET}"
"${FLUX[@]}" get sources bucket -A 2>&1 | sed 's/^/  /' || echo "  none"

# ── §5 failing resources (Ready != True) across all Flux kinds ──
hdr "§5  Failing resources (Ready != True)"

CRDS=(
    "kustomizations.kustomize.toolkit.fluxcd.io:Kustomization"
    "helmreleases.helm.toolkit.fluxcd.io:HelmRelease"
    "gitrepositories.source.toolkit.fluxcd.io:GitRepository"
    "ocirepositories.source.toolkit.fluxcd.io:OCIRepository"
    "helmrepositories.source.toolkit.fluxcd.io:HelmRepository"
    "helmcharts.source.toolkit.fluxcd.io:HelmChart"
    "buckets.source.toolkit.fluxcd.io:Bucket"
)

FOUND_FAILURE=0
for entry in "${CRDS[@]}"; do
    plural="${entry%%:*}"
    kind="${entry##*:}"

    resources=$("${KCTL[@]}" get "$plural" -A -o json 2>/dev/null || echo '{"items":[]}')

    rows=$(echo "$resources" | jq -r --arg kind "$kind" '
        .items[]
        | . as $r
        | ($r.status.conditions // [] | map(select(.type == "Ready")) | .[0]) as $c
        | select($c == null or $c.status != "True")
        | [$kind, $r.metadata.namespace, $r.metadata.name,
           ($c.reason // "Unknown"), ($c.message // "No status reported yet")]
        | @tsv')

    [[ -z "$rows" ]] && continue
    FOUND_FAILURE=1
    while IFS=$'\t' read -r k ns name reason message; do
        [[ -z "$k" ]] && continue
        echo -e "  ${RED}✖${RESET}  ${BOLD}$k${RESET}/$name  ${DIM}(ns: $ns, reason: $reason)${RESET}"
        echo -e "      $message"
    done <<<"$rows"
done

if [[ "$FOUND_FAILURE" -eq 0 ]]; then
    ok "No Kustomizations, HelmReleases, or sources are reporting Ready=False."
fi

# ── §6 controller logs — recent errors ───────
hdr "§6  Controller logs — recent errors (since $SINCE)"

PODS=$("${KCTL[@]}" get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [[ -z "$PODS" ]]; then
    warn "No controller pods found in namespace $NAMESPACE."
else
    for pod in $PODS; do
        echo -e "\n  ${BOLD}${pod}${RESET}"
        matches=$("${KCTL[@]}" logs -n "$NAMESPACE" "$pod" --since "$SINCE" --all-containers --prefix=false 2>/dev/null |
            grep -iE 'error|failed|retry|panic' | tail -n "$LOG_LINES" || true)
        if [[ -z "$matches" ]]; then
            ok "  no error/failed/retry lines in the last $SINCE"
        else
            while IFS= read -r line; do
                echo -e "    ${RED}$line${RESET}"
            done <<<"$matches"
        fi
    done
fi

# ── summary ───────────────────────────────────
hdr "Summary"
if [[ "$FOUND_FAILURE" -eq 0 && -z "$BAD_PODS" ]]; then
    ok "Flux looks healthy: controllers running, all reconciled resources Ready."
else
    [[ -n "$BAD_PODS" ]] && warn "One or more controller pods are unhealthy (see §1)."
    [[ "$FOUND_FAILURE" -eq 1 ]] && warn "One or more Flux resources are not Ready (see §5)."
    echo -e "  ${DIM}Check §6 controller logs above for the underlying error messages.${RESET}"
fi
echo
