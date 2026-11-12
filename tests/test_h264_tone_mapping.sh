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

assert_failure() {
    local label="$1"
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    local output
    if output=$("$@" 2>&1); then
        printf "  \033[31m✖\033[0m %s (unexpected success)\n" "${label}"
        printf "      Command: %s\n" "$*"
        printf "      Output: %s\n" "${output}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        printf "  \033[32m✔\033[0m %s\n" "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

echo "Running H.264 All-Intra & Tone-Mapping Test Suite..."
echo "==================================================="

TMP_TEST_DIR=$(mktemp -d "/tmp/transcoder_h264_test.XXXXXX")
trap 'rm -rf "${TMP_TEST_DIR}"' EXIT

# Create synthetic test media in isolated scratch directory
MEDIA_DIR="${TMP_TEST_DIR}/media"
OUTPUT_DIR="${TMP_TEST_DIR}/output"
mkdir -p "${MEDIA_DIR}" "${OUTPUT_DIR}"

echo ""
echo "1. Pre-flight Check on FFmpeg Dependencies & Capabilities:"
assert_success "check_dependencies succeeds on supported host" bash -c "source '${TRANSCODER}' && check_dependencies"

# Test simulated failure when an encoder/filter is missing
assert_failure "check_dependencies fails if libx264 is missing" bash -c "
    ffmpeg() {
        if [ \"\$1\" = \"-encoders\" ]; then
            echo ' V..... libopenh264'
        else
            command ffmpeg \"\$@\"
        fi
    }
    export -f ffmpeg
    source '${TRANSCODER}' && check_dependencies
"

assert_failure "check_dependencies fails if zscale is missing" bash -c "
    ffmpeg() {
        if [ \"\$1\" = \"-filters\" ]; then
            echo ' .. tonemap'
        else
            command ffmpeg \"\$@\"
        fi
    }
    export -f ffmpeg
    source '${TRANSCODER}' && check_dependencies
"

echo ""
echo "2. CLI Argument Parsing and Validation:"
# Default format is h264
assert_eq "Default format is h264" "h264" "$(bash -c "source '${TRANSCODER}' && echo \"\${FORMAT}\"")"
assert_eq "Default tonemap algorithm is hable" "hable" "$(bash -c "source '${TRANSCODER}' && echo \"\${TONEMAP_ALGO}\"")"
assert_eq "Default NPL is 100" "100" "$(bash -c "source '${TRANSCODER}' && echo \"\${NPL_VAL}\"")"

# Valid options
assert_eq "Parse --tonemap mobius" "mobius" "$(bash -c "source '${TRANSCODER}' && parse_arguments --tonemap mobius && echo \"\${TONEMAP_ALGO}\"")"
assert_eq "Parse --tonemap=reinhard" "reinhard" "$(bash -c "source '${TRANSCODER}' && parse_arguments --tonemap=reinhard && echo \"\${TONEMAP_ALGO}\"")"
assert_eq "Parse --npl 120" "120" "$(bash -c "source '${TRANSCODER}' && parse_arguments --npl 120 && echo \"\${NPL_VAL}\"")"
assert_eq "Parse --npl=150.5" "150.5" "$(bash -c "source '${TRANSCODER}' && parse_arguments --npl=150.5 && echo \"\${NPL_VAL}\"")"

# Invalid options
assert_failure "Reject invalid tonemap algorithm" bash -c "source '${TRANSCODER}' && parse_arguments --tonemap invalid"
assert_failure "Reject invalid npl value" bash -c "source '${TRANSCODER}' && parse_arguments --npl -50"
assert_failure "Reject zero npl value" bash -c "source '${TRANSCODER}' && parse_arguments --npl 0"
assert_failure "Reject non-numeric npl value" bash -c "source '${TRANSCODER}' && parse_arguments --npl abc"

echo ""
echo "3. Creating Synthetic Test Clips:"
# Clip A: iPhone-like HDR HLG (HEVC 10-bit arib-std-b67) with audio
ffmpeg -v error -y \
    -f lavfi -i "testsrc=duration=1:size=320x240:rate=30" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -pix_fmt yuv420p10le \
    -bsf:v "h264_metadata=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9" \
    -c:a aac \
    "${MEDIA_DIR}/hdr_hlg_clip.mov"

# Clip B: Standard SDR (H.264 8-bit Rec.709) with audio
ffmpeg -v error -y \
    -f lavfi -i "testsrc=duration=1:size=320x240:rate=30" \
    -f lavfi -i "sine=frequency=880:duration=1" \
    -c:v libx264 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac \
    "${MEDIA_DIR}/sdr_clip.mp4"

