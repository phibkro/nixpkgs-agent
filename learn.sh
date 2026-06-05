#!/usr/bin/env bash
# learn.sh — codify per-package update procedures.
#
# Given a package name, look at its git history in nixpkgs and either
# create a fresh `skills/<pkg>.md` or update an existing one. The skill
# becomes the agent's playbook entry for FUTURE bumps of that package:
# which hash fields to refresh, where they live, known gotchas, and any
# special steps the human had to take last time.
#
# Phase 0 behaviour: pure observation — reads git log, emits / updates
# the markdown. No PRs, no commits to nixpkgs. The skill is informational
# until phases 1+ start consuming it during dispatch.
#
# Usage:
#   ./learn.sh <package>            (uses default nixpkgs clone)
#   NIXPKGS=/path ./learn.sh <package>

set -euo pipefail

PKG="${1:?need a package name}"
NIXPKGS="${NIXPKGS:-/srv/share/projects/nixpkgs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${HERE}/skills"
SKILL_FILE="${SKILL_DIR}/${PKG}.md"

mkdir -p "$SKILL_DIR"

# Locate the package.nix. nixpkgs uses pkgs/by-name/<aa>/<pkg>/package.nix
# for new-style packages; older packages live under pkgs/applications/
# pkgs/development/ etc. Try by-name first; fall back to grep.
PKG_PATH="$(cd "$NIXPKGS" && \
  ls "pkgs/by-name/${PKG:0:2}/${PKG}/package.nix" 2>/dev/null \
  || git grep --files-with-matches -E "^\s*pname\s*=\s*\"${PKG}\"" -- 'pkgs/**/*.nix' 2>/dev/null \
       | head -1 \
  || echo "")"

if [ -z "$PKG_PATH" ]; then
  echo "learn: cannot locate package.nix for '$PKG'" >&2
  exit 70
fi

DIR_PATH="$(dirname "$PKG_PATH")"
LAST_VERIFIED="$(date +%Y-%m-%d)"

# Last ~10 commits touching the package directory.
HISTORY="$(cd "$NIXPKGS" && git log --oneline -n 10 -- "$DIR_PATH" 2>/dev/null || echo "")"

# Inspect package.nix for hash-flavoured attributes; informs what needs
# refreshing on each bump. This is regex-shallow but covers ~95% of cases.
HASH_FIELDS="$(grep -nE 'hash\s*=|sha256\s*=|vendorHash\s*=|npmDepsHash\s*=|outputHash\s*=|cargoHash\s*=|cargoLock\s*=' "${NIXPKGS}/${PKG_PATH}" 2>/dev/null \
  | head -10 || true)"

# Detect builder type (heuristic).
BUILDER="$(grep -nE '\b(buildGoModule|buildRustPackage|buildPythonPackage|buildNpmPackage|buildBunPackage|stdenvNoCC?\s*\.\s*mkDerivation|vscode-utils\.buildVscodeMarketplaceExtension)\b' "${NIXPKGS}/${PKG_PATH}" 2>/dev/null \
  | head -3 || true)"

# Note: no auto-update of EXISTING skills yet. Phase 0 writes fresh every
# run; this destroys hand-edited notes. Mitigation: emit a backup if a
# skill already exists.
if [ -f "$SKILL_FILE" ]; then
  cp "$SKILL_FILE" "${SKILL_FILE}.prev"
fi

cat > "$SKILL_FILE" <<EOF
---
package: ${PKG}
package_path: ${PKG_PATH}
last_verified: ${LAST_VERIFIED}
---

# How to bump \`${PKG}\`

## Builder detected

\`\`\`
${BUILDER:-unknown — inspect ${PKG_PATH} manually}
\`\`\`

## Hash fields to refresh on bump

\`\`\`
${HASH_FIELDS:-none detected (inspect manually)}
\`\`\`

## Recent bump history (last 10 commits touching ${DIR_PATH})

\`\`\`
${HISTORY:-none in shallow clone}
\`\`\`

## Procedure

1. Identify the new upstream version.
2. Update \`version\` (or the version line in \`manifest.json\` if the package uses one — see claude-code).
3. Update the **src hash** by setting it to \`lib.fakeHash\` and rebuilding; nix prints the real hash.
4. Update **other hash fields** above the same way; each needs its own \`nix-build\` cycle.
5. \`nix-build -A ${PKG}\` to verify.
6. For Marketplace / multi-platform binaries: refresh per-platform hashes by curl + nix-prefetch-url, OR run successive \`nix-build --system <X>\` calls.

## Known gotchas

(Populate from past PR comments and commit bodies. Phase 0 leaves this
empty; the human / a later phase can add entries.)

## Linked skills

(Future: cross-references to playbook entries that have triggered for
this package — e.g. if \`darwin_libgcc_s_1\` matched once, link it here so
the next bump pre-applies the fix.)
EOF

echo "learn: wrote $SKILL_FILE" >&2
