#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERIFY_SCRIPT="$REPO_ROOT/scripts/verify-local-release-signing.sh"
PAIR_VERIFY_SCRIPT="$REPO_ROOT/scripts/verify-local-release-pair.sh"
INSTALL_SCRIPT="$REPO_ROOT/scripts/install-local-release.sh"
TEST_ROOT=$(mktemp -d)
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT

export AGENTGRID_LOCAL_XCCONFIG="$TEST_ROOT/Local.xcconfig"
/usr/bin/printf '%s\n' \
    'AGENTGRID_CODE_SIGN_IDENTITY = Apple Development: maintainer@example.com (LABEL12345)' \
    'AGENTGRID_DEVELOPMENT_TEAM = TEAM123456' > "$AGENTGRID_LOCAL_XCCONFIG"

passed=0

expect_success() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        passed=$((passed + 1))
    else
        echo "FAIL: $description" >&2
        exit 1
    fi
}

expect_failure() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: $description unexpectedly succeeded" >&2
        exit 1
    else
        passed=$((passed + 1))
    fi
}

expect_exit() {
    local description=$1
    local expected=$2
    shift 2
    local actual
    if "$@" >/dev/null 2>&1; then
        actual=0
    else
        actual=$?
    fi
    if [[ $actual -ne $expected ]]; then
        echo "FAIL: $description exited $actual instead of $expected" >&2
        exit 1
    fi
    passed=$((passed + 1))
}

make_bundle() {
    local path=$1
    /bin/mkdir -p "$path/Contents/MacOS"
    /usr/bin/touch "$path/Contents/MacOS/AgentGrid"
}

FAKE_BIN="$TEST_ROOT/bin"
/bin/mkdir -p "$FAKE_BIN"
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if [[ " $* " == *" --verify "* ]]; then' \
    '  [[ "${FAKE_VERIFY_OK:-1}" == 1 ]]' \
    'elif [[ " $* " == *" --entitlements "* ]]; then' \
    '  /usr/bin/printf "%s\n" "${FAKE_ENTITLEMENTS:-<plist><dict></dict></plist>}"' \
    'elif [[ " $* " == *" -r- "* ]]; then' \
    '  bundle="${@: -1}"' \
    '  if [[ "$bundle" == *"PairA.app" ]]; then requirement="${FAKE_REQUIREMENT_A:-stable}"; else requirement="${FAKE_REQUIREMENT_B:-stable}"; fi' \
    '  /usr/bin/printf "Executable=%s/Contents/MacOS/AgentGrid\ndesignated => %s\n" "$bundle" "$requirement" >&2' \
    'else' \
    '  /usr/bin/printf "%s\n" "${FAKE_DETAILS:-Identifier=com.thechosenvictor.AgentGrid}" >&2' \
    'fi' > "$FAKE_BIN/codesign"
/bin/chmod +x "$FAKE_BIN/codesign"

BUNDLE="$TEST_ROOT/AgentGrid.app"
make_bundle "$BUNDLE"

VALID_DETAILS=$'Identifier=com.thechosenvictor.AgentGrid\nAuthority=Apple Development: maintainer@example.com (LABEL12345)\nTeamIdentifier=TEAM123456\nCodeDirectory v=20500 size=1 flags=0x10000(runtime)'
ADHOC_DETAILS=$'Identifier=com.thechosenvictor.AgentGrid\nSignature=adhoc\nTeamIdentifier=not set\nCodeDirectory v=20500 size=1 flags=0x10000(runtime)'
LABEL_SUFFIX_AS_TEAM_DETAILS=$'Identifier=com.thechosenvictor.AgentGrid\nAuthority=Apple Development: maintainer@example.com (LABEL12345)\nTeamIdentifier=LABEL12345\nCodeDirectory v=20500 size=1 flags=0x10000(runtime)'

expect_failure "ad-hoc/no-team bundle is rejected" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$ADHOC_DETAILS" "$VERIFY_SCRIPT" "$BUNDLE"

expect_success "stable Apple Development identity is accepted" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$VALID_DETAILS" "$VERIFY_SCRIPT" "$BUNDLE"

expect_failure "certificate label suffix is not accepted as TeamIdentifier" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$LABEL_SUFFIX_AS_TEAM_DETAILS" "$VERIFY_SCRIPT" "$BUNDLE"

