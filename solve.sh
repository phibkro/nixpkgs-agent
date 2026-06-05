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
# The sandbox boundary is pagu-box's strict profile, no extras:
#   * $PWD (the worktree)         — bound RW
#   * ~/.claude                   — agent state
#   * ~/.claude.json              — agent config
#   * /tmp, /nix/store, /etc      — toolchain (via strict's defaults)
#   * $HOME everywhere else       — tmpfs (no ~/.ssh, no ~/.config/git,
#                                   no ~/.aws, etc.)
#   * Network                     — FULL for now (phase 1 caveat).
#                                   Future: Claw Patrol — pagu's
#                                   credential-injecting egress proxy,
#                                   currently on pagu's roadmap.
#
# Because ~/.config/git is denied, commits from inside the sandbox would
# either fail or be authored as "nobody". The agent is told NOT to
# commit. The diff is the deliverable.

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
  echo "## Capabilities available to you"
  echo
  echo "- **Any nixpkgs tool, on demand.** \`nix shell nixpkgs#<pkg> -c <cmd>\` pulls"
  echo "  anything from nixpkgs without installing — ripgrep, jq, curl, patchutils,"
  echo "  scc, hyperfine, the lot. Don't get blocked on \"\$X is not on PATH\";"
  echo "  reach for nix shell first."
  echo "- **nix-build** is your verification tool. \`nix-build -A $PKG --no-out-link\`"
  echo "  on linux; \`ssh nori@100.102.29.85 'cd ~/nixpkgs && nix-build -A $PKG'\`"
  echo "  if the bug is darwin-only (the workstation Mac is reachable from this"
  echo "  sandbox)."
  echo "- **Web access** is available — use WebFetch / WebSearch for canonical"
  echo "  reference material. Lean on it. The first-rank sources for nixpkgs"
  echo "  fixes are:"
  echo "    - nixpkgs source itself: https://github.com/NixOS/nixpkgs (search PRs"
  echo "      and issues for the same package + the same error signature; the"
  echo "      maintainers' answer is usually findable)"
  echo "    - The nixpkgs manual: https://nixos.org/manual/nixpkgs/"
  echo "    - upstream source / issues for the package being fixed"
  echo "    - Apple's developer docs (for darwin failures)"
  echo "    - StackOverflow / GitHub Discussions if all else fails"
  echo "  When you find a referenced fix, write the URL in the changelog / commit"
  echo "  message so the human reviewer can verify."
  echo "- **Git** is on PATH; use it for blame, log, diff, etc. Don't \`git commit\`"
  echo "  inside the sandbox — there is no user identity here. Leave the diff in"
  echo "  the working tree; the human applies it from outside."
  echo
  echo "## What you CANNOT do"
  echo
  echo "- Push, open PRs, or any GitHub write action (no credentials in the sandbox)"
  echo "- Touch \$HOME outside ~/.claude (denied by pagu-box strict)"
  echo "- Modify nixpkgs anywhere outside this worktree"
  echo
  echo "## Your job"
  echo
  echo "1. Diagnose the failure from the log above. Look at:"
  echo "   - \`git log --oneline -10 -- <package-path>\` for prior bumps"
  echo "   - existing patches / postPatch / preConfigure in the package.nix"
  echo "   - whether the failure signature is darwin-specific, sandbox-specific,"
  echo "     or a real upstream bug"
  echo "2. Search the canonical references (see above) for the same error."
  echo "   If somebody has fixed this exact shape before, copy their approach."
  echo "3. Edit the package.nix (or add a patch). Prefer a REAL fix over a"
  echo "   test-disable; if the test-disable is the only reasonable answer,"
  echo "   leave a comment in the package.nix explaining the trade-off."
  echo "4. Verify with \`nix-build\` (see Capabilities above)."
  echo "5. When the build is green, leave the worktree as-is and exit."
  echo "   The human runs \`git diff\` and writes the commit + PR."
} > "$CONTEXT_FILE"

# ---- spawn agent inside pagu-box strict, no extras ----
# Sandbox is the worktree + ~/.claude + ~/.claude.json + the standard
# tmpfs $HOME / RO toolchain. No ~/.config/git (so no commits — by design),
# no ~/.ssh, no ~/.aws, no ~/.config/{sops,age,gh}, no ~/.nix-profile bind
# (the nix daemon socket via /nix/var/nix/daemon-socket is enough).
cd "$WORKTREE"
exec pagu-box --profile=strict -- claude
