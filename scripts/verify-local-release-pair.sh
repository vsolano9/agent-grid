#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && /bin/pwd -P)
VERIFY_SCRIPT="$SCRIPT_DIRECTORY/verify-local-release-signing.sh"
CODESIGN_COMMAND="/usr/bin/codesign"

if [[ "${AGENTGRID_SCRIPT_TEST_MODE:-0}" == 1 ]]; then
    CODESIGN_COMMAND="${AGENTGRID_CODESIGN_COMMAND:-$CODESIGN_COMMAND}"
fi

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/first/AgentGrid.app /path/to/second/AgentGrid.app" >&2
    exit 64
fi

first_bundle=$1
second_bundle=$2

"$VERIFY_SCRIPT" "$first_bundle"
"$VERIFY_SCRIPT" "$second_bundle"

designated_requirement() {
    local bundle=$1
    local output
    local requirement
    output=$("$CODESIGN_COMMAND" -d -r- "$bundle" 2>&1)
    requirement=$(/usr/bin/sed -n 's/^designated => //p' <<< "$output")
    if [[ -z "$requirement" || "$requirement" == *$'\n'* ]]; then
        echo "Expected exactly one designated requirement for $bundle" >&2
        exit 72
    fi
    /usr/bin/printf '%s' "$requirement"
}

first_requirement=$(designated_requirement "$first_bundle")
second_requirement=$(designated_requirement "$second_bundle")
if [[ "$first_requirement" != "$second_requirement" ]]; then
    echo "AgentGrid designated requirements differ across builds" >&2
    exit 73
fi

echo "Verified matching AgentGrid designated requirement across two builds"
