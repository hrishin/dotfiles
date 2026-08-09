#!/usr/bin/env bash
# Shared helpers sourced by other scripts in this repo. Not meant to be run
# directly, and skipped by install-local-bin.sh (see LOCAL_BIN_SKIP).
set -euo pipefail

err() {
    echo "❌ $*" >&2
}
