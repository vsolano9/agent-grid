#!/bin/bash

set -euo pipefail

fixture_path="${1:?usage: TerminalMemoryStressTests.sh /path/to/TerminalMemoryStressFixture}"

run_case() {
  local panes="$1"
  local cycles="$2"
  local image_mb="$3"
  local cache_mb="$4"
  local rss_limit_mb="$5"

  "$fixture_path" \
    --panes "$panes" \
    --cycles "$cycles" \
    --image-mb-per-pane "$image_mb" \
    --cache-mb-per-pane "$cache_mb" \
    --rss-limit-mb "$rss_limit_mb" \
    --timeout-seconds 45
}

run_case 1 2 40 32 256
run_case 4 4 40 32 512
run_case 12 1 36 32 900

"$fixture_path" \
  --adversarial-encoded-mb 128 \
  --transfer-limit-mb 8 \
  --rss-limit-mb 192 \
  --timeout-seconds 45
