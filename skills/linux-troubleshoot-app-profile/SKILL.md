---
name: linux-troubleshoot-app-profile
description: SSH into a remote Linux host and profile a running application's resource usage — CPU, memory, disk I/O, and (best-effort) network I/O — for the target process and its full descendant tree over a fixed sampling window, to help diagnose performance issues. The user can identify the target by PID or by process name. Use when the user wants to profile an app's resource usage, asks things like "check CPU/memory usage for this process", "why is this app using so much disk I/O", "trace resource usage for PID X", "profile this application on the remote host", or "diagnose performance issues for <app>".
allowed-tools: Bash
metadata:
  author: hrishin
---

# Linux Application Resource Profiling (over SSH)

SSHes into a target host and profiles a process there — from the target's
own `/proc`, not the local machine. Resolves the target (PID or name) to
its full descendant-process tree, then samples CPU%, memory (RSS), and
disk I/O for that whole tree over a fixed window, reporting per-sample
totals plus the individual processes contributing the most CPU time.
Network I/O is best-effort (see Step 4). Backed by `app-profile.sh` in the
repo's root `scripts/` directory (also installed to `~/.local/bin` like any
other repo script, so it can be run locally on its own).

## Step 1: Get the target and what to profile

If not already given in the request, ask the user for:

- SSH target (`user@host`, plus port/identity file if non-default)
- What to profile: a PID, or a process name/substring (resolved via
  `pgrep` on the remote host — exact `comm` match first, then a
  full-cmdline substring match if that finds nothing)
- Optionally: how long to sample (`--duration`, default 10s), how often
  (`--interval`, default 1s), and how many top CPU contributors to report
  (`--top`, default 5)

If the name resolves to more than one process, the script lists the
candidates (PID, PPID, CMD) and exits — relay that list to the user and
ask them to pick a PID rather than guessing.

## Step 2: Resolve the script path

BSD `readlink` has no `-f`, so resolve the skill's symlink portably, then
walk up to the repo root:

```bash
SKILL_LINK=~/.claude/skills/linux-troubleshoot-app-profile/SKILL.md
SKILL_TARGET="$(readlink "$SKILL_LINK" 2>/dev/null || echo "$SKILL_LINK")"
SKILL_DIR="$(cd "$(dirname "$SKILL_TARGET")" && pwd -P)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd -P)"
```

## Step 3: Run the diagnostic on the remote host

Stream the script into the target over SSH via stdin — nothing needs to be
copied onto the box permanently:

```bash
ssh -o BatchMode=yes <ssh_target> 'bash -s' -- \
    -t "<pid-or-name>" -d "<duration>" -i "<interval>" -n "<top-n>" \
    < "$REPO_ROOT/scripts/app-profile.sh"
```

- `BatchMode=yes` fails fast on a missing/rejected key instead of hanging
  on an interactive password prompt. If it fails for that reason, tell the
  user and ask how they'd like to authenticate rather than silently
  retrying or guessing at credentials.
- Pass a non-default port with `-p <port>`, or an identity file with
  `-i <path>`, as needed (don't confuse this SSH `-i` with the script's
  own `-i/--interval`, which goes after `--`).
- The remote host needs `bash` and `pgrep`/`ps` (procps) — present on
  virtually every modern Linux distro; that's the only hard dependency.
  `ss` (iproute2) is a soft dependency: if it's missing, the script warns
  once and just skips the active-connections section rather than failing.
- **Root matters here more than in most diagnostics.** Without root, the
  script can only read `/proc/<pid>` for processes owned by the SSH user,
  so it warns and may under-report CPU/memory/disk I/O for a target owned
  by another user (e.g. a system service). If the user hits that warning
  and the target is a privileged process, suggest re-running with `sudo`
  prefixed inside the remote command, e.g.:
  `ssh ... 'sudo bash -s' -- -t ...`.
- The sampling window blocks for the full `--duration` (default 10s) —
  don't assume the command has hung if it takes that long to return.

## Step 4: Present the results

Print the script's stdout/stderr as-is — it already renders, in order:

1. **Process tree** — every PID under the target (`ps -o pid,ppid,user,
   %cpu,%mem,etimes,stat,cmd`), plus the host's core count (`nproc`), so
   the user has both what's running and the denominator for interpreting
   CPU% before the numbers arrive. A `Z` in the `STAT` column is a
   zombie — a real diagnostic signal (something in the tree isn't
   reaping its children), not noise.
2. **Per-sample table** — one row per interval: live process count (as
   `N` or `N+MZ` when `M` zombies are present in the tree — zombies are
   called out separately rather than padding the live count, and are
   excluded from the CPU/memory/I/O sums since they hold no real
   resources), total CPU% across the tree (can exceed 100% on
   multi-core workloads — that's expected, not a bug; compare against
   the core count from step 1), total RSS in MB, and disk read/write
   rates. `OTHER I/O/s` is a labeled *heuristic* for non-disk I/O
   (network, pipes, sockets), derived from `/proc/<pid>/io`'s
   `rchar`/`wchar` minus `read_bytes`/`write_bytes` — call out clearly
   that it's an approximation, not a precise network figure. On a wide
   tree (>30 processes) the script also warns that it's adding its own
   nontrivial overhead to the host being profiled — relay that caveat if
   the user seems to be reading the numbers as if they were free.
3. **Active network connections** — sockets currently open by the tree
   (via `ss -tunp`), for qualitative context on what the app is talking
   to. If `ss` isn't installed remotely, this section says so explicitly
   instead of silently reporting no connections.
4. **Network I/O via nethogs** — only appears if `nethogs` is installed
   *and* the script ran as root on the remote host; when it's missing,
   the script already told the user in step 3's warning. It captures on
   every non-loopback UP interface, not just the default route's, so
   overlay/CNI traffic (`cni0`, `flannel.1`, etc. on a k8s node) is
   included. If the user needs accurate network throughput and this
   section is absent, suggest installing `nethogs` and/or re-running as
   root, rather than treating the `OTHER I/O/s` heuristic as authoritative.
5. **Top CPU contributors** — the individual PIDs in the tree that burned
   the most CPU time over the window, with peak memory and total disk I/O
   each accrued. This is usually the most actionable table for pinpointing
   *which* child process (e.g. a specific worker) is the actual offender
   in a multi-process app.

Don't reformat or summarize away the tables — they're already the
deliverable. After presenting them, call out anything that stands out
(e.g. one worker PID dominating CPU while siblings idle, disk write rate
sustained near the device's expected ceiling, memory climbing sample over
sample suggesting a leak rather than steady-state usage).

## Notes

- This measures usage *as seen from the target host*, from that host's own
  `/proc` — the point, since that's where the actual resource contention
  lives.
- The process tree is re-walked every sample, so it correctly picks up
  short-lived children spawned mid-window (e.g. a prefork server cycling
  workers) and drops ones that exited.
- If the target process exits mid-run, the script stops sampling early
  and still prints whatever it captured — that's useful partial data, not
  a failure to relay as an error.
- CPU% per sample is computed from `/proc/<pid>/stat` tick deltas divided
  by the sampling interval, aggregated across the whole tree — it reflects
  actual scheduled CPU time, not `ps`'s since-process-start average.
- If the SSH session is interrupted mid-run (Ctrl-C, dropped connection)
  while a `nethogs` capture is active, the script's `EXIT` trap still
  kills it and removes its temp log on the remote host — no orphaned
  root packet-capture process left behind.
