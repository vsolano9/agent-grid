#!/bin/bash
set -euo pipefail

# shellcheck source=local-release-config.sh
source "$(cd "$(dirname "$0")" && /bin/pwd -P)/local-release-config.sh"

EXPECTED_IDENTIFIER="com.thechosenvictor.AgentGrid"
EXPECTED_TEAM="$LOCAL_RELEASE_TEAM"
EXPECTED_AUTHORITY="$LOCAL_RELEASE_IDENTITY"
EXPECTED_INSTALL_PATH="$LOCAL_RELEASE_INSTALL_PATH"
CODESIGN_COMMAND="/usr/bin/codesign"

if [[ "${AGENTGRID_SCRIPT_TEST_MODE:-0}" == 1 ]]; then
    CODESIGN_COMMAND="${AGENTGRID_CODESIGN_COMMAND:-$CODESIGN_COMMAND}"
fi

require_installed_path=0
if [[ "${1:-}" == --installed ]]; then
    require_installed_path=1
    shift
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--installed] /path/to/AgentGrid.app" >&2
    exit 64
fi

require_local_release_identity

bundle=$1
if [[ ! -d "$bundle/Contents/MacOS" ]]; then
    echo "Not an application bundle: $bundle" >&2
    exit 65
fi

bundle_parent=$(/usr/bin/dirname "$bundle")
bundle_name=$(/usr/bin/basename "$bundle")
canonical_bundle="$(cd "$bundle_parent" && /bin/pwd -P)/$bundle_name"
if [[ $require_installed_path -eq 1 && "$canonical_bundle" != "$EXPECTED_INSTALL_PATH" ]]; then
    echo "Installed AgentGrid must be exactly $EXPECTED_INSTALL_PATH" >&2
    exit 66
fi

"$CODESIGN_COMMAND" --verify --deep --strict "$bundle"
details=$("$CODESIGN_COMMAND" -d --verbose=4 "$bundle" 2>&1)

if ! /usr/bin/grep -Fqx "Identifier=$EXPECTED_IDENTIFIER" <<< "$details"; then
    echo "Unexpected or missing bundle identifier" >&2
    exit 67
fi
if ! /usr/bin/grep -Fqx "Authority=$EXPECTED_AUTHORITY" <<< "$details"; then
    echo "The stable Apple Development signing authority is required" >&2
    exit 68
fi
if ! /usr/bin/grep -Fqx "TeamIdentifier=$EXPECTED_TEAM" <<< "$details"; then
    echo "Signing team must be $EXPECTED_TEAM" >&2
    exit 69
fi
if ! /usr/bin/grep -Eq 'flags=.*\(runtime\)' <<< "$details"; then
    echo "Hardened runtime flag is missing" >&2
    exit 70
fi

entitlements=$("$CODESIGN_COMMAND" -d --entitlements :- "$bundle" 2>&1)
entitlements_single_line=$(/usr/bin/tr '\n' ' ' <<< "$entitlements")
for forbidden_key in \
    com.apple.security.app-sandbox \
    com.apple.security.device. \
    com.apple.security.personal-information. \
    com.apple.security.screen-capture \
    com.apple.security.automation.apple-events
do
    if /usr/bin/grep -Fq "<key>$forbidden_key" <<< "$entitlements_single_line"; then
        echo "Forbidden unused entitlement: $forbidden_key" >&2
        exit 71
    fi
done

echo "Verified stable local AgentGrid signature: $canonical_bundle"
