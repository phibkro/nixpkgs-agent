#!/usr/bin/env bash
# r-ryantm-stuck.sh — find r-ryantm version-bump PRs that are open + failing CI.
#
# Most of these get stuck on a stale nested hash (npmDepsHash, vendorHash,
# bun lockfile hash, cargoHash, …). The fix is mechanical: pull the actual
# hash from the build log and sed it in.
#
# Output: JSONL on stdout. One object per PR.

set -euo pipefail

LIMIT="${1:-30}"

gh pr list --repo NixOS/nixpkgs \
  --state open --author r-ryantm \
  --search "status:failure" \
  --limit "$LIMIT" \
  --json number,title,updatedAt,statusCheckRollup 2>&1 \
| nix shell nixpkgs#jq -c jq '.[] | {
    package: (.title | split(":")[0] | gsub("^\\s+|\\s+$"; "")),
    pr: .number,
    title: .title,
    updated_at: .updatedAt,
    failing_checks: ([.statusCheckRollup[]?
      | select(.conclusion == "FAILURE" or .state == "FAILURE")
      | (.name // .context)] | unique),
    log_kind: "pr_check"
  }'
