# ============================================================================
# PATH Configuration
# ============================================================================
export PULUMI_CONFIG_PASSPHRASE=""
export PATH="$HOME/.tfenv/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
export PATH="/Users/hrishis/.antigravity/antigravity/bin:$PATH"
export PATH="/Users/hrishis/.opencode/bin:$PATH"
export PATH="$PATH:$HOME/Downloads/terraform_1.9.4_darwin_arm64:/private/var/folders/m1/0n9md3h51rx2gf4lw2jllzm80000gn/T/AppTranslocation/E246B421-88F2-40CC-A16C-4558867A6AA0/d/Visual\ Studio\ Code.app/Contents/Resources/app/bin/"
export PATH="$PATH:/opt/homebrew/bin/"
export PATH="$PATH:/Users/hrishis/go/bin/"
# ============================================================================
# Aliases
# ============================================================================

alias docker=podman
alias python=python3
alias kgnl="k get node -L node-type"
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

if command -v direnv &> /dev/null; then
  eval "$(direnv hook zsh)"
fi

if [[ -f "/Users/hrishis/.openclaw/completions/openclaw.zsh" ]]; then
  source "/Users/hrishis/.openclaw/completions/openclaw.zsh"
fi

if command -v scw &> /dev/null; then
  eval "$(scw autocomplete script shell=zsh)"
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
