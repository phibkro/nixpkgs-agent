#!/usr/bin/env bash
# classify.sh — match a build-log tail (on stdin) against playbook.tsv
# signatures. Outputs the FIRST match as JSON, or `{"name": "no_match"}`.
#
# Usage:
#   ./classify.sh < some-tail.log
#   ./lib/log-tail.sh 330206792 | ./classify.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${HERE}/playbook.tsv"

# Read whole stdin once so we can grep it multiple times.
LOG="$(cat)"

# Skip header; iterate rows. Use process substitution so the loop runs in
# the parent shell (a piped `while` runs in a subshell, where `exit` only
# kills the subshell and leaves the no_match fallback firing).
while IFS=$'\t' read -r name signature fix_hint; do
  [ -z "$name" ] && continue
  if printf '%s' "$LOG" | grep -E -q "$signature"; then
    capture="$(printf '%s' "$LOG" | grep -E -o "$signature" | head -1 || true)"
    nix shell nixpkgs#jq -c jq -n \
      --arg name "$name" \
      --arg fix_hint "$fix_hint" \
      --arg matched "$capture" \
      '{name: $name, fix_hint: $fix_hint, matched_line: $matched}'
    exit 0
  fi
done < <(tail -n +2 "$PLAYBOOK")

nix shell nixpkgs#jq -c jq -n '{name: "no_match"}'
