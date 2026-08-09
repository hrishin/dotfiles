#!/usr/bin/env bash
# Shared symlink-loop helpers, sourced by install-local-bin.sh and
# install-skills.sh. Not meant to be run directly.
set -euo pipefail

# link_tree <src_dir> <dest_dir> [skip_basename ...]
# Symlinks every direct child of <src_dir> (files and directories) into
# <dest_dir>, replacing anything already at the destination. Basenames
# passed as extra args are skipped entirely.
link_tree() {
    local src_dir="$1"
    local dest_dir="$2"
    shift 2
    local skip=("$@")

    mkdir -p "$dest_dir"

    local entry base target skip_name skipped
    for entry in "$src_dir"/*; do
        [ -e "$entry" ] || continue
        base="$(basename "$entry")"

        skipped=false
        for skip_name in "${skip[@]:-}"; do
            if [ "$base" = "$skip_name" ]; then
                skipped=true
                break
            fi
        done
        [ "$skipped" = true ] && continue

        target="$dest_dir/$base"
        if [ -L "$target" ] || [ -e "$target" ]; then
            rm -rf "$target"
        fi
        ln -s "$entry" "$target"
        echo "✅ Linked $target -> $entry"
    done
}

# prune_dead_symlinks <src_dir> <dest_dir>
# Removes symlinks in <dest_dir> that point somewhere under <src_dir> but
# whose target no longer exists there (e.g. a script or skill was removed
# from the repo since the last install).
prune_dead_symlinks() {
    local src_dir="$1"
    local dest_dir="$2"

    [ -d "$dest_dir" ] || return 0

    local entry resolved
    for entry in "$dest_dir"/*; do
        [ -L "$entry" ] || continue
        resolved="$(readlink "$entry")"
        case "$resolved" in
        "$src_dir"/*)
            if [ ! -e "$resolved" ]; then
                rm -f "$entry"
                echo "ℹ️  Removed dead symlink $entry"
            fi
            ;;
        esac
    done
}
