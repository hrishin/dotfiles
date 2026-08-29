# ============================================================================
# PATH Configuration
# ============================================================================
# Lives in ~/.path.sh (configs/.path.sh) instead, sourced early by
# .zshrc/.bashrc — before Oh My Zsh loads, since some of its bundled
# plugins (e.g. kubectl) silently no-op if their command isn't already on
# PATH by the time they load. See .path.sh for the full explanation.

# ============================================================================
# Aliases
# ============================================================================

alias docker=podman
alias python=python3
alias kgnl="k get node -L node-type"
alias kgsep="k get svc,ep"
alias kghr='k get httproutes.gateway.networking.k8s.io -A -o "custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,GATEWAY:.spec.parentRefs[*].name,HOSTNAMES:.spec.hostnames[*],BACKENDS:.spec.rules[*].backendRefs[*].name,ACCEPTED:.status.parents[*].conditions[?(@.type==\"Accepted\")].status,RESOLVED:.status.parents[*].conditions[?(@.type==\"ResolvedRefs\")].status,CREATED:.metadata.creationTimestamp"'
alias kgis='k get ingress -A -o "custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host,BACKENDS:.spec.rules[*].http.paths[*].backend.service.name,ADDRESS:.status.loadBalancer.ingress[*].ip,LB-HOST:.status.loadBalancer.ingress[*].hostname,CREATED:.metadata.creationTimestamp"'
alias kcilsvc="k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list"
alias kcillb="k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list"
alias kcilep="k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list"
alias kgev="k get events --sort-by='.lastTimestamp'"
alias kgeva="k get events -A --sort-by='.lastTimestamp'"
alias puup="pulumi up -y"
alias pudst="pulumi destroy -y"
alias pusop="pulumi stack output"


# EndpointSlices are labeled with the owning Service's name
# (kubernetes.io/service-name), not named after it directly.
kgeps() {
  local svc="$1"
  shift
  k get endpointslices -l kubernetes.io/service-name="$svc" "$@"
}