expect_failure "sandbox entitlement is rejected" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$VALID_DETAILS" \
    FAKE_ENTITLEMENTS='<plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' \
    "$VERIFY_SCRIPT" "$BUNDLE"

PAIR_A="$TEST_ROOT/PairA.app"
PAIR_B="$TEST_ROOT/PairB.app"
make_bundle "$PAIR_A"
make_bundle "$PAIR_B"

expect_success "two verified builds with one designated requirement are accepted" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$VALID_DETAILS" FAKE_REQUIREMENT_A='identifier "stable"' \
    FAKE_REQUIREMENT_B='identifier "stable"' \
    "$PAIR_VERIFY_SCRIPT" "$PAIR_A" "$PAIR_B"

expect_failure "two verified builds with different designated requirements are rejected" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$VALID_DETAILS" FAKE_REQUIREMENT_A='identifier "stable"' \
    FAKE_REQUIREMENT_B='identifier "changed"' \
    "$PAIR_VERIFY_SCRIPT" "$PAIR_A" "$PAIR_B"

expect_failure "installed validation rejects a non-fixed path" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_CODESIGN_COMMAND="$FAKE_BIN/codesign" \
    FAKE_DETAILS="$VALID_DETAILS" "$VERIFY_SCRIPT" --installed "$BUNDLE"

FAKE_VERIFY="$TEST_ROOT/fake-verify.sh"
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if [[ "${FAIL_SOURCE_VERIFY:-0}" == 1 && "${1:-}" != --installed ]]; then exit 1; fi' \
    'if [[ "${FAIL_INSTALLED_VERIFY:-0}" == 1 && "${1:-}" == --installed ]]; then exit 1; fi' \
    'exit 0' > "$FAKE_VERIFY"
/bin/chmod +x "$FAKE_VERIFY"

FAKE_MV="$TEST_ROOT/fake-mv.sh"
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'source_path=${1:-}' \
    'target_path=${2:-}' \
    'if [[ "$source_path" == *.incoming && "$target_path" == *.app ]]; then exit 1; fi' \
    'if [[ "${FAIL_RESTORE:-0}" == 1 && "$source_path" == *.previous && "$target_path" == *.app ]]; then exit 1; fi' \
    'exec /bin/mv "$@"' > "$FAKE_MV"
/bin/chmod +x "$FAKE_MV"

FAKE_LSREGISTER="$TEST_ROOT/fake-lsregister.sh"
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'count_file=${LSREGISTER_COUNT_FILE:?}' \
    'count=0' \
    'if [[ -e "$count_file" ]]; then count=$(<"$count_file"); fi' \
    'count=$((count + 1))' \
    '/usr/bin/printf "%s" "$count" > "$count_file"' \
    'if (( count <= ${FAIL_LSREGISTER_CALLS:-0} )); then exit 1; fi' \
    'exit 0' > "$FAKE_LSREGISTER"
/bin/chmod +x "$FAKE_LSREGISTER"

SOURCE="$TEST_ROOT/source/AgentGrid.app"
DESTINATION="$TEST_ROOT/install/AgentGrid.app"
make_bundle "$SOURCE"
make_bundle "$DESTINATION"
/usr/bin/touch "$DESTINATION/previous-version"

expect_failure "unverified source never replaces the installed bundle" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$DESTINATION" FAIL_SOURCE_VERIFY=1 \
    "$INSTALL_SCRIPT" "$SOURCE"
[[ -e "$DESTINATION/previous-version" ]] || { echo "FAIL: current bundle was moved" >&2; exit 1; }
passed=$((passed + 1))

ORPHAN_DESTINATION="$TEST_ROOT/orphan-install/AgentGrid.app"
make_bundle "$ORPHAN_DESTINATION.previous"
/usr/bin/touch "$ORPHAN_DESTINATION.previous/recovery-only"
expect_failure "an orphaned previous bundle is preserved for manual recovery" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$ORPHAN_DESTINATION" AGENTGRID_LSREGISTER_COMMAND=/usr/bin/true \
    "$INSTALL_SCRIPT" "$SOURCE"
