# Util scripts

Utility and performance/troubleshooting scripts for Linux hosts, containers, and AWS networking.

Each script is standalone — copy it to a host (or `curl` it directly, see examples below) and run it, no install step required beyond the dependencies noted per script.

## Scripts

### `cert-info.sh`

Prints TLS certificate details for a domain: `curl -v` for the live HTTPS handshake summary (subject, issuer, validity dates, SAN match, verify result — exactly as curl reports them during the real TLS negotiation), then `openssl s_client` + `openssl x509` for the full decoded certificate (all extensions, SANs, serial, SHA-256 fingerprint), plus an expiry check via `openssl x509 -checkend` (not manual date-math — sidesteps BSD-vs-GNU `date` differences entirely). Accepts a bare domain or a full URL; scheme, path, and an embedded port are all handled.

**Dependencies:** `curl`, `openssl`.

**Usage:**

```bash
./cert-info.sh example.com                        # curl handshake + key facts + full -text dump
./cert-info.sh https://example.com:8443/some/path  # port/path parsed out automatically
./cert-info.sh example.com -q                      # skip the full -text dump
./cert-info.sh example.com -p 8443
./cert-info.sh -h | --help
```

### `container-enter.sh`

Enters a running container's namespaces via `nsenter`, given its container name (not the pod name) as known to the container runtime — resolved via `crictl`, same mechanism `container-inspect.sh` uses. Tries the container's own shell first (`bash`, then `sh`); if the image has neither (distroless/scratch), falls back to the host's shell running inside the container's PID/UTS/IPC/network namespaces only — the mount namespace is deliberately left as the host's so the host shell binary can actually be found and exec'd, the same trick `container-inspect.sh`'s network section uses for `ss`. Exits with the full list of matches (id, name, pod) if the name is ambiguous, rather than guessing.

**Dependencies:** `crictl`, `jq`, `nsenter`. Must be run as root (or via `sudo`) on a node with a running container runtime (containerd/CRI-O) — this isn't something `kubectl` alone can do.

Also accepts `--id <container-id>` instead of a name, skipping the crictl name lookup (and its ambiguity) entirely — used by `pod-container-enter.sh` below, which already knows the exact ID from `kubectl`.

**Usage:**

```bash
sudo ./container-enter.sh myapp                    # container's own bash, then sh
sudo ./container-enter.sh myapp --host-shell        # skip straight to the host-shell fallback
sudo ./container-enter.sh myapp -s /bin/ash         # exec a specific shell, no probing
sudo ./container-enter.sh --id abc123def456         # exact ID, no name lookup
sudo ./container-enter.sh -h | --help
```

### `pod-container-enter.sh`

Same idea as `container-enter.sh`, but starting from a Kubernetes pod + container name instead of a node-local container name — for when you don't have a shell already open on the right node. Resolves the pod's node and the container's exact ID via `kubectl`, `scp`s `container-enter.sh` to that node, then `ssh -t`s in to run it there with `--id` (so there's no node-local name ambiguity to worry about) and cleans up the copied script on exit, success or failure.

`container-enter.sh` is copied over rather than piped through the SSH connection's stdin: piping a script via `ssh ... bash -s -- args < script` consumes stdin transferring the script itself, so the interactive shell `nsenter` hands back at the end would inherit an already-exhausted stdin instead of the terminal.

**Dependencies:** `kubectl` (configured for the target cluster), `jq`, `ssh`, `scp`. The SSH target needs a user that can reach the node directly (or via `--ssh-jump`) and has (or can `sudo` into) root, since `container-enter.sh` needs it there.

**Usage:**

```bash
./pod-container-enter.sh mypod app                                    # current namespace/context
./pod-container-enter.sh mypod app -n prod -c my-cluster-context      # explicit namespace/context
./pod-container-enter.sh mypod app --ssh-user ec2-user --ssh-key ~/.ssh/id_rsa
./pod-container-enter.sh mypod app --ssh-jump bastion.example.com     # via a bastion
./pod-container-enter.sh mypod app --host-shell                       # passed through to container-enter.sh
./pod-container-enter.sh -h | --help
```

### `container-inspect.sh`

Inspects a container's namespace isolation, cgroup membership, and resource limits (CPU/memory/PIDs), and lists its open listening ports. Useful for checking whether a container is sharing namespaces with the host and what limits its cgroup actually has applied.

**Dependencies:** `jq`, `crictl` (and `nsenter`/`ss` for the network section — typically already on the host).

