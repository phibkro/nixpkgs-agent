#!/usr/bin/env bash
# hydra-fails.sh — discover failing builds.
#
# Phase 0 source: the /tmp/tails/*.tail cache left over from the earlier
# darwin-fix research session. It's a snapshot of the ~141 x86_64-darwin-
# only failures the agent surveyed there.
#
# Phase 0.5 TODO: poll Hydra's JSON API for fresh failures
# (https://hydra.nixos.org/jobset/nixpkgs/nixpkgs-26.05-darwin/evals).
# Hydra's API has known patchiness; the working approach is probably
# scraping the eval HTML for failing jobs, then fetching log tails via
# lib/log-tail.sh.
#
# Output: JSONL on stdout. One object per candidate:
#   { "package": "bacula", "log_source": "/tmp/tails/bacula.tail", ... }

set -euo pipefail

TAILS_DIR="${1:-/tmp/tails}"

if [ ! -d "$TAILS_DIR" ]; then
  echo "hydra-fails: no tails cache at $TAILS_DIR — phase 0.5 not implemented yet" >&2
  exit 0
fi

# Each file is named <attr>.tail. Strip the suffix for the package field.
find "$TAILS_DIR" -maxdepth 1 -type f -name '*.tail' | while read -r tail; do
  pkg="$(basename "$tail" .tail)"
  nix shell nixpkgs#jq -c jq -n \
    --arg package "$pkg" \
    --arg log_source "$tail" \
    '{package: $package, log_source: $log_source, log_kind: "file"}'
done
