# ============================================================================
# PATH Configuration
# ============================================================================
export PULUMI_CONFIG_PASSPHRASE=""
export PATH="$HOME/.tfenv/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
# $HOME-relative and existence-gated (not hardcoded to one user/machine), so
# these are safe no-ops on a machine that doesn't have the tool — including
# Linux, and including this repo's own private-repo counterpart being
# checked out for a different user. /opt/homebrew/bin also primes `brew`
# onto PATH before the `command -v brew` check further below, which is what
# runs `brew shellenv` for the rest of Homebrew's own PATH/MANPATH setup —
# a genuinely clean shell has nothing under /opt/homebrew on PATH otherwise.
[[ -d "$HOME/.antigravity/antigravity/bin" ]] && export PATH="$HOME/.antigravity/antigravity/bin:$PATH"
[[ -d "$HOME/.opencode/bin" ]] && export PATH="$HOME/.opencode/bin:$PATH"
[[ -d /opt/homebrew/bin ]] && export PATH="$PATH:/opt/homebrew/bin"
[[ -d "$HOME/go/bin" ]] && export PATH="$PATH:$HOME/go/bin"
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
alias puup="pulumi up -y"
alias pudst="pulumi destroy -y"
alias pusop="pulumi stack output"


kgn() {
  kubectl get nodes -o json |
    jq -r '
      def ng:
        if (.metadata.labels.NodeGroup // "") != "" then .metadata.labels.NodeGroup
        elif (.metadata.labels["node-type"] // "") != "" then .metadata.labels["node-type"]
        else ""
        end;

      def ready:
        if ([.status.conditions[]? | select(.type=="Ready") | .status] | any(.=="True")) then "Ready"
        else "Unknown"
        end;

      def extip:
        ([.status.addresses[]? | select(.type=="ExternalIP") | .address] | first) // "-";

      ["NAME","NODEGROUP","INSTANCE-TYPE","EXTERNAL-IP","KUBELET","RUNTIME","STATUS","CREATED"],
      (.items[] | [
        .metadata.name,
        (ng),
        (.metadata.labels["node.kubernetes.io/instance-type"] // ""),
        (extip),
        .status.nodeInfo.kubeletVersion,
        .status.nodeInfo.containerRuntimeVersion,
        ready,
        .metadata.creationTimestamp
      ]) | @tsv
    ' |
    awk 'NR==1 {
      print $1, $2, $3, $4, $5, $6, $7, "CREATED", "AGE"; next
    } {
      cmd = "echo $(( ( $(date -u +%s) - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ \"" $8 "\" +%s) ) / 60 ))"
      cmd | getline mins
      close(cmd)
      if (mins+0 < 60) age = mins "m"
      else if (mins+0 < 1440) age = int(mins/60) "h"
      else age = int(mins/1440) "d"
      print $1, $2, $3, $4, $5, $6, $7, $8, age
    }' | column -t
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