**Usage:**

```bash
./container-inspect.sh <container-id>   # resolves the PID via crictl, then inspects it
./container-inspect.sh --pid <pid>      # inspect a known PID directly
./container-inspect.sh -h | --help
```

Run directly without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/hrishin/until-scripts/refs/heads/main/container-inspect.sh | bash -s -- 3d8fe8caa81ca
```

### `disk-usage-report.sh`

Reports top disk consumers on a Linux host (largest directories and files under a given path) and runs a `df`-vs-`du` drift check on a filesystem. When `df` reports more used space than `du` can account for, it's almost always a process still holding a deleted (unlinked) file open — the script finds those via `lsof +L1` (falling back to a `/proc/*/fd` scan if `lsof` isn't installed), lists the offending command/PID/fd/path, and sums how much of the gap they explain.

**Dependencies:** GNU `du`/`find`/`df` (Linux only — relies on `/proc` and GNU-specific flags like `-B1`, `-d1`, `-printf`); `lsof` optional but recommended.

**Usage:**

```bash
./disk-usage-report.sh                                    # scans / , top 15
./disk-usage-report.sh -p /var -n 20                       # scan /var, top 20
./disk-usage-report.sh -m /data                             # drift-check a specific mount
./disk-usage-report.sh -h | --help
```

Run as root (or with `sudo`) for a complete open-file scan — otherwise it only sees your own processes' file descriptors. Walking a large filesystem with `du`/`find` can take a while; permission-denied subdirectories are skipped rather than aborting the scan.

### `flux-status.sh`

Reports FluxCD health end-to-end: lists controller pods (flagging non-`Running`/not-ready/
high-restart ones, and for each one, the container's exit code, terminate reason (e.g.
`OOMKilled`), and recent Events pulled from `kubectl describe pod`), lists Kustomizations,
HelmReleases, and all source types (Git/OCI/Helm repositories, HelmCharts, Buckets), aggregates
every resource whose `Ready` condition isn't `True` into one failing-resources summary, and tails
each controller's logs for recent `error`/`failed`/`retry`/`panic` lines. Does not check Flux
CLI/controller versions or image tags.

**Dependencies:** `kubectl` (configured for the target cluster), `flux` CLI, `jq`.

**Usage:**

```bash
./flux-status.sh                                            # flux-system ns, current context
./flux-status.sh -n flux-system -c my-cluster-context        # explicit namespace/context
./flux-status.sh -s 6h -l 50                                 # look back 6h, up to 50 log lines/pod
./flux-status.sh -h | --help
```

### `gpu-node-debug.sh`

Diagnoses GPU issues on Kubernetes GPU nodes. Cluster-wide (via `kubectl`/`jq`/`helm`): lists GPU
nodes with their allocatable/capacity GPU counts and scheduled GPU pods, checks the GPU Operator's
`nvidia-device-plugin-daemonset`/`nvidia-container-toolkit-daemonset` rollout status, reads the GPU
Operator Helm release's `toolkit.env` (`CONTAINERD_CONFIG`/`CONTAINERD_SOCKET`) and
`migManager.enabled`/`mig.strategy`, and checks every GPU node's `nvidia.com/mig.config` /
`nvidia.com/mig.config.state` labels. On a GPU node (run directly via SSH, or inside a
`kubectl debug node/<name>` session): parses `ps` output to work out which containerd instance
kubelet's CRI socket actually resolves to — a node can run more than one containerd — then checks
that instance's `config.toml` for the NVIDIA runtime class, verifies its `BinaryName` binary exists,
lists `/dev/nvidia*` devices, runs `nvidia-smi` (and `nvidia-smi mig -lgi`/`-lci`) if present, scans
the containerd journal for NVIDIA/runtime errors, and finally cross-checks the Helm `toolkit.env`
values against what was actually detected — a mismatch there means the GPU Operator is patching a
containerd instance kubelet never talks to, which is a common root cause for GPU workloads silently
never getting the `nvidia` runtime.

It also flags three MIG-specific pitfalls: a node with manually-carved GPU Instances but no
`nvidia.com/mig.config` label (the MIG Manager treats "no label" as target `all-disabled` and will
tear the slices down the moment it starts watching that node); a stuck reconciliation
(`mig.config.state=failed`/`pending`), with the exact `kubectl rollout restart` / label-toggle
commands needed to force a re-evaluation, since the manager only reacts to label events and never
polls hardware state; and a GPU/Compute Instance delete that fails with "In use by another client",
since the GI/CI hierarchy is enforced (destroy Compute Instances before their GPU Instance, and
evict any pod running on a slice before destroying it).

If SSH to the node isn't an option, `--node <name>` runs the same local diagnosis
without it: it creates a short-lived `kubectl debug node/<name>` pod (`--profile=general`, so it
gets `hostPID` and the host filesystem mounted at `/host`), pipes this same script into it over
`kubectl exec -i ... -- chroot /host bash -s -- --local-only` (chrooting means `ps`, `nvidia-smi`,
`journalctl`, etc. all resolve to the host's real binaries, no `--host-root` needed), streams the
§5-§10 output back live, and always deletes the debug pod on the way out — success or failure.
Only needs `kubectl`; the debug image (default `busybox:1.36`) only has to provide a shell and
`chroot`.

**Dependencies:** `kubectl`, `jq`, `helm` (all optional — cluster sections are skipped gracefully if
missing); `ps`, `awk`, `grep` for the local/node sections (present on any Linux node); `nvidia-smi`
and `journalctl` are used opportunistically if available.

**Usage:**

```bash
./gpu-node-debug.sh                                    # cluster overview + local node diagnosis
./gpu-node-debug.sh --nodes-only                        # cluster-wide GPU/operator overview only
./gpu-node-debug.sh --local-only                        # local kubelet/containerd diagnosis only
./gpu-node-debug.sh --local-only --host-root /host       # inside an unchrooted debug pod
./gpu-node-debug.sh --node <node-name>                   # local diagnosis via kubectl debug, no SSH
./gpu-node-debug.sh -n gpu-operator -c my-cluster-context
./gpu-node-debug.sh -h | --help
```

### `k8s-app-map.sh`

Traces the full request path for an app, in sequence: Ingress and/or Gateway API `HTTPRoute` (host, path, backend port) -> Service (name, path, port, targetPort) -> Endpoints (IP) -> Pod (name, container, listening port, node name) -> Node (IP, Ready state) -> NetworkPolicy (ingress rules reaching the pod). Matching Services are found via the `app` / `app.kubernetes.io/name` / `app.kubernetes.io/instance` labels (first one that hits wins), falling back to a substring match on Service name; `--selector` overrides this with an exact label selector. `HTTPRoute` lookups are skipped silently if the Gateway API CRDs aren't installed on the cluster. Along the way it flags likely misconfigurations as `MISMATCH`: an Ingress with no `status.loadBalancer` address (controller hasn't processed it), an HTTPRoute `parentRef` Gateway that doesn't exist or hasn't accepted the route (checked against `status.parents`' `Accepted`/`ResolvedRefs` conditions, not just the spec), an Ingress/HTTPRoute backend port that isn't one of the Service's actual ports, a Service selector that matches zero Pods (label typo), a Service selector that matches Pods but none are Ready, a Service `targetPort` that none of the backing Pod's containers declare, a readiness/liveness probe port that doesn't match a container port (both port checks skipped, not flagged, when the container declares no ports at all, since that's optional in Kubernetes), and — see below — a blocking NetworkPolicy.

**NetworkPolicy check:** lists every ingress-relevant policy selecting the target Pod — native Kubernetes `NetworkPolicy` (namespaced), and, if the CRDs are present, Cilium's `CiliumNetworkPolicy` (namespaced) and `CiliumClusterwideNetworkPolicy` (cluster-scoped) — with a `MISMATCH` for a policy that selects the pod with zero ingress rules (denies all ingress). Pass `--from-ns`/`--from-labels`/`--from-ip` to additionally test whether a specific caller would be let through each policy; each policy kind is evaluated and reported as an independent verdict rather than combined into one answer, since how a given CNI combines multiple policy sources for the same pod (union vs. intersection, Deny-rule precedence) varies. Only `matchLabels`/`endpointSelector.matchLabels` selectors are evaluated (`matchExpressions` are flagged as unverifiable, not silently ignored); `ipBlock.except` and Cilium `fromEntities` (e.g. `cluster`/`host`/`world`) are reported but not evaluated.

**Dependencies:** `kubectl` (configured for the target cluster), `jq`.

**Usage:**

```bash
./k8s-app-map.sh myapp                                  # current namespace, guesses the label
./k8s-app-map.sh myapp -n prod -c my-cluster-context     # explicit namespace/context
./k8s-app-map.sh myapp -A                                # search across all namespaces
./k8s-app-map.sh myapp -l app.kubernetes.io/name=myapp   # exact selector, skip the guesswork
./k8s-app-map.sh myapp -n prod --from-ns web --from-labels role=client   # test if `web` ns pods with role=client would reach it
./k8s-app-map.sh -h | --help
```

### `kubectl-trim`

A `kubectl` plugin — install it (any name matching `kubectl-<verb>` on `PATH` is picked up automatically) and it's invoked as `kubectl trim <resource>` (or `kubectl-trim <resource>` directly). Strips Kubernetes-managed noise fields from a `kubectl get -o json` resource — `status`, `kubectl`/`kapp` managed annotations and labels, `creationTimestamp`/`deletionTimestamp`, `finalizers`, `generation`, `uid`, `resourceVersion`, `selfLink`, `ownerReferences`, `managedFields` — for a readable/diffable view. `-t` replaces the default field list with your own comma-separated jq paths. Adapted from [luisdavim/dotfiles](https://github.com/luisdavim/dotfiles/blob/master/files/scripts/kubectl-trim), rewritten to build the `jq`/`yq` pipeline from argv arrays instead of `eval`ing a shell string assembled from resource/flag input.

**Dependencies:** `kubectl`, `jq`, and `yq` (only for the default YAML output — not needed with `-o json`).

**Zsh tab-completion:** `kubectl-trim <TAB>` (the direct executable-name form) gets `kubectl get`'s own completion — resource types, resource names, and every `get` flag — via a `_kubectl_trim` function in `configs/.profile` that delegates to `_kubectl`'s real dynamic completion (`kubectl __complete get ...`) with `get` spliced in as the verb. The two-word `kubectl trim <TAB>` plugin form isn't covered (would need patching `_kubectl`'s own subcommand dispatch, which is regenerated per kubectl version).

**Usage:**

```bash
kubectl trim pod/metac-0
kubectl trim svc cert-manager -n cert-manager           # YAML (default)
kubectl trim svc cert-manager -n cert-manager -o json    # JSON
kubectl trim pod metac-0 -t .metadata,.status            # custom field list
kubectl trim -h | --help
```

### `nlb-status.sh`

Fetches an AWS Network Load Balancer's overview, listeners, target groups, and per-target health status (with instance ID, private IP, AZ, node name, and health state) in a readable, color-coded report.

**Dependencies:** `aws` CLI (configured with credentials/region access), `jq`.

**Usage:**

```bash
./nlb-status.sh <nlb-arn> [region]   # region defaults to eu-west-2 if omitted
```

### `setup-zsh-env.sh`

Bootstraps a standard dev shell environment: installs zsh, tmux, git, curl, wget, Oh My Zsh, and the `history-search-multi-word` plugin; optionally installs `direnv`, `tfenv`, and `kubectl krew`; copies `configs/.profile`, `configs/.zshrc`, and `configs/.tmux.conf` from this repo into `~/.profile`, `~/.zshrc`, and `~/.tmux.conf`; and sets zsh as the default shell. Supports Debian/Ubuntu, RedHat/Fedora/CentOS, and macOS (Homebrew). Existing dotfiles are backed up (`<file>.bak.<timestamp>`) before being overwritten, and steps are skipped if the tool is already installed.

**Usage:**

```bash
./setup-zsh-env.sh
```

Comment out any of the optional installs (`install_direnv`, `install_tfenv`, `install_krew`) in `main()` if you don't want them. After it finishes, put secrets like `GH_TOKEN` in `~/.credentials` (auto-sourced by `.profile`) if needed, then re-open your terminal (or run `exec zsh`).

### `softnet.sh`

Decodes `/proc/net/softnet_stat` into a per-CPU report of packet processing (total frames, drops, `time_squeeze`, RPS-steered frames, flow limits, throttled events), flags CPU load imbalance, and prints concrete `sysctl`/`ethtool` remediation steps for any issues found (NAPI budget too low, backlog drops, IRQ affinity imbalance, RPS not enabled).

**Usage:**

```bash
bash softnet.sh                          # reads live /proc/net/softnet_stat
bash softnet.sh /proc/net/softnet_stat   # explicit path
cat /proc/net/softnet_stat | bash softnet.sh
NIC=eth0 bash softnet.sh                 # override the NIC name used in recommendations (default: ens2)
```
