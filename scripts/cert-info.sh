#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  cert-info.sh
#  Prints TLS certificate details for a domain: curl -v for the live HTTPS
#  handshake summary (subject/issuer/dates/verify result, exactly as curl
#  itself reports them during the real TLS negotiation), then
#  openssl s_client + x509 for the full decoded certificate (all
#  extensions, SANs, serial, fingerprint, public key) plus an expiry check.
#
#  Usage: ./cert-info.sh <domain-or-url> [-p|--port <port>] [-q|--quick]
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

usage() {
    echo -e "${BOLD}Usage:${RESET}"
    echo "  $0 <domain-or-url> [-p|--port <port>] [-q|--quick]"
    echo "  $0 -h | --help"
    echo
    echo "  <domain-or-url>      a bare domain (example.com) or a full URL"
    echo "                       (https://example.com[:port][/path]) — scheme,"
    echo "                       path, and port (if present) are stripped/used"
    echo "  -p, --port <port>    TLS port to connect to (default: 443, or the"
    echo "                       port embedded in the URL if one was given)"
    echo "  -q, --quick          skip the full 'openssl x509 -text' dump; just"
    echo "                       the curl handshake summary + key facts + expiry"
    echo "  -h, --help"
    exit 0
}

TARGET=""
PORT=""
QUICK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
    -p | --port)
        [[ -z "${2:-}" ]] && {
            err "--port requires a value"
            exit 1
        }
        PORT="$2"
        shift 2
        ;;
    -q | --quick)
        QUICK=1
        shift
        ;;
    -h | --help) usage ;;
    -*)
        err "Unknown argument: $1"
        usage
        ;;
    *)
        if [[ -n "$TARGET" ]]; then
            err "Unexpected extra argument: $1"
            usage
        fi
        TARGET="$1"
        shift
        ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    err "Missing required <domain-or-url> argument."
    usage
fi

missing=()
for dep in curl openssl; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
fi

# ── parse host[:port] out of a bare domain or a full URL ──
HOST="$TARGET"
HOST="${HOST#*://}" # strip scheme, if any
HOST="${HOST%%/*}"  # strip path, if any
if [[ "$HOST" == *:* ]]; then
    [[ -z "$PORT" ]] && PORT="${HOST##*:}"
    HOST="${HOST%%:*}"
fi
[[ -z "$PORT" ]] && PORT=443

hdr "Target: $HOST:$PORT"

# ── §1 curl -v handshake summary ──
hdr "§1  curl -v TLS handshake"
curl_out="$(curl -vI --connect-timeout 10 --max-time 15 "https://$HOST:$PORT/" 2>&1 || true)"
handshake_lines="$(echo "$curl_out" | grep -E '^\*[[:space:]]*(subject:|issuer:|start date:|expire date:|subjectAltName:|SSL certificate verify|TLSv|ALPN|Server certificate)' || true)"

if [[ -z "$handshake_lines" ]]; then
    warn "curl produced no TLS handshake info — connection may have failed. Raw curl output:"
    echo "$curl_out" | tail -n 15 | sed 's/^/    /'
else
    echo "$handshake_lines" | sed 's/^\*/ /' | sed 's/^/   /'
fi

# ── §2 full certificate via openssl s_client + x509 ──
hdr "§2  Certificate details (openssl x509)"
cert_pem="$(echo | openssl s_client -connect "$HOST:$PORT" -servername "$HOST" 2>/dev/null | openssl x509 2>/dev/null || true)"

if [[ -z "$cert_pem" ]]; then
    err "Could not retrieve a certificate from $HOST:$PORT via openssl s_client."
    exit 1
fi

echo -e "  ${BOLD}Key facts${RESET}"
echo "$cert_pem" | openssl x509 -noout -subject -issuer -serial -dates -fingerprint -sha256 2>/dev/null | sed 's/^/    /'
echo -e "\n  ${BOLD}Subject Alternative Names${RESET}"
echo "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | sed 's/^/    /' || echo "    <none>"

# ── §3 expiry check (openssl -checkend, no manual date-math) ──
hdr "§3  Expiry"
if echo "$cert_pem" | openssl x509 -noout -checkend 0 &>/dev/null; then
    if echo "$cert_pem" | openssl x509 -noout -checkend 604800 &>/dev/null; then
        if echo "$cert_pem" | openssl x509 -noout -checkend 2592000 &>/dev/null; then
            ok "Valid, not expiring within 30 days."
        else
            warn "Expires within 30 days."
        fi
    else
        err "Expires within 7 days!"
    fi
else
    err "Certificate has already expired."
fi

if [[ "$QUICK" -eq 0 ]]; then
    hdr "§4  Full decoded certificate (openssl x509 -text)"
    echo "$cert_pem" | openssl x509 -noout -text | sed 's/^/  /'
fi

echo
