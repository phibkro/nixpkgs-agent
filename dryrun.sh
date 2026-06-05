#!/usr/bin/env bash
# dryrun.sh — phase 0 orchestrator. Discover → classify → fallback to gemma
# → learn (codify per-package skill) → emit one JSON object per candidate
# on stdout. No PRs, no commits.
#
# Usage:
#   ./dryrun.sh                       # process every cached Hydra failure
#   ./dryrun.sh --limit 5             # first 5 only
#   ./dryrun.sh --no-gemma            # skip the LLM fallback
#   ./dryrun.sh --no-learn            # skip skill generation

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIMIT=0
USE_GEMMA=1
USE_LEARN=1

while [ $# -gt 0 ]; do
  case "$1" in
    --limit)     LIMIT="$2"; shift 2 ;;
    --no-gemma)  USE_GEMMA=0; shift ;;
    --no-learn)  USE_LEARN=0; shift ;;
    -h|--help)
      sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)           echo "dryrun: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

i=0
"$HERE/discover/hydra-fails.sh" | while read -r candidate; do
  [ -z "$candidate" ] && continue

  pkg=$(printf '%s' "$candidate" | nix shell nixpkgs#jq -c jq -r '.package')
  log_source=$(printf '%s' "$candidate" | nix shell nixpkgs#jq -c jq -r '.log_source')

  i=$((i + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$i" -gt "$LIMIT" ]; then break; fi

  log_tail="$(cat "$log_source")"

  classification="$(printf '%s' "$log_tail" | "$HERE/classify.sh")"
  name=$(printf '%s' "$classification" | nix shell nixpkgs#jq -c jq -r '.name')

  if [ "$name" = "no_match" ] && [ "$USE_GEMMA" -eq 1 ]; then
    suggestion="$(printf '%s' "$log_tail" | "$HERE/agent-ask.sh" 2>/dev/null || echo '{"name":"gemma_error"}')"
  else
    suggestion='null'
  fi

  if [ "$USE_LEARN" -eq 1 ]; then
    "$HERE/learn.sh" "$pkg" >/dev/null 2>&1 || true
  fi

  nix shell nixpkgs#jq -c jq -n \
    --argjson candidate "$candidate" \
    --argjson classification "$classification" \
    --argjson suggestion "$suggestion" \
    '{
      package: $candidate.package,
      log_source: $candidate.log_source,
      matched: $classification,
      gemma: $suggestion
    }'
done
