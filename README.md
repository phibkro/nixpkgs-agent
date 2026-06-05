# nixpkgs-agent (phase 0)

Read-only scaffolding for an agent that triages nixpkgs build failures and suggests fixes — no PRs, no commits, no upstream interaction. The eventual goal (phases 1-4) is automated fix suggestions on the operator's own fork; phase 0 only proves out **discovery + classification + a local-LLM fallback** in dry-run.

Sibling of [pagu] and [pagu-box] — same hermit-crab family. Soft, untrusted agent inside a hard shell of mandatory build verification. Phase 0 has no shell yet because nothing is acted on; it's pure observation.

[pagu]: https://github.com/phibkro/pagu
[pagu-box]: https://github.com/phibkro/pagu-box

## What it does

1. **Discover** failure candidates (failing Hydra builds; stuck r-ryantm PRs).
2. **Classify** each by matching the build-log tail against `playbook.tsv` signatures.
3. **Fallback** for unmatched: ask `gemma4:12b` via local Ollama to describe the likely fix.
4. **Print** a dry-run report to stdout — what it _would_ do, if it could.

No PRs are opened. No code is modified. The fix recipes themselves don't run; only their _signatures_ run, to match. This is the read-only data-gathering phase that informs whether phases 1+ are worth building.

## Layout

```
playbook.tsv               # recipes: name, signature, fix-hint
playbook/                  # (future) one shell snippet per recipe
discover/
  hydra-fails.sh           # poll Hydra for x86_64-darwin failures
  r-ryantm-stuck.sh        # list r-ryantm PRs with failing CI
lib/
  log-tail.sh              # fetch + brotli-decompress a Hydra build log tail
classify.sh                # match a log tail against playbook signatures
agent-ask.sh               # fallback: ask local gemma4:12b via Ollama
dryrun.sh                  # orchestrate everything; print "would-do" report
```

## Run

```sh
./dryrun.sh                       # everything: discover → classify → ask gemma → report
./discover/hydra-fails.sh         # just the discovery layer
./classify.sh < some-tail.log     # match one log against the playbook
./agent-ask.sh < some-tail.log    # ask gemma4:12b only
```

Output is JSONL-on-stdout: one candidate per line, with the matched recipe (or `gemma_suggested`) and a one-line fix hint.

## Threat model (yes, even at phase 0)

This phase only reads. The risks are:

- **Ollama prompt-injection from a malicious build log.** If a build log contains attacker-controlled text engineered to trick gemma into a misleading suggestion, the human reviewer still has to land the fix. Mitigation: the agent never writes code in phase 0.
- **Hydra rate limits.** Polling discovery scripts respect `Cache-Control`. Cap is `2 polls/min`.
- **Cost.** Local gemma4:12b is free; the cost is GPU minutes on workstation.

When phases 1+ start writing diffs, the threat model has to be redone — that's a different document.

## Status

Phase 0 only. Pieces individually verified:

- `classify.sh` — matches 3/5 of today's PRs against the playbook
  (dasm/lrzip/sambamba match by signature; bacula and cpufetch needed unique fixes not in the playbook).
- `agent-ask.sh` against `gemma4:12b` via Ollama — produced reasonable triage for bacula
  (identified missing-symbol shape; suggested checking deps/config). Useful as a
  human-review signal even when it's not the exact fix.
- `learn.sh` — writes `skills/<pkg>.md` from git log + heuristic field detection. Phase
  0 destroys hand-edits on re-run (mitigation: `.prev` backup); proper merge is a phase
  0.5 task.

### Known TODOs

- `discover/hydra-fails.sh` falls back to the local `/tmp/tails/*.tail` cache.
  Phase 0.5: scrape failing jobs from Hydra's eval HTML; use `lib/log-tail.sh`
  to fetch tails on demand.
- `dryrun.sh` has a JSON-pipe glitch (likely jq-spawn overhead + chunk fragility).
  Each underlying script works individually; the orchestrator needs a rewrite that
  buffers cleanly.
- **opencode + gemma4:12b inside pagu-box** as a richer LLM runtime was tested
  (with `provider.ollama-local` in `~/.config/opencode/opencode.jsonc`). ollama
  serves responses (14s 200, 4k tokens) but opencode produces no visible stdout —
  likely a TUI-vs-pipe issue or a gemma response-shape mismatch with opencode's
  tool-use parser. Direct ollama API (`agent-ask.sh`) is the working path for
  phase 0. Opencode-as-runtime is a phase 1 task pending that debug.
