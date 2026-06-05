#!/usr/bin/env just --justfile
# Convenience entry points for nixpkgs-agent (phase 0).

default: dryrun

# Run the orchestrator over every cached Hydra failure.
@dryrun *args:
    ./dryrun.sh {{args}}

# Show the playbook (recipe set the agent matches against).
@playbook:
    column -t -s "$(printf '\t')" playbook.tsv | head -40

# List discovered candidates without classifying them.
@discover:
    ./discover/hydra-fails.sh | nix shell nixpkgs#jq -c jq

# Show all generated skills (per-package update procedures).
@skills:
    @ls skills/ 2>/dev/null | head -20 || echo "(none yet — run \`just dryrun\` to populate)"

# Single-package classify test — `just classify bacula`
@classify pkg:
    cat /tmp/tails/{{pkg}}.tail | ./classify.sh

# Single-package gemma test — `just ask bacula`
@ask pkg:
    cat /tmp/tails/{{pkg}}.tail | ./agent-ask.sh

# Re-codify the per-package skill from current nixpkgs HEAD.
@learn pkg:
    ./learn.sh {{pkg}}

# Spawn a minimal agent harness on a failing package — pagu-box --profile=strict
# scoped to a fresh nixpkgs worktree on a fix-<pkg>-darwin branch. Human reviews
# the diff before pushing; the sandbox has no SSH key.
# Usage: just solve libmspub
@solve pkg *args:
    ./solve.sh {{pkg}} {{args}}