[[ -e "$ORPHAN_DESTINATION.previous/recovery-only" ]] || { echo "FAIL: orphaned recovery bundle was removed" >&2; exit 1; }
passed=$((passed + 1))

/usr/bin/touch "$SOURCE/version-2"
expect_success "verified replacement leaves a recoverable previous bundle" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$DESTINATION" AGENTGRID_LSREGISTER_COMMAND=/usr/bin/true \
    "$INSTALL_SCRIPT" "$SOURCE"
[[ -e "$DESTINATION.previous/previous-version" ]] || { echo "FAIL: previous bundle missing" >&2; exit 1; }
passed=$((passed + 1))

SOURCE_V3="$TEST_ROOT/source-v3/AgentGrid.app"
make_bundle "$SOURCE_V3"
/usr/bin/touch "$SOURCE_V3/version-3"

expect_success "a second verified update replaces the one-generation recovery bundle" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$DESTINATION" AGENTGRID_LSREGISTER_COMMAND=/usr/bin/true \
    "$INSTALL_SCRIPT" "$SOURCE_V3"
[[ -e "$DESTINATION/version-3" ]] || { echo "FAIL: second update was not installed" >&2; exit 1; }
[[ -e "$DESTINATION.previous/version-2" ]] || { echo "FAIL: previous bundle is not version 2" >&2; exit 1; }
[[ ! -e "$DESTINATION.previous/previous-version" ]] || { echo "FAIL: version 1 recovery bundle was retained" >&2; exit 1; }
passed=$((passed + 3))

CUTOVER_SOURCE="$TEST_ROOT/cutover-source/AgentGrid.app"
CUTOVER_DESTINATION="$TEST_ROOT/cutover-install/AgentGrid.app"
make_bundle "$CUTOVER_SOURCE"
make_bundle "$CUTOVER_DESTINATION"
/usr/bin/touch "$CUTOVER_SOURCE/candidate-version"
/usr/bin/touch "$CUTOVER_DESTINATION/original-version"

expect_failure "a failed incoming cutover restores the canonical bundle" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_MV_COMMAND="$FAKE_MV" AGENTGRID_INSTALL_DESTINATION="$CUTOVER_DESTINATION" \
    AGENTGRID_LSREGISTER_COMMAND=/usr/bin/true "$INSTALL_SCRIPT" "$CUTOVER_SOURCE"
[[ -e "$CUTOVER_DESTINATION/original-version" ]] || { echo "FAIL: cutover failure did not restore current bundle" >&2; exit 1; }
[[ -e "$CUTOVER_DESTINATION.incoming/candidate-version" ]] || { echo "FAIL: failed incoming bundle was not preserved" >&2; exit 1; }
[[ ! -e "$CUTOVER_DESTINATION.previous" ]] || { echo "FAIL: restored previous bundle remained duplicated" >&2; exit 1; }
passed=$((passed + 3))

RESTORE_SOURCE="$TEST_ROOT/restore-source/AgentGrid.app"
RESTORE_DESTINATION="$TEST_ROOT/restore-install/AgentGrid.app"
make_bundle "$RESTORE_SOURCE"
make_bundle "$RESTORE_DESTINATION"
/usr/bin/touch "$RESTORE_SOURCE/candidate-version"
/usr/bin/touch "$RESTORE_DESTINATION/original-version"

expect_failure "a failed cutover and failed restore preserve both recovery bundles" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_MV_COMMAND="$FAKE_MV" AGENTGRID_INSTALL_DESTINATION="$RESTORE_DESTINATION" \
    AGENTGRID_LSREGISTER_COMMAND=/usr/bin/true FAIL_RESTORE=1 "$INSTALL_SCRIPT" "$RESTORE_SOURCE"
[[ ! -e "$RESTORE_DESTINATION" ]] || { echo "FAIL: failed restore left an unverified canonical bundle" >&2; exit 1; }
[[ -e "$RESTORE_DESTINATION.previous/original-version" ]] || { echo "FAIL: failed restore lost the previous bundle" >&2; exit 1; }
[[ -e "$RESTORE_DESTINATION.incoming/candidate-version" ]] || { echo "FAIL: failed restore lost the incoming bundle" >&2; exit 1; }
passed=$((passed + 3))

