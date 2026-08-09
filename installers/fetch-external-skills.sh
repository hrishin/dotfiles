#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/util.sh
source "$SCRIPT_DIR/../scripts/util.sh"

SKILLS_DIR="$REPO_ROOT/skills"

# name|mode|repo_url|path_in_repo|license|author
#
#   fetch    - clone repo_url, copy path_in_repo flat into skills/<name>/
#              (dropping any category nesting), inject `metadata.author`
#              (and `license: <license>`, if the license field is
#              non-empty — leave it empty when the upstream repo has no
#              declared license, rather than falsely claiming one) into its
#              SKILL.md frontmatter.
#   preserve - skill is already vendored with local customisations; verify
#              it exists and report its source, but never overwrite it.
#              (license field is unused in this mode.)
REGISTRY=(
    "domain-modeling|fetch|https://github.com/mattpocock/skills|skills/engineering/domain-modeling|MIT|mattpocock"
    "pr-description|fetch|https://github.com/hrishin/dotfiles|skills/pr-description||hrishin"
    "conventional-commits|preserve|https://github.com/hrishin/dotfiles|skills/conventional-commits||bastos (customised via hrishin/dotfiles)"
)

declare -A CLONE_DIRS=()

cleanup() {
    local dir
    for dir in "${CLONE_DIRS[@]:-}"; do
        if [ -n "$dir" ]; then
            rm -rf "$dir"
        fi
    done
}
trap cleanup EXIT

# clone_repo <repo_url>
# Shallow-clones repo_url once per run (cached in CLONE_DIRS) and sets
# CLONE_DIR to the local checkout path. Runs in the caller's shell (not a
# command substitution) so the CLONE_DIRS cache and cleanup trap both see it.
CLONE_DIR=""
clone_repo() {
    local repo_url="$1"

    if [ -n "${CLONE_DIRS[$repo_url]:-}" ]; then
        CLONE_DIR="${CLONE_DIRS[$repo_url]}"
        return
    fi

    CLONE_DIR="$(mktemp -d)"
    git clone --quiet --depth 1 "$repo_url" "$CLONE_DIR"
    CLONE_DIRS["$repo_url"]="$CLONE_DIR"
}

# inject_frontmatter <skill_md> <license> <author>
# Adds `metadata.author: <author>` (and `license: <license>`, if non-empty)
# to a SKILL.md's YAML frontmatter, just before the closing `---`. No-op if
# already present.
inject_frontmatter() {
    local skill_md="$1"
    local license="$2"
    local author="$3"

    if grep -q "^metadata:" "$skill_md"; then
        return
    fi

    awk -v license="$license" -v author="$author" '
        BEGIN { delims = 0 }
        /^---$/ && delims < 2 {
            delims++
            if (delims == 2) {
                if (license != "") print "license: " license
                print "metadata:"
                print "  author: " author
            }
            print
            next
        }
        { print }
    ' "$skill_md" >"$skill_md.tmp"
    mv "$skill_md.tmp" "$skill_md"
}

for entry in "${REGISTRY[@]}"; do
    IFS='|' read -r name mode repo_url path_in_repo license author <<<"$entry"
    dest="$SKILLS_DIR/$name"

    case "$mode" in
    preserve)
        if [ ! -d "$dest" ]; then
            err "Vendored skill '$name' is missing at $dest (preserve mode expects it to already be vendored, from $repo_url/$path_in_repo)"
            exit 1
        fi
        echo "ℹ️  Preserving locally-customised skill '$name' (source: $repo_url/$path_in_repo)"
        ;;
    fetch)
        echo "⏳ Fetching '$name' from $repo_url..."
        clone_repo "$repo_url"
        clone_dir="$CLONE_DIR"
        sha="$(git -C "$clone_dir" rev-parse HEAD)"

        rm -rf "$dest"
        cp -R "$clone_dir/$path_in_repo" "$dest"
        inject_frontmatter "$dest/SKILL.md" "$license" "$author"

        echo "✅ Fetched '$name' from $repo_url@$sha"
        ;;
    *)
        err "Unknown fetch mode '$mode' for skill '$name'"
        exit 1
        ;;
    esac
done
