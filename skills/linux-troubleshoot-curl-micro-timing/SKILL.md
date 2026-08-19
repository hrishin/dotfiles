---
name: linux-troubleshoot-curl-micro-timing
description: SSH into a remote Linux host and run network diagnostics. Currently ships a curl timing breakdown (DNS, TCP connect, TLS handshake, TTFB, total) plus a full --trace-ascii protocol trace, rendered as a formatted table. Use when the user wants to troubleshoot connectivity, latency, or TLS handshake issues on a remote box, or asks things like "ssh in and check curl timing", "why is this request slow from that box", "diagnose TLS handshake", or "troubleshoot Linux host".
allowed-tools: Bash
metadata:
  author: hrishin
---

# Linux Host Troubleshooting (over SSH)

SSHes into a target host and runs network diagnostics there — measuring
from the target's own network path, not from the local machine. Ships one
diagnostic today: curl timing breakdown + TLS handshake analysis + full
protocol trace, backed by `curl-timing.sh` in the repo's root `scripts/`
directory (it's also installed to `~/.local/bin` like any other repo
script, so it can be run locally on its own). Add more diagnostics as
scripts following the same pattern as new troubleshooting needs come up.

## Step 1: Get the target and what to test

If not already given in the request, ask the user for:

- SSH target (`user@host`, plus port/identity file if non-default)
- The URL to test against (default `https://google.com` if the user just
  wants a general connectivity/DNS/TLS sanity check from that box)

## Step 2: Resolve the script path

BSD `readlink` has no `-f`, so resolve the skill's symlink portably, then
walk up to the repo root:

```bash
SKILL_LINK=~/.claude/skills/linux-troubleshoot-curl-micro-timing/SKILL.md
SKILL_TARGET="$(readlink "$SKILL_LINK" 2>/dev/null || echo "$SKILL_LINK")"
SKILL_DIR="$(cd "$(dirname "$SKILL_TARGET")" && pwd -P)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd -P)"
```

## Step 3: Run the diagnostic on the remote host

Stream the script into the target over SSH via stdin — nothing needs to be
copied onto the box permanently, and it leaves no artifact there except the
trace file itself (useful if the user wants to inspect it further in a
follow-up SSH session). Leave the trace-file argument unset so the script
picks a fresh `mktemp` path each run — a fixed path like `/tmp/curl.trace`
can collide with a stale file left by an earlier run (e.g. owned by a
different user), and the script's own trace/TLS sections would silently
serve that stale data instead of erroring:

```bash
ssh -o BatchMode=yes <ssh_target> 'bash -s' -- "<url>" \
    < "$REPO_ROOT/scripts/curl-timing.sh"
```

The script prints the resolved trace-file path in its "Full trace (...)"
header, so you always know where it landed on the remote host.

- `BatchMode=yes` fails fast on a missing/rejected key instead of hanging
  on an interactive password prompt. If it fails for that reason, tell the
  user and ask how they'd like to authenticate (agent forwarding, a
  specific identity file, etc.) rather than silently retrying or guessing
  at credentials.
- Pass a non-default port with `-p <port>`, or an identity file with
  `-i <path>`, as needed.
- The remote host needs `bash`, `curl`, `awk`, and `grep` — present on
  virtually every Linux box. If `curl` is missing, report that clearly and
  suggest the distro's install command (`apt-get install curl` /
  `yum install curl` / etc.) rather than trying to work around it.

## Step 4: Present the results

Print the script's stdout/stderr as-is — it already renders:

1. A timing table (DNS, TCP connect, TLS handshake (derived: appconnect −
   connect), pretransfer, redirect, TTFB, total) in both seconds and ms.
2. The full `--trace-ascii --trace-time` protocol trace.
3. A filtered view of just the TLS handshake lines from that trace, so the
   handshake (ClientHello → ServerHello → Certificate → Finished) is easy
   to find without scrolling through the whole dump.

Don't reformat or summarize away the table — it's already the deliverable.
After presenting it, call out anything that stands out (e.g. TLS handshake
dominating total time, a redirect adding a hop, a slow TTFB relative to
pretransfer suggesting server-side latency rather than connection setup).

## Notes

- This measures the connection *as seen from the target host*, which is
  the point — e.g. to check egress latency, DNS resolution, or a
  middlebox/proxy intercepting TLS from inside a specific VPC or data
  center.
- If curl exits non-zero (DNS failure, connection refused, TLS failure,
  timeout), the script still dumps whatever trace was captured before the
  failure — that partial trace is often the most useful diagnostic output
  in exactly that case, so don't treat a non-zero exit as "nothing to
  show."