REGISTER_SOURCE="$TEST_ROOT/register-source/AgentGrid.app"
REGISTER_DESTINATION="$TEST_ROOT/register-install/AgentGrid.app"
REGISTER_COUNT="$TEST_ROOT/register-count"
make_bundle "$REGISTER_SOURCE"
make_bundle "$REGISTER_DESTINATION"
/usr/bin/touch "$REGISTER_SOURCE/candidate-version"
/usr/bin/touch "$REGISTER_DESTINATION/original-version"

expect_exit "a failed replacement registration re-registers the restored bundle" 67 \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$REGISTER_DESTINATION" \
    AGENTGRID_LSREGISTER_COMMAND="$FAKE_LSREGISTER" LSREGISTER_COUNT_FILE="$REGISTER_COUNT" \
    FAIL_LSREGISTER_CALLS=1 "$INSTALL_SCRIPT" "$REGISTER_SOURCE"
[[ "$(<"$REGISTER_COUNT")" == 2 ]] || { echo "FAIL: restored bundle was not re-registered" >&2; exit 1; }
[[ -e "$REGISTER_DESTINATION/original-version" ]] || { echo "FAIL: registration rollback did not restore original" >&2; exit 1; }
[[ -e "$REGISTER_DESTINATION.failed/candidate-version" ]] || { echo "FAIL: rejected registered candidate was not preserved" >&2; exit 1; }
passed=$((passed + 3))

REGISTER_FAIL_SOURCE="$TEST_ROOT/register-fail-source/AgentGrid.app"
REGISTER_FAIL_DESTINATION="$TEST_ROOT/register-fail-install/AgentGrid.app"
REGISTER_FAIL_COUNT="$TEST_ROOT/register-fail-count"
make_bundle "$REGISTER_FAIL_SOURCE"
make_bundle "$REGISTER_FAIL_DESTINATION"
/usr/bin/touch "$REGISTER_FAIL_SOURCE/candidate-version"
/usr/bin/touch "$REGISTER_FAIL_DESTINATION/original-version"

expect_exit "failed replacement and recovery registration exits distinctly" 70 \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$REGISTER_FAIL_DESTINATION" \
    AGENTGRID_LSREGISTER_COMMAND="$FAKE_LSREGISTER" LSREGISTER_COUNT_FILE="$REGISTER_FAIL_COUNT" \
    FAIL_LSREGISTER_CALLS=2 "$INSTALL_SCRIPT" "$REGISTER_FAIL_SOURCE"
[[ "$(<"$REGISTER_FAIL_COUNT")" == 2 ]] || { echo "FAIL: recovery registration was not attempted exactly once" >&2; exit 1; }
[[ -e "$REGISTER_FAIL_DESTINATION/original-version" ]] || { echo "FAIL: double registration failure lost original" >&2; exit 1; }
[[ -e "$REGISTER_FAIL_DESTINATION.failed/candidate-version" ]] || { echo "FAIL: double registration failure lost candidate evidence" >&2; exit 1; }
passed=$((passed + 3))

ROLLBACK_SOURCE="$TEST_ROOT/rollback-source/AgentGrid.app"
ROLLBACK_DESTINATION="$TEST_ROOT/rollback-install/AgentGrid.app"
make_bundle "$ROLLBACK_SOURCE"
make_bundle "$ROLLBACK_DESTINATION"
/usr/bin/touch "$ROLLBACK_DESTINATION/original-version"

expect_failure "failed destination postflight rolls back the prior bundle" \
    env AGENTGRID_SCRIPT_TEST_MODE=1 AGENTGRID_VERIFY_COMMAND="$FAKE_VERIFY" \
    AGENTGRID_INSTALL_DESTINATION="$ROLLBACK_DESTINATION" FAIL_INSTALLED_VERIFY=1 \
    "$INSTALL_SCRIPT" "$ROLLBACK_SOURCE"
[[ -e "$ROLLBACK_DESTINATION/original-version" ]] || { echo "FAIL: rollback did not restore prior bundle" >&2; exit 1; }
[[ -d "$ROLLBACK_DESTINATION.failed" ]] || { echo "FAIL: failed replacement was not preserved" >&2; exit 1; }
passed=$((passed + 2))

echo "Local release script tests passed: $passed"
