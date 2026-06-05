# nixpkgs-agent

A minimal agent harness for fixing nixpkgs build failures. The agent runs inside
`pagu-box --profile=strict` scoped to a fresh git worktree of nixpkgs on a fix
branch. It has read/write bash, the nix toolchain, git identity, and network
access. It cannot push (no SSH key in the sandbox) — the diff goes back to the
human for review and forwarding.

Sibling of [pagu] and [pagu-box] — same hermit-crab family. Soft, untrusted
agent inside a hard shell. The shell is the worktree + pagu-box; the agent is
whatever you spawn inside (Claude Code currently; opencode+gemma when its
pipeline stops hanging).

## The shape

```
just solve libmspub
  │
  └─ git worktree add -B fix-libmspub-darwin upstream/master
     │
     └─ pagu-box --profile=strict + worktree paths bound
        │
        └─ claude (started with a starting prompt containing failure log + task)
           │
           └─ … iterates: read package.nix, edit, nix-build, repeat …
              │
              └─ commit + exit
                  │
                  └─ human: git diff → review → push to fork
```

## Components

[pagu]: https://github.com/phibkro/pagu
[pagu-box]: https://github.com/phibkro/pagu-box

| Path | Role |
|---|---|
| `solve.sh` | The minimal agent harness. Spins up a worktree, writes `.agent-context.md` with the failure log + task, launches Claude under pagu-box. |
| `playbook.tsv` | Fast-path signatures. The starting prompt includes any match — saves the agent a round trip when the failure mode is one we've seen. |
| `classify.sh` | Match a build-log tail against the playbook. Tiny, fast, no LLM. |
| `agent-ask.sh` | Direct Ollama HTTP triage. Useful for batch surveys without spinning a full agent. |
| `learn.sh` | Per-package update procedure codification — reads nixpkgs git history + package shape and writes `skills/<pkg>.md` for future bumps. |
| `discover/hydra-fails.sh` | Currently reads from `/tmp/tails/*.tail` cache. Live polling is TODO. |
| `discover/r-ryantm-stuck.sh` | List failing r-ryantm version-bump PRs (a recurring source of stuck-on-stale-hash PRs). |

## Sandbox boundary

`solve.sh` wraps the agent in `pagu-box --profile=strict` with **no
additional binds** (`--ro-allow` is intentionally absent):

| Path | Access |
|---|---|
| `$PWD` (the worktree) | bound RW |
| `~/.config/opencode` + `~/.local/share/opencode` + `~/.cache/opencode` | bound RW (opencode state) |
| `/tmp` | tmpfs (writeable scratch) |
| `/nix/store` | RO (toolchain) |
| `/nix/var/nix/daemon-socket` | bound (`nix-build` works) |
| `/etc` (selected paths) | RO (`/etc/{static,profiles,resolv.conf,ssl,passwd,group}`) |
| `GIT_{AUTHOR,COMMITTER}_{NAME,EMAIL}` | injected as env (`nixpkgs-agent <noreply@…>`) |
| `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/{sops,age,gh,op}`, `~/.claude`, … | denied |
| `~/.config/git` | denied (identity comes from env vars instead) |
| `$HOME` everywhere else | tmpfs |
| Network | **full** for now (phase-1 caveat) |

The agent **can** commit to its `fix-<pkg>-darwin` branch — git identity is
injected via env vars so commits are explicitly authored as
`nixpkgs-agent <noreply@nixpkgs-agent.invalid>`. It **cannot** push (no
SSH key inside, no GitHub token) — the operator pulls the branch from outside
and pushes to their fork. On exit, the agent drops `.agent-status` (`ready`
or `giving up — <reason>`) so the wrapper knows what to do next.

**Network egress will tighten** when [Claw Patrol] — pagu's
credential-injecting egress proxy — ships. Until then, the agent is told
which sites it should consult (nixpkgs, the manual, upstream sources,
StackOverflow) via the starting prompt. Audit happens at the diff.

[Claw Patrol]: https://github.com/phibkro/pagu/blob/main/ROADMAP.md

## Run

```sh
just solve libmspub                              # worktree + agent on the bug
just solve libmspub --hydra-build 330238590      # explicit Hydra failure to seed
just classify libmspub                           # signature-only triage from cache
just ask libmspub                                # direct gemma triage
just learn opencode                              # codify update procedure
```

## Threat model

The agent has read/write inside a worktree and full network. Three real attacks:

1. **Prompt-injected build log.** A package's failure log contains attacker-crafted
   text engineered to convince the agent to e.g. add a backdoored fetchpatch.
   Mitigation: human review of the diff before pushing. Build verification is
   not enough — the agent could write a backdoor that builds fine.
2. **Exfil via curl in the build.** The agent could add a `postBuild` that POSTs
   data somewhere. The sandbox has no secrets to exfil; the worktree is a public
   nixpkgs fork. So the actual risk is just polluting the diff. Caught at review.
3. **Wasted CI cycles upstream.** A bad PR forwarded by the human burns reviewer
   time. Cost: a PR comment.

### Acknowledged limitations

- **No restricted egress yet.** "Egress to nix sites + StackOverflow only" was the
  ideal; pagu-box doesn't support per-domain whitelisting. v1 trusts the agent to
  behave + audits the diff. Tightening this is a real TODO — likely via a
  network-namespace + nftables rules approach.
- **No automatic submission.** Push to fork is the operator's call after reviewing
  the diff. This is the deliberate gate — no autonomous PRs.

## Status

`solve.sh` is the actual deliverable. Run it on any failing package and the agent
gets a worktree, the failure log, the playbook hint, and the keys to nix-build.
The diff is the output.

### TODOs

- **Restricted egress** via nftables in the sandbox.
- **Live Hydra polling** in `discover/hydra-fails.sh` to replace the `/tmp/tails/`
  cache. The eval JSON API is patchy; HTML scraping likely needed.
- **opencode + gemma + box** is now wired up but only smoke-tested on toy
  prompts. The "no stdout" issue was gemma's default 4k context being eaten
  by opencode's system prompt + tool registry; resolved via a 32k Modelfile
  alias (`gemma4:12b-32k`). Real package smoke tests pending.
- **Merge-aware `learn.sh`.** Today it destroys hand-edits on re-run (backed up
  to `.prev`); a real merge that preserves the human notes is needed before this
  is automatic.

## Local LLM provider (Ollama) notes

The harness ships pointed at `ollama-local/gemma4:12b-32k`, an alias created
via this Modelfile:

```
FROM gemma4:12b
PARAMETER num_ctx 32768
```

```sh
ollama create gemma4:12b-32k -f Modelfile
```

Out-of-the-box `gemma4:12b` defaults to a 4k context, which opencode's system
prompt + 64-skill registry blows past instantly (verified: `output: 1, reason:
length`). 32k clears that with headroom; KV cache at fp16 is ~12 GB on the
5060 Ti's 16 GB.

**Bump-up note:** if 32k feels tight in practice, **try 48k fp16 next**.
That sits just over the 5060 Ti's VRAM ceiling (~18 GB KV), so it'll need
either CPU-offload of the overflow (`OLLAMA_KV_CACHE_TYPE=q8_0` is the
cleanest knob — int8 KV brings 48k back to ~9 GB) or a model with smaller
per-token KV. Don't jump to 64k+ without also switching to int4 KV (real
quality risk).
