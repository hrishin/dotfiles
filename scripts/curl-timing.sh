#!/usr/bin/env bash
# Standalone: runs on the remote host via `ssh ... 'bash -s' < this-file`,
# so it must not depend on anything from this repo (e.g. util.sh).
set -uo pipefail

url="${1:-https://google.com}"
trace_file="${2:-$(mktemp /tmp/curl-trace.XXXXXX)}"

# A fixed default path would silently collide with a stale file left by a
# prior run (e.g. under a different user/owner). curl treats a trace file
# it can't open for writing as non-fatal: it dumps the trace to stderr
# instead and still exits 0, so the failure is invisible unless we check
# up front — fail loudly here rather than let the trace/TLS sections below
# silently serve stale or misplaced data.
if ! : >"$trace_file" 2>/tmp/curl-trace-check.$$; then
    echo "❌ Cannot write to trace file $trace_file: $(cat /tmp/curl-trace-check.$$ 2>/dev/null)" >&2
    rm -f /tmp/curl-trace-check.$$
    exit 1
fi
rm -f /tmp/curl-trace-check.$$

echo "⏳ Running curl timing diagnostic against $url ..."

curl_exit=0
curl -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_pretransfer} %{time_redirect} %{time_starttransfer} %{time_total}\n' \
    -o /dev/null -s -S \
    --trace-ascii "$trace_file" --trace-time \
    "$url" |
    awk -v target="$url" '{
        split("time_namelookup time_connect time_appconnect time_pretransfer time_redirect time_starttransfer time_total", names, " ")
        printf "\nTiming for %s\n", target
        printf "┌────────────────────┬──────────┬───────────┐\n"
        printf "│      Variable      │ seconds  │    ms     │\n"
        printf "├────────────────────┼──────────┼───────────┤\n"
        for (i = 1; i <= 7; i++) {
            ms = $i * 1000
            msstr = (ms == 0) ? "0 ms" : sprintf("%.3f ms", ms)
            printf "│ %-19s│ %-9.6f│ %-10s│\n", names[i], $i, msstr
            if (i < 7)
                printf "├────────────────────┼──────────┼───────────┤\n"
        }
        tls = ($3 - $2) * 1000
        printf "├────────────────────┼──────────┼───────────┤\n"
        printf "│ %-19s│ %-9.6f│ %-10s│\n", "tls_handshake(calc)", $3 - $2, sprintf("%.3f ms", tls)
        printf "└────────────────────┴──────────┴───────────┘\n"
    }'
curl_exit=$?

if [ "$curl_exit" -ne 0 ]; then
    echo "❌ curl exited with status $curl_exit — timing table above may be incomplete; trace below still useful for diagnosis." >&2
fi

echo ""
echo "--- Full trace ($trace_file) ---"
echo ""
if [ -s "$trace_file" ]; then
    cat "$trace_file"
else
    echo "ℹ️  No trace data captured (connection likely failed before any bytes were sent)."
fi

echo ""
echo "--- TLS handshake lines only ---"
echo ""
if [ -s "$trace_file" ] && grep -n -i "TLSv\|SSL connection\|handshake\|Server hello\|Client hello\|Certificate" "$trace_file"; then
    :
else
    echo "ℹ️  No TLS handshake lines found in trace."
fi

[ "$curl_exit" -eq 0 ] && echo "✅ Diagnostic complete."

exit "$curl_exit"
