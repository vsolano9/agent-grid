#!/bin/bash

set -euo pipefail

fixture_path="${1:?usage: TerminalViewMemoryStressTests.sh /path/to/TerminalViewMemoryStressFixture}"

run_case() {
  "$fixture_path" \
    --panes "$1" \
    --cycles "$2" \
    --process-rss-limit-mb "$3" \
    --descendant-rss-limit-mb "$4" \
    --timeout-seconds 55
}

run_case 1 3 320 128
run_case 4 3 640 256
run_case 12 2 1200 512
run_case 24 2 1800 768
