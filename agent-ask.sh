#!/usr/bin/env bash
# agent-ask.sh — fallback for log tails that classify.sh couldn't match.
# Hands the log to local gemma4:12b via Ollama and asks for a one-paragraph
# guess at the cause + fix shape. Outputs JSON.
#
# Phase 0: the model's suggestion is NEVER applied. It's just printed.
# A human looks at it and decides whether to (a) write a new playbook
# entry, (b) open the PR by hand, or (c) ignore.
#
# Usage:
#   ./agent-ask.sh < some-tail.log
#   ./agent-ask.sh --model qwen3.5:9b < tail.log   # any installed model

set -euo pipefail

MODEL="gemma4:12b"
ENDPOINT="http://localhost:11434/api/generate"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "agent-ask: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

LOG="$(cat)"

SYSTEM_PROMPT='You are a nixpkgs build-failure triager. Given the tail of a failed nix-build log, identify the likely cause and propose a one-paragraph fix.

Constraints:
- If you do not see a clear failure signature, say so explicitly. Do not invent fixes.
- Prefer well-known fix patterns: hash mismatch (refresh hash), missing source on a conditional (widen the conditional), unsupported linker flag on darwin (drop or guard), missing library (add to buildInputs).
- Output PLAIN TEXT, ~3-5 lines. No markdown, no preamble, no commentary about your reasoning.'

PROMPT="$SYSTEM_PROMPT

---
BUILD LOG TAIL:
$LOG
---

YOUR ANALYSIS:"

# Stream off; just return the final response.
PAYLOAD="$(nix shell nixpkgs#jq -c jq -n \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  '{model: $model, prompt: $prompt, stream: false}')"

RAW="$(curl -sS -X POST "$ENDPOINT" -d "$PAYLOAD")"
RESPONSE="$(printf '%s' "$RAW" | nix shell nixpkgs#jq -c jq -r '.response // .error // "no response"')"

nix shell nixpkgs#jq -c jq -n \
  --arg model "$MODEL" \
  --arg response "$RESPONSE" \
  '{name: "gemma_suggested", model: $model, response: $response}'
