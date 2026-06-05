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
# The sandbox boundary is pagu-box's strict profile + the minimum extras
# opencode needs to remember its session:
#   * $PWD (the worktree)         — bound RW
#   * ~/.config/opencode          — opencode config (provider, model)
#   * ~/.local/share/opencode     — opencode session state (sqlite DB)
#   * ~/.cache/opencode           — opencode models index
#   * /tmp, /nix/store, /etc      — toolchain (via strict's defaults)
#   * $HOME everywhere else       — tmpfs (no ~/.ssh, no ~/.config/git,
#                                   no ~/.aws, no ~/.claude, etc.)
#   * Network                     — FULL for now (phase 1 caveat).
#                                   Future: Claw Patrol — pagu's
#                                   credential-injecting egress proxy,
#                                   currently on pagu's roadmap.
#
# Git identity is injected via environment variables (GIT_AUTHOR_NAME etc.)
# — ~/.config/git is NOT bound, so the agent's commits are explicitly
# tagged as nixpkgs-agent, not the operator. The agent CAN commit to its
# own branch; it CANNOT push (no SSH key, no GitHub token in the sandbox).
# On exit, it writes a sentinel file the wrapper script picks up to know
# whether the diff is ready for the operator to push.

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
  echo "- **Any nixpkgs tool, on demand.** \`nix shell nixpkgs#<pkg> -c <cmd>\`"
  echo "  pulls anything from nixpkgs without installing — ripgrep, jq, curl,"
  echo "  patchutils, scc, hyperfine, the lot. Don't get blocked on"
  echo "  \"\$X is not on PATH\"; reach for nix shell first."
  echo "- **nix-build** is your verification tool. \`nix-build -A $PKG --no-out-link\`"
  echo "  is what you should run after every edit. Only linux builds are"
  echo "  available inside this sandbox (no ssh credentials in here). If the"
  echo "  failure is darwin-only, document the fix and let the operator verify."
  echo "- **Web access**. Lean on WebFetch / WebSearch for canonical reference"
  echo "  material. Highest-quality sources, in order:"
  echo "    - nixpkgs source itself: https://github.com/NixOS/nixpkgs"
  echo "      (search PRs and issues for this package + the same error signature;"
  echo "      maintainers' answers are usually findable)"
  echo "    - The nixpkgs manual: https://nixos.org/manual/nixpkgs/"
  echo "    - Upstream source + issue tracker for the package being fixed"
  echo "    - Apple's developer docs (for darwin failures)"
  echo "    - StackOverflow / GitHub Discussions as fallback"
  echo "  When a reference informs your fix, **cite the URL** in the commit"
  echo "  message so the human reviewer can verify."
  echo "- **Git is configured.** \`git config user.name\` and \`user.email\` are"
  echo "  injected as env vars (you'll see \`nixpkgs-agent <noreply@…>\`). Commit"
  echo "  freely on the current branch (\`$BRANCH\`). Don't try to push — there"
  echo "  are no credentials in the sandbox; the operator pushes from outside."
  echo
  echo "## What you CANNOT do"
  echo
  echo "- Push to any remote, or open a PR (no credentials)"
  echo "- SSH anywhere (no SSH key inside)"
  echo "- Touch \$HOME outside ~/.config/opencode + ~/.local/share/opencode +"
  echo "  ~/.cache/opencode (your own state)"
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
  echo "4. Verify with \`nix-build -A $PKG --no-out-link\` until green."
  echo "5. \`git add\` + \`git commit\` a single coherent commit on \`$BRANCH\`."
  echo "   Conventional shape: \`$PKG: <what changed>\` subject, body explains"
  echo "   the cause and cites references."
  echo "6. Drop a sentinel file when you're done so the operator picks it up:"
  echo "   \`echo \"ready\" > .agent-status\` (or \`echo \"giving up — \$REASON\""
  echo "   > .agent-status\` if you couldn't fix it). Then exit."
} > "$CONTEXT_FILE"

# ---- spawn agent inside pagu-box strict ----
# Opencode (not Claude): no Anthropic credential needed in the sandbox.
# Allow opencode state to persist so it can resume sessions across
# invocations. Git identity is set in the calling env and passed through
# pagu-box's --env so the agent CAN commit to its branch. It cannot push
# (no SSH key, no GitHub token).
cd "$WORKTREE"
export GIT_AUTHOR_NAME="nixpkgs-agent"
export GIT_AUTHOR_EMAIL="noreply@nixpkgs-agent.invalid"
export GIT_COMMITTER_NAME="nixpkgs-agent"
export GIT_COMMITTER_EMAIL="noreply@nixpkgs-agent.invalid"

exec box --profile=strict \
  --allow "$HOME/.config/opencode" \
  --allow "$HOME/.local/share/opencode" \
  --allow "$HOME/.cache/opencode" \
  --env GIT_AUTHOR_NAME \
  --env GIT_AUTHOR_EMAIL \
  --env GIT_COMMITTER_NAME \
  --env GIT_COMMITTER_EMAIL \
  -- opencode --model 'ollama-local/gemma4:12b-32k'
