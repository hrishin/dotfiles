#!/usr/bin/env bash
# Standalone: runs on the remote host via `ssh ... 'bash -s' < this-file`,
# so it must not depend on anything from this repo (e.g. util.sh).
# -H/--host re-execs this same script remotely over SSH (piping itself in
# exactly that way), so it can also be run directly from your own machine
# without crafting that ssh command by hand.
#
# Lists each real (human) user's primary and supplementary group
# memberships, one row per group:
#
#   USERNAME  USERID  GROUP     GROUPID
#   hrishi    1000    hrishi    1000
#                     research  200
#
# Commands used to gather this:
#   getent passwd             - username, uid, primary gid (one line per
#                               user; same data as /etc/passwd)
#   getent group <gid|name>   - resolve a group's name<->gid (same data as
#                               /etc/group)
#   id -Gn <user>             - a user's full group list (primary +
#                               supplementary), by name
#   groups <user> / id <user> - quicker one-line view of the same thing
#                               for a single user, if you don't need the
#                               table
set -uo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-H|--host <ssh-target>] [-a|--all]

  -H, --host <target>  run on a remote host via \`ssh <target>\` (passes
                       through anything in your ssh_config: user@host,
                       port, identity file, etc.)
  -a, --all            include system accounts too (default: only users
                       with UID >= 1000 and a real login shell)
  -h, --help           this help
EOF
}

HOST=""
ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
    -H | --host)
        HOST="$2"
        shift 2
        ;;
    -a | --all)
        ALL=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

if [[ -n "$HOST" ]]; then
    remote_args=()
    [[ "$ALL" -eq 1 ]] && remote_args+=(--all)
    # The remote `bash -s` re-reads this whole script from stdin and runs
    # it as a fresh process, so the argument-parsing loop above runs again
    # there too — --all forwarded through remote_args, no -H this time (so
    # it falls through past this block into the report logic instead of
    # trying to ssh again).
    exec ssh -o BatchMode=yes "$HOST" 'bash -s' -- "${remote_args[@]}" <"$0"
fi

{
    printf 'USERNAME\tUSERID\tGROUP\tGROUPID\n'
    while IFS=: read -r name _ uid gid _ _ shell; do
        if [[ "$ALL" -ne 1 ]]; then
            [[ "$uid" -lt 1000 ]] && continue
            case "$shell" in
            */nologin | */false) continue ;;
            esac
        fi

        primary_group="$(getent group "$gid" | cut -d: -f1)"
        printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$primary_group" "$gid"

        for g in $(id -Gn "$name" 2>/dev/null); do
            [[ "$g" == "$primary_group" ]] && continue
            gid2="$(getent group "$g" | cut -d: -f3)"
            printf '\t\t%s\t%s\n' "$g" "$gid2"
        done
    done < <(getent passwd)
} | column -t -s $'\t'
