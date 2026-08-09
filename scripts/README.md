# Util scripts

Utility and performance/troubleshooting scripts for Linux hosts, containers, and AWS networking.

Each script is standalone — copy it to a host (or `curl` it directly, see examples below) and run it, no install step required beyond the dependencies noted per script.

## Scripts

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