# Clip C: Empty file (0 bytes) to test warning tolerance
touch "${MEDIA_DIR}/empty_clip.mp4"

# Clip D: Corrupted / non-video file to test warning tolerance
echo "not a video file" > "${MEDIA_DIR}/corrupt_clip.mov"

printf "  ✔ Synthetic test clips generated.\n"

echo ""
echo "4. Batch Transcoding Run & Output Inspection:"
assert_success "Batch transcode execution with H.264 All-Intra" \
    "${TRANSCODER}" "${MEDIA_DIR}" -o "${OUTPUT_DIR}" --tonemap hable --npl 100

TARGET_HDR="${OUTPUT_DIR}/hdr_hlg_clip_transcoded.mov"
TARGET_SDR="${OUTPUT_DIR}/sdr_clip_transcoded.mov"

assert_success "HDR transcoded file exists" test -s "${TARGET_HDR}"
assert_success "SDR transcoded file exists" test -s "${TARGET_SDR}"

# Verify HDR Output Specs
probe_hdr_v=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,pix_fmt,color_transfer,color_space,color_primaries,color_range,has_b_frames \
    -of default=noprint_wrappers=1 "${TARGET_HDR}")

assert_eq "HDR output codec is h264" "codec_name=h264" "$(grep '^codec_name=' <<< "${probe_hdr_v}")"
assert_eq "HDR output pixel format is yuv420p" "pix_fmt=yuv420p" "$(grep '^pix_fmt=' <<< "${probe_hdr_v}")"
assert_eq "HDR output color range is tv" "color_range=tv" "$(grep '^color_range=' <<< "${probe_hdr_v}")"
assert_eq "HDR output color_primaries is bt709" "color_primaries=bt709" "$(grep '^color_primaries=' <<< "${probe_hdr_v}")"
assert_eq "HDR output color_transfer is bt709" "color_transfer=bt709" "$(grep '^color_transfer=' <<< "${probe_hdr_v}")"
assert_eq "HDR output color_space is bt709" "color_space=bt709" "$(grep '^color_space=' <<< "${probe_hdr_v}")"
assert_eq "HDR output has zero B-frames" "has_b_frames=0" "$(grep '^has_b_frames=' <<< "${probe_hdr_v}")"

# Verify All-Intra (every sampled frame is I-frame)
hdr_frames=$(ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -read_intervals "%+#5" -of csv=p=0 "${TARGET_HDR}" | tr -d ',\r\n ')
assert_eq "HDR output is All-Intra (all I frames)" "IIIII" "${hdr_frames}"

# Verify uncompressed PCM audio
probe_hdr_a=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "${TARGET_HDR}")
assert_eq "HDR output audio is pcm_s16le" "codec_name=pcm_s16le" "$(grep '^codec_name=' <<< "${probe_hdr_a}")"

# Verify SDR Output Specs
probe_sdr_v=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,pix_fmt,color_transfer,color_space,color_primaries,color_range,has_b_frames \
    -of default=noprint_wrappers=1 "${TARGET_SDR}")
assert_eq "SDR output codec is h264" "codec_name=h264" "$(grep '^codec_name=' <<< "${probe_sdr_v}")"
assert_eq "SDR output pixel format is yuv420p" "pix_fmt=yuv420p" "$(grep '^pix_fmt=' <<< "${probe_sdr_v}")"
assert_eq "SDR output color_primaries is bt709" "color_primaries=bt709" "$(grep '^color_primaries=' <<< "${probe_sdr_v}")"
assert_eq "SDR output color_transfer is bt709" "color_transfer=bt709" "$(grep '^color_transfer=' <<< "${probe_sdr_v}")"

sdr_frames=$(ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -read_intervals "%+#5" -of csv=p=0 "${TARGET_SDR}" | tr -d ',\r\n ')
assert_eq "SDR output is All-Intra (all I frames)" "IIIII" "${sdr_frames}"

echo ""
echo "5. Skip Logic & Anti-Double Transcoding Check:"
# Running on the OUTPUT_DIR where all files are already transcoded All-Intra
assert_success "Skip check succeeds and skips already transcoded files" "${TRANSCODER}" "${OUTPUT_DIR}" -d

echo ""
echo "==================================================="
echo "H.264 & Tone-Mapping Tests completed: ${TEST_COUNT}"
echo "Passed: ${PASS_COUNT}"
echo "Failed: ${FAIL_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
exit 0
