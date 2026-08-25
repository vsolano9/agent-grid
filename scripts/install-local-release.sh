#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
DESTINATION="/Users/victor/Applications/AgentGrid.app"
VERIFY_COMMAND="$SCRIPT_DIRECTORY/verify-local-release-signing.sh"
LSREGISTER_COMMAND="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
MV_COMMAND="/bin/mv"

if [[ "${AGENTGRID_SCRIPT_TEST_MODE:-0}" == 1 ]]; then
    DESTINATION="${AGENTGRID_INSTALL_DESTINATION:-$DESTINATION}"
    VERIFY_COMMAND="${AGENTGRID_VERIFY_COMMAND:-$VERIFY_COMMAND}"
    LSREGISTER_COMMAND="${AGENTGRID_LSREGISTER_COMMAND:-$LSREGISTER_COMMAND}"
    MV_COMMAND="${AGENTGRID_MV_COMMAND:-$MV_COMMAND}"
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /explicit/path/to/AgentGrid.app" >&2
    exit 64
fi

source_bundle=$1
incoming="$DESTINATION.incoming"
previous="$DESTINATION.previous"
failed="$DESTINATION.failed"
cleanup_incoming_on_exit=1

cleanup_incoming() {
    if [[ $cleanup_incoming_on_exit -eq 1 && -e "$incoming" ]]; then
        /bin/rm -rf -- "$incoming"
    fi
}
trap cleanup_incoming EXIT

rollback_after_postflight_failure() {
    if [[ -e "$DESTINATION" ]]; then
        "$MV_COMMAND" "$DESTINATION" "$failed"
    fi
    if [[ -e "$previous" ]]; then
        "$MV_COMMAND" "$previous" "$DESTINATION"
    fi
}

"$VERIFY_COMMAND" "$source_bundle"

if [[ -e "$incoming" || -e "$failed" ]]; then
    echo "Refusing to overwrite an existing recovery sibling for $DESTINATION" >&2
    exit 65
fi
if [[ -e "$previous" && ! -e "$DESTINATION" ]]; then
    echo "Refusing to replace the only recoverable bundle at $previous" >&2
    exit 65
fi

/bin/mkdir -p "$(/usr/bin/dirname "$DESTINATION")"
/usr/bin/ditto "$source_bundle" "$incoming"
"$VERIFY_COMMAND" "$incoming"

if [[ -e "$DESTINATION" ]]; then
    if [[ -e "$previous" ]]; then
        /bin/rm -rf -- "$previous"
    fi
    "$MV_COMMAND" "$DESTINATION" "$previous"
fi
if ! "$MV_COMMAND" "$incoming" "$DESTINATION"; then
    cleanup_incoming_on_exit=0
    if [[ -e "$previous" ]] && "$MV_COMMAND" "$previous" "$DESTINATION"; then
        echo "Install cutover failed; the previous bundle was restored and the incoming bundle was preserved" >&2
        exit 68
    fi
    echo "Install cutover and rollback failed; recovery bundles were preserved" >&2
    exit 69
fi

if ! "$VERIFY_COMMAND" --installed "$DESTINATION"; then
    rollback_after_postflight_failure
    echo "Installed signature verification failed; the previous bundle was restored" >&2
    exit 66
fi

if ! "$LSREGISTER_COMMAND" -f -R -trusted "$DESTINATION"; then
    rollback_after_postflight_failure
    if [[ -e "$DESTINATION" ]] && "$LSREGISTER_COMMAND" -f -R -trusted "$DESTINATION"; then
        echo "LaunchServices registration failed; the previous bundle was restored and re-registered" >&2
        exit 67
    fi
    echo "LaunchServices registration and recovery registration failed; recovery bundles were preserved" >&2
    exit 70
fi

echo "Installed verified AgentGrid at $DESTINATION"
if [[ -e "$previous" ]]; then
    echo "Recoverable previous bundle retained at $previous"
fi