# AGE is computed entirely in jq (fromdateiso8601/now), not by shelling out
# to `date` per row: that approach broke on a cluster where the CREATED
# field ended up empty by the time awk's nested `date -j -f ...` subshell
# saw it, throwing a "Failed conversion" error per node and misrendering
# the whole row. jq's date math avoids the subprocess entirely and doesn't
# care about BSD (macOS) vs GNU (Linux) `date` flag differences.
kgn() {
  kubectl get nodes -o json |
    jq -r '
      def ng:
        (.metadata.labels // {}) as $l
        | if ($l.NodeGroup // "") != "" then $l.NodeGroup
          elif ($l["node-type"] // "") != "" then $l["node-type"]
          else
            ([$l | keys[] | select(startswith("node-role.kubernetes.io/")) | sub("^node-role.kubernetes.io/"; "")]) as $roles
            | if ($roles | length) > 0 then ($roles | join(","))
              else "<none>"
              end
          end;

      def ready:
        if ([.status.conditions[]? | select(.type=="Ready") | .status] | any(.=="True")) then "Ready"
        else "Unknown"
        end;

      def extip:
        ([.status.addresses[]? | select(.type=="ExternalIP") | .address] | first) // "-";

      def age($created):
        (now - ($created | fromdateiso8601)) as $secs
        | ($secs / 60 | floor) as $mins
        | if $mins < 60 then "\($mins)m"
          elif $mins < 1440 then "\(($mins/60)|floor)h"
          else "\(($mins/1440)|floor)d"
          end;

      ["NAME","NODEGROUP","INSTANCE-TYPE","EXTERNAL-IP","KUBELET","RUNTIME","STATUS","CREATED","AGE"],
      (.items[] | [
        .metadata.name,
        (ng),
        (.metadata.labels["node.kubernetes.io/instance-type"] // "-"),
        (extip),
        .status.nodeInfo.kubeletVersion,
        .status.nodeInfo.containerRuntimeVersion,
        ready,
        .metadata.creationTimestamp,
        age(.metadata.creationTimestamp)
      ]) | @tsv
    ' | column -t -s $'\t'
}

# Per-node taints/labels side by side, one node block at a time — a "node
# <name> --" header row followed by a "|"-prefixed row per taint/label
# pair (index-aligned; the shorter list just leaves that side blank).
kgnt() {
  kubectl get nodes -o json |
    jq -r '
      def taint_str:
        if (.value // "") != "" then "\(.key)=\(.value):\(.effect)"
        else "\(.key):\(.effect)"
        end;

      .items[] |
      (.metadata.name) as $name |
      (.spec.taints // []) as $taints |
      ((.metadata.labels // {}) | to_entries | map("\(.key)=\(.value)")) as $labels |
      ([($taints|length), ($labels|length)] | max) as $n |
      (["node \($name) --","TAINTS","LABELS"] | @tsv),
      (range(0; $n) | [
          "|",
          ($taints[.] as $t | if $t then ($t|taint_str) else "" end),
          ($labels[.] // "")
        ] | @tsv),
      ""
    ' | column -t -s $'\t'
}

# Attaches an ephemeral debug container (docker.io/hriships/debug — see
# images/debug/Dockerfile: dig, sysstat, top, ip, ss, tcpdump) to a
# running pod via `kubectl debug`. Pass a container name to also share
# its process namespace (needed to `nsenter`/see its processes, not for
# network visibility — containers in a pod already share one network
# namespace, so tcpdump/ss/ip work either way).
kdebug() {
  if [[ -z "${1:-}" ]]; then
    echo "Usage: kdebug <pod> [container]" >&2
    return 1
  fi
  local pod="$1"
  local target="${2:-}"
  if [[ -n "$target" ]]; then
    kubectl debug -it "$pod" --image=docker.io/hriships/debug --target="$target" -- bash
  else
    kubectl debug -it "$pod" --image=docker.io/hriships/debug -- bash
  fi
}

# ============================================================================
# Shell Integrations & Completions
# ============================================================================

# This file is sourced by both .zshrc and .bashrc, but `direnv hook`/`scw
# autocomplete script` each generate shell-specific function syntax for
# exactly one shell — eval-ing the zsh form under bash is a hard syntax
# error on every bash startup, not a harmless no-op. Detect the running
# shell rather than hardcoding zsh.
if [ -n "${ZSH_VERSION:-}" ]; then
  command -v direnv &> /dev/null && eval "$(direnv hook zsh)"
  command -v scw &> /dev/null && eval "$(scw autocomplete script shell=zsh)"
  [[ -f "$HOME/.openclaw/completions/openclaw.zsh" ]] && source "$HOME/.openclaw/completions/openclaw.zsh"
elif [ -n "${BASH_VERSION:-}" ]; then
  command -v direnv &> /dev/null && eval "$(direnv hook bash)"
  command -v scw &> /dev/null && eval "$(scw autocomplete script shell=bash)"
fi

# kubens ships a zsh completion function (_kubens) via its Homebrew formula,
# but oh-my-zsh's cached compdump is only rebuilt periodically, so newly
# installed completions like this one don't get auto-registered. Wire it up
# explicitly, the same way oh-my-zsh's own kubectl plugin does for _kubectl.
if command -v kubens &> /dev/null && [[ -n "$ZSH_VERSION" ]]; then
  autoload -Uz _kubens
  compdef _kubens kubens kns
fi

# ktrim (scripts/ktrim) just forwards its args into `kubectl get -o
# json`, so give it kubectl get's own completion — resource types,
# resource names, and every `get` flag — instead of leaving it with no
# completion at all. Modern kubectl's zsh completion has no separate
# per-verb function to borrow (it shells out to `kubectl __complete ...`
# and lets the real binary compute candidates), so _ktrim replays that
# same request with "get" spliced in as the verb, then hands off to
# _kubectl to do the actual work.
if command -v ktrim &> /dev/null && [[ -n "$ZSH_VERSION" ]]; then
  _ktrim() {
    local -a words_orig=("${words[@]}")
    local current_orig=$CURRENT
    words=(kubectl get "${words[2,-1]}")
    ((CURRENT += 1))
    _kubectl
    words=("${words_orig[@]}")
    CURRENT=$current_orig
  }
  compdef _ktrim ktrim
fi

# ============================================================================
# Tool Initialization
# ============================================================================

if command -v brew &> /dev/null; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if command -v cargo &> /dev/null; then
  . "$HOME/.cargo/env"
fi

# Load credentials if they exist
if [[ -f "$HOME/.credentials" ]]; then
  source "$HOME/.credentials"
fi
