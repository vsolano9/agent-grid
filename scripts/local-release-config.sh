#!/bin/bash
# Sourced by the local release scripts. Reads the maintainer's signing values from the
# untracked Config/Local.xcconfig (see Config/Local.xcconfig.example), so no identity is
# committed. Test mode may point AGENTGRID_LOCAL_XCCONFIG at a fixture.

LOCAL_RELEASE_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)
LOCAL_XCCONFIG="$LOCAL_RELEASE_REPO_ROOT/Config/Local.xcconfig"

if [[ "${AGENTGRID_SCRIPT_TEST_MODE:-0}" == 1 ]]; then
    LOCAL_XCCONFIG="${AGENTGRID_LOCAL_XCCONFIG:-$LOCAL_XCCONFIG}"
fi

# Prints the last value assigned to $1 in the local xcconfig, without surrounding spaces.
local_release_setting() {
    local key=$1
    [[ -f "$LOCAL_XCCONFIG" ]] || return 0
    /usr/bin/sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$LOCAL_XCCONFIG" \
        | /usr/bin/tail -n 1 \
        | /usr/bin/sed 's/[[:space:]]*$//'
}

LOCAL_RELEASE_IDENTITY=$(local_release_setting AGENTGRID_CODE_SIGN_IDENTITY)
LOCAL_RELEASE_TEAM=$(local_release_setting AGENTGRID_DEVELOPMENT_TEAM)
LOCAL_RELEASE_INSTALL_PATH=$(local_release_setting AGENTGRID_INSTALL_PATH)
LOCAL_RELEASE_INSTALL_PATH=${LOCAL_RELEASE_INSTALL_PATH:-$HOME/Applications/AgentGrid.app}

# Exits unless a stable (non-ad-hoc) identity and team are configured.
require_local_release_identity() {
    if [[ -z "$LOCAL_RELEASE_IDENTITY" || "$LOCAL_RELEASE_IDENTITY" == - || -z "$LOCAL_RELEASE_TEAM" ]]; then
        echo "Set AGENTGRID_CODE_SIGN_IDENTITY and AGENTGRID_DEVELOPMENT_TEAM in $LOCAL_XCCONFIG (see Config/Local.xcconfig.example)" >&2
        exit 74
    fi
}
