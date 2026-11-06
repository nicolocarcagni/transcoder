#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TRANSCODER="${SCRIPT_DIR}/transcode.sh"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    TEST_COUNT=$((TEST_COUNT + 1))
    if [ "${expected}" = "${actual}" ]; then
        printf "  \033[32m✔\033[0m %s\n" "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "  \033[31m✖\033[0m %s\n" "${label}"
        printf "      Expected: [%s]\n" "${expected}"
        printf "      Actual:   [%s]\n" "${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_success() {
    local label="$1"
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    local output
    if output=$("$@" 2>&1); then
        printf "  \033[32m✔\033[0m %s\n" "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "  \033[31m✖\033[0m %s\n" "${label}"
        printf "      Command failed: %s\n" "$*"
        printf "      Output: %s\n" "${output}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "Running Path Handling Tests..."
echo "=============================="

# Source transcoder functions
# shellcheck source=/dev/null
source "${TRANSCODER}"

# Setup self-contained ephemeral test fixtures
TMP_FIXTURE_DIR=$(mktemp -d "/tmp/transcoder_test_fixture.XXXXXX")
cleanup_fixtures() {
    rm -rf "${TMP_FIXTURE_DIR}"
}
trap cleanup_fixtures EXIT

TEST_DIR="${TMP_FIXTURE_DIR}/in put (test)"
mkdir -p "${TEST_DIR}"

# Create a small valid synthetic 1-second video clip for dry-run validation
ffmpeg -v error -f lavfi -i testsrc=duration=1:size=320x240:rate=30 -c:v libx264 -pix_fmt yuv420p "${TEST_DIR}/sample clip.mp4"

echo "1. Unit Tests for clean_input_path:"
assert_eq "Single-quoted folder" "/path/to/folder" "$(clean_input_path "'/path/to/folder'")"
assert_eq "Single-quoted folder with trailing slash" "/path/to/folder" "$(clean_input_path "'/path/to/folder/'")"
assert_eq "Single-quoted folder with trailing space" "/path/to/folder" "$(clean_input_path "'/path/to/folder' ")"
assert_eq "Single-quoted folder with surrounding whitespace" "/path/to/folder" "$(clean_input_path "  '/path/to/folder'  ")"
assert_eq "Single-quoted folder with spaces" "/path/to/my folder" "$(clean_input_path "'/path/to/my folder'")"
assert_eq "Double-quoted folder" "/path/to/folder" "$(clean_input_path "\"/path/to/folder\"")"
assert_eq "Double-quoted folder with trailing slash" "/path/to/folder" "$(clean_input_path "\"/path/to/folder/\"")"
assert_eq "Nested quoted folder" "/path/to/folder" "$(clean_input_path "\"'/path/to/folder'\"")"
assert_eq "Tilde expansion with quotes" "${HOME:-~}/Videos" "$(clean_input_path "'~/Videos'")"
assert_eq "Tilde only with quotes" "${HOME:-~}" "$(clean_input_path "'~'")"
assert_eq "file:// URI prefix" "/path/to/folder" "$(clean_input_path "file:///path/to/folder")"
assert_eq "file://localhost URI prefix" "/path/to/folder" "$(clean_input_path "file://localhost/path/to/folder")"
assert_eq "Root path preserved" "/" "$(clean_input_path "'/'")"
assert_eq "Empty input" "" "$(clean_input_path "")"
assert_eq "Whitespace-only input" "" "$(clean_input_path "   ")"

# Test unescaping of backslash-escaped path for existing target
escaped_dir="${TEST_DIR// /\\ }"
assert_eq "Backslash-escaped existing folder" "${TEST_DIR}" "$(clean_input_path "${escaped_dir}")"

# Test URL percent-encoding for existing target
encoded_dir="file://${TEST_DIR// /%20}"
assert_eq "URL percent-encoded existing folder" "${TEST_DIR}" "$(clean_input_path "${encoded_dir}")"

echo ""
echo "2. CLI Arguments with Quotes in Dry-Run:"
assert_success "Positional quoted folder" "${TRANSCODER}" "'${TEST_DIR}'" -d
assert_success "Positional quoted folder with trailing slash" "${TRANSCODER}" "'${TEST_DIR}/'" -d
assert_success "-i flag with quoted folder" "${TRANSCODER}" -i "'${TEST_DIR}'" -d
assert_success "Positional quoted file" "${TRANSCODER}" "'${TEST_DIR}/sample clip.mp4'" -d

echo ""
echo "3. Interactive Mode Prompt Simulation:"
# Verify that clean_input_path handles simulated drag-and-drop input
dragged_input="'${TEST_DIR}/' "
cleaned=$(clean_input_path "${dragged_input}")
TEST_COUNT=$((TEST_COUNT + 1))
if [ -d "${cleaned}" ]; then
    printf "  \033[32m✔\033[0m Dragged input '%s' resolved to valid directory: %s\n" "${dragged_input}" "${cleaned}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf "  \033[31m✖\033[0m Cleaned path does not exist as directory: %s\n" "${cleaned}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo ""
echo "=============================="
echo "Tests completed: ${TEST_COUNT}"
echo "Passed: ${PASS_COUNT}"
echo "Failed: ${FAIL_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
exit 0
