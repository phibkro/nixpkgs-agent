#!/usr/bin/env bash
# solve.sh — minimal agent harness.
#
# Takes a failing nixpkgs package, spins up a fresh git worktree on a
# fix branch, drops a Claude Code session inside it under pagu-box
# strict, and gives the agent the tight starting context (failure log,
# package path, verification command). When the agent exits, prints the
# diff for human review. Push is the operator's call — there is no SSH
# key inside the sandbox.
#
# Usage:
#   ./solve.sh <package>
#   ./solve.sh <package> --branch fix-libmspub-darwin
#   ./solve.sh <package> --hydra-build 330238590
#
# The sandbox boundary is pagu-box's strict profile:
#   * $PWD (the worktree)         — bound RW
#   * ~/.claude                   — agent state
#   * ~/.config/git               — RO (commits get identity)
#   * ~/.nix-profile, /nix/store  — RO toolchain
#   * $HOME everywhere else       — tmpfs
#   * Network                     — FULL (phase 1 caveat; restricted-egress TODO)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXPKGS="${NIXPKGS:-/srv/share/projects/nixpkgs}"
HYDRA_BUILD=""
BRANCH=""

usage() {
  sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)        usage 0 ;;
    --branch)         BRANCH="$2"; shift 2 ;;
    --hydra-build)    HYDRA_BUILD="$2"; shift 2 ;;
    --)               shift; break ;;
    -*)               echo "solve: unknown option '$1'" >&2; exit 64 ;;
    *)                break ;;
  esac
done

PKG="${1:?need a package name (e.g. ./solve.sh libmspub)}"
BRANCH="${BRANCH:-fix-${PKG}-darwin}"
WORKTREE="/tmp/nixpkgs-agent-${PKG}"

# ---- prepare the worktree ----
if [ ! -d "$NIXPKGS/.git" ]; then
  echo "solve: $NIXPKGS isn't a nixpkgs git checkout" >&2
  exit 70
fi

cd "$NIXPKGS"
git fetch upstream master --quiet 2>/dev/null || true

if [ -d "$WORKTREE" ]; then
  echo "solve: reusing existing worktree at $WORKTREE" >&2
else
  git worktree add -f -B "$BRANCH" "$WORKTREE" upstream/master >&2
fi

# ---- gather the failure context ----
CONTEXT_FILE="$WORKTREE/.agent-context.md"
{
  echo "# Failing package: \`$PKG\`"
  echo
  echo "Branch: \`$BRANCH\`"
  echo "Worktree: \`$WORKTREE\`"
  echo
  echo "## Failure log tail"
  echo
  echo '```'
  if [ -n "$HYDRA_BUILD" ]; then
    "$HERE/lib/log-tail.sh" "$HYDRA_BUILD" 60
  elif [ -f "/tmp/tails/$PKG.tail" ]; then
    tail -60 "/tmp/tails/$PKG.tail"
  else
    echo "(no log available — run nix-build -A $PKG yourself to get one)"
  fi
  echo '```'
  echo
  echo "## Playbook signature match"
  echo
  if [ -f "/tmp/tails/$PKG.tail" ]; then
    "$HERE/classify.sh" < "/tmp/tails/$PKG.tail" | nix shell nixpkgs#jq -c jq '.'
  else
    echo "(no classification — no log to match against)"
  fi
  echo
  echo "## Your job"
  echo
  echo "1. Diagnose the failure from the log above (and \`git log -- pkgs/.../\$PKG\` if helpful)."
  echo "2. Edit the package.nix (or add a patch). Prefer a REAL fix over a test-disable;"
  echo "   if the test-disable is the right call, say so explicitly in the commit message."
  echo "3. Verify with \`nix-build -A $PKG --no-out-link\` (Linux) or by ssh-ing to mac"
  echo "   (\`ssh nori@100.102.29.85 'cd ~/nixpkgs && nix-build -A $PKG'\`)"
  echo "   if the bug is darwin-only."
  echo "4. When the build is green, commit with conventional \`<pkg>: <what changed>\`"
  echo "   plus a body explaining the cause and the fix."
  echo "5. Exit. The human reviews the diff before pushing."
  echo
  echo "You CANNOT push (no SSH key in the sandbox) or open PRs from in here — the human does that."
} > "$CONTEXT_FILE"

# ---- spawn agent inside pagu-box strict ----
cd "$WORKTREE"
exec pagu-box --profile=strict \
  --ro-allow "$HOME/.config/git" \
  --ro-allow "$HOME/.nix-profile" \
  --ro-allow "$HOME/.local/state/nix" \
  --ro-allow "$HOME/.deno" \
  --allow "/srv/share/projects/nixpkgs" \
  -- claude
