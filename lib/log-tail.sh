#!/usr/bin/env bash
# log-tail.sh — fetch + brotli-decompress the tail of a Hydra build log.
#
# Hydra serves raw logs brotli-compressed at /build/N/nixlog/1/raw. The JSON
# API is patchy and we only need the LAST ~60 lines anyway (signature lives
# there). This is the canonical fetcher; both classify.sh and agent-ask.sh
# pipe its output.
#
# Usage:
#   ./lib/log-tail.sh <build_id> [lines=60]

set -euo pipefail

BUILD_ID="${1:?need a Hydra build ID}"
LINES="${2:-60}"

curl -sL "https://hydra.nixos.org/build/${BUILD_ID}/nixlog/1/raw" \
  | nix shell nixpkgs#brotli -c brotli -d 2>/dev/null \
  | tail -n "$LINES"
