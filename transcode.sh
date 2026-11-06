#!/usr/bin/env bash
set -euo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_DIM=$'\033[2m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_BLUE=""
    COLOR_CYAN=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
fi

# Base bitrate estimates (1080p @ 30fps):
# ProRes 422 LT: ~45 GB/h video + 48 kHz stereo PCM audio (192 kB/s) = 12,692,000 B/s (1080p @ 30fps)
# H.264 All-Intra: ~15 GB/h video + 48 kHz stereo PCM audio (192 kB/s) = 4,358,667 B/s (1080p @ 30fps)
# Scaled dynamically for actual resolution and target framerate:
# Bitrate_clip ≈ Bitrate_base * (width * height / (1920 * 1080)) * (TARGET_FPS / 30)
readonly PRORES_BYTE_RATE=12692000
readonly H264_BYTE_RATE=4358667
readonly DISK_SAFETY_MARGIN_NUM=12
readonly DISK_SAFETY_MARGIN_DEN=10

readonly DEFAULT_OUTPUT_FOLDER_NAME="transcoded"

FORMAT="prores"
TARGET_FPS="30"
INPUT_DIR="."
SPECIFIC_FILE=""
OUTPUT_DIR=""
DRY_RUN=false
RECURSIVE=false

CURRENT_PARTIAL=""
FFMPEG_PID=""
TMP_DIR=""

cleanup_partial() {
    if [ -n "${CURRENT_PARTIAL:-}" ] && [ -f "${CURRENT_PARTIAL}" ]; then
        rm -f "${CURRENT_PARTIAL}"
        echo -e "${COLOR_YELLOW}⚠ Removed partial file: ${CURRENT_PARTIAL}${COLOR_RESET}" >&2
        CURRENT_PARTIAL=""
    fi
}

cleanup_tmp() {
    exec 3<&- 2>/dev/null || true
    if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
        TMP_DIR=""
    fi
}

on_sigint() {
    echo "" >&2
    echo -e "${COLOR_YELLOW}⚠ Interrupted by user (Ctrl+C): shutting down...${COLOR_RESET}" >&2
    if [ -n "${FFMPEG_PID:-}" ] && kill -0 "${FFMPEG_PID}" 2>/dev/null; then
        kill -TERM "${FFMPEG_PID}" 2>/dev/null || true
        wait "${FFMPEG_PID}" 2>/dev/null || true
    fi
    cleanup_partial
    cleanup_tmp
    exit 130
}

on_sigterm() {
    echo "" >&2
    echo -e "${COLOR_YELLOW}⚠ Received SIGTERM: shutting down...${COLOR_RESET}" >&2
    if [ -n "${FFMPEG_PID:-}" ] && kill -0 "${FFMPEG_PID}" 2>/dev/null; then
        kill -TERM "${FFMPEG_PID}" 2>/dev/null || true
        wait "${FFMPEG_PID}" 2>/dev/null || true
    fi
    cleanup_partial
    cleanup_tmp
    exit 143
}

on_exit() {
    local exit_code=$?
    if [ "${exit_code}" -ne 0 ]; then
        cleanup_partial
    fi
    cleanup_tmp
}

trap 'on_sigint' SIGINT
trap 'on_sigterm' SIGTERM
trap 'on_exit' EXIT

check_dependencies() {
    local missing=()
    for bin in ffmpeg ffprobe df awk numfmt; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            missing+=("${bin}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${COLOR_RED}${COLOR_BOLD}[ERROR] Missing required dependencies: ${missing[*]}${COLOR_RESET}" >&2
        echo -e "${COLOR_YELLOW}To install them on Fedora Linux, run the following DNF commands:${COLOR_RESET}" >&2
        echo "" >&2
        echo -e "  ${COLOR_CYAN}# 1. Enable RPM Fusion repositories (if not already enabled for full FFmpeg):${COLOR_RESET}" >&2
        echo -e "  sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm \\" >&2
        echo -e "                      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\$(rpm -E %fedora).noarch.rpm" >&2
        echo "" >&2
        echo -e "  ${COLOR_CYAN}# 2. Install FFmpeg, Coreutils, Gawk and desktop notification tools:${COLOR_RESET}" >&2
        echo -e "  sudo dnf install -y ffmpeg coreutils gawk libnotify" >&2
        echo "" >&2
        exit 1
    fi
}

show_help() {
    cat <<EOF
${COLOR_BOLD}Usage:${COLOR_RESET} $(basename "$0") [OPTIONS] [INPUT_DIR|FILE]

Production-grade transcode script to normalize video recordings
(VFR, HDR HLG/Dolby Vision) into stable editing formats (Apple ProRes / H.264 All-Intra).

${COLOR_BOLD}ARGUMENTS:${COLOR_RESET}
  INPUT_DIR|FILE           Source directory or video file to process
                           (Default: current directory)

${COLOR_BOLD}OPTIONS:${COLOR_RESET}
  -f, --format FORMAT      Output codec: ${COLOR_CYAN}prores${COLOR_RESET} (Apple ProRes 422 LT) or ${COLOR_CYAN}h264${COLOR_RESET} (All-Intra)
                           (Default: prores)
  -r, --fps FPS            Constant target framerate (CFR): ${COLOR_CYAN}30${COLOR_RESET} or ${COLOR_CYAN}60${COLOR_RESET} (Default: 30)
  -i, --input DIR|FILE     Source directory or video file (alternative to positional argument)
  -o, --output DIR         Destination directory for converted videos
                           (Default: <input>/${DEFAULT_OUTPUT_FOLDER_NAME})
  -R, --recursive          Scan input directory recursively including subfolders
  -d, --dry-run            Scan sources, verify disk space and print estimate
                           without running FFmpeg
  -h, --help               Display this help text and exit

${COLOR_BOLD}EXAMPLES:${COLOR_RESET}
  # Interactive mode
  $(basename "$0")

  # Process an entire folder passed directly as positional argument
  $(basename "$0") ~/Videos/iPhone

  # Process folder with options and save to custom destination
  $(basename "$0") ~/Videos/iPhone -f prores -r 30 -o ~/Videos/Transcoded_Clips

  # Process an entire folder recursively
  $(basename "$0") ~/Videos/iPhone -R

  # Convert a single video file
  $(basename "$0") clip.mov -f h264

  # Dry-run validation
  $(basename "$0") "./raw_footage" -d
EOF
}

format_duration() {
    local total_seconds
    total_seconds=$(awk -v s="${1:-0}" 'BEGIN {printf "%.0f", s}')
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    printf "%02d:%02d:%02d" "${hours}" "${minutes}" "${seconds}"
}

format_bytes() {
    local bytes="${1:-0}"
    if [ "${bytes}" -le 0 ]; then
        echo "0.0B"
        return
    fi
    numfmt --to=iec-i --suffix=B --format="%.1f" "${bytes}"
}

print_banner() {
    local codec_desc=""
    if [ "${FORMAT}" = "prores" ]; then
        codec_desc="Apple ProRes 422 LT (prores_ks profile 1, 10-bit 4:2:2)"
    else
        codec_desc="H.264 All-Intra (libx264 fast CRF 18, g=1, 8-bit 4:2:0)"
    fi

    echo ""
    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Video Transcoder v1.0.0${COLOR_RESET}"
    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Video codec  :${COLOR_RESET} ${codec_desc}"
    echo -e "  ${COLOR_DIM}Framerate    :${COLOR_RESET} ${TARGET_FPS} fps CFR (-fps_mode cfr)"
    echo -e "  ${COLOR_DIM}Color        :${COLOR_RESET} Rec.709 (BT.709, TV range) · auto HDR→SDR tone-mapping"
    echo -e "  ${COLOR_DIM}Audio        :${COLOR_RESET} PCM 16-bit 48 kHz (pcm_s16le)"
    if [ -n "${SPECIFIC_FILE}" ]; then
        echo -e "  ${COLOR_DIM}Source file  :${COLOR_RESET} ${SPECIFIC_FILE}"
    else
        echo -e "  ${COLOR_DIM}Source dir   :${COLOR_RESET} ${INPUT_DIR}"
        if [ "${RECURSIVE}" = true ]; then
            echo -e "  ${COLOR_DIM}Scan mode    :${COLOR_RESET} Recursive"
        fi
    fi
    echo -e "  ${COLOR_DIM}Destination  :${COLOR_RESET} ${OUTPUT_DIR}"
    if [ "${DRY_RUN}" = true ]; then
        echo -e "  ${COLOR_YELLOW}${COLOR_BOLD}MODE         : DRY-RUN (simulation only)${COLOR_RESET}"
    fi
    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo ""
}

run_interactive_mode() {
    echo -e "${COLOR_CYAN}${COLOR_BOLD}Welcome to Video Transcoder!${COLOR_RESET}"
    echo ""

    local input_prompt=""
    read -r -e -p "Enter source directory or video file [default: .]: " input_prompt
    input_prompt="${input_prompt:-.}"
    input_prompt="${input_prompt/#\~/$HOME}"

    if [ -d "${input_prompt}" ]; then
        INPUT_DIR="${input_prompt}"
        SPECIFIC_FILE=""
    elif [ -f "${input_prompt}" ]; then
        SPECIFIC_FILE="${input_prompt}"
        INPUT_DIR=$(dirname "${input_prompt}")
    else
        echo -e "${COLOR_RED}[ERROR] File or directory does not exist: ${input_prompt}${COLOR_RESET}" >&2
        exit 1
    fi

    if [ -z "${SPECIFIC_FILE}" ]; then
        local subdirs
        subdirs=$(find "${INPUT_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name ".*" 2>/dev/null | wc -l)
        if [ "${subdirs}" -gt 0 ]; then
            echo ""
            echo "Subdirectories detected in ${INPUT_DIR}."
            local choice_rec
            read -r -p "Scan subdirectories recursively? [y/N]: " choice_rec
            if [[ "${choice_rec}" =~ ^[yY] ]]; then
                RECURSIVE=true
            else
                RECURSIVE=false
            fi
        fi
    fi

    echo ""
    echo "Select target video format:"
    echo -e "  ${COLOR_BOLD}1)${COLOR_RESET} Apple ProRes 422 LT (10-bit 4:2:2, ultra-smooth editing, ~45 GB/h) ${COLOR_GREEN}[Default]${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}2)${COLOR_RESET} H.264 All-Intra (8-bit 4:2:0, balance between performance and storage, ~15 GB/h)"
    echo -e "  ${COLOR_BOLD}3)${COLOR_RESET} Exit"
    echo ""

    local choice_format
    read -r -p "Choice [1/2/3, default: 1]: " choice_format
    choice_format="${choice_format:-1}"

    case "${choice_format}" in
        1) FORMAT="prores" ;;
        2) FORMAT="h264" ;;
        3) echo "Exiting."; exit 0 ;;
        *) echo -e "${COLOR_RED}Invalid choice.${COLOR_RESET}"; exit 1 ;;
    esac

    echo ""
    echo "Select target constant framerate (CFR):"
    echo -e "  ${COLOR_BOLD}1)${COLOR_RESET} 30 fps ${COLOR_GREEN}[Default]${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}2)${COLOR_RESET} 60 fps"
    echo ""

    local choice_fps
    read -r -p "Choice [1/2, default: 1]: " choice_fps
    choice_fps="${choice_fps:-1}"

    case "${choice_fps}" in
        1) TARGET_FPS="30" ;;
        2) TARGET_FPS="60" ;;
        *) echo -e "${COLOR_RED}Invalid choice.${COLOR_RESET}"; exit 1 ;;
    esac

    OUTPUT_DIR="${INPUT_DIR}/${DEFAULT_OUTPUT_FOLDER_NAME}"
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--format)
                if [ -z "${2:-}" ]; then
                    echo -e "${COLOR_RED}[ERROR] Option $1 requires a value (prores or h264).${COLOR_RESET}" >&2
                    exit 1
                fi
                FORMAT=$(echo "$2" | tr '[:upper:]' '[:lower:]')
                if [ "${FORMAT}" != "prores" ] && [ "${FORMAT}" != "h264" ]; then
                    echo -e "${COLOR_RED}[ERROR] Invalid format: '$2'. Allowed values: prores, h264.${COLOR_RESET}" >&2
                    exit 1
                fi
                shift 2
                ;;
            -r|--fps)
                if [ -z "${2:-}" ]; then
                    echo -e "${COLOR_RED}[ERROR] Option $1 requires a value (30 or 60).${COLOR_RESET}" >&2
                    exit 1
                fi
                TARGET_FPS="$2"
                if [ "${TARGET_FPS}" != "30" ] && [ "${TARGET_FPS}" != "60" ]; then
                    echo -e "${COLOR_RED}[ERROR] Invalid framerate: '$2'. Recommended values: 30, 60.${COLOR_RESET}" >&2
                    exit 1
                fi
                shift 2
                ;;
            -i|--input)
                if [ -z "${2:-}" ]; then
                    echo -e "${COLOR_RED}[ERROR] Option $1 requires a path.${COLOR_RESET}" >&2
                    exit 1
                fi
                if [ -n "${INPUT_ALREADY_SET:-}" ]; then
                    echo -e "${COLOR_RED}[ERROR] Multiple input paths provided. Only one input path is allowed.${COLOR_RESET}" >&2
                    exit 1
                fi
                local in_arg="$2"
                in_arg="${in_arg/#\~/$HOME}"
                if [ -d "${in_arg}" ]; then
                    INPUT_DIR="${in_arg}"
                    SPECIFIC_FILE=""
                elif [ -f "${in_arg}" ]; then
                    SPECIFIC_FILE="${in_arg}"
                    INPUT_DIR=$(dirname "${in_arg}")
                else
                    echo -e "${COLOR_RED}[ERROR] Input path does not exist: '$2'.${COLOR_RESET}" >&2
                    exit 1
                fi
                INPUT_ALREADY_SET=true
                shift 2
                ;;
            -o|--output)
                if [ -z "${2:-}" ]; then
                    echo -e "${COLOR_RED}[ERROR] Option $1 requires a directory path.${COLOR_RESET}" >&2
                    exit 1
                fi
                OUTPUT_DIR="$2"
                OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
                shift 2
                ;;
            -R|-s|--recursive)
                RECURSIVE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --)
                shift
                if [ $# -gt 0 ]; then
                    if [ -n "${INPUT_ALREADY_SET:-}" ]; then
                        echo -e "${COLOR_RED}[ERROR] Multiple input arguments provided. Only one input path is allowed.${COLOR_RESET}" >&2
                        exit 1
                    fi
                    local pos_arg="$1"
                    pos_arg="${pos_arg/#\~/$HOME}"
                    if [ -d "${pos_arg}" ]; then
                        INPUT_DIR="${pos_arg}"
                        SPECIFIC_FILE=""
                    elif [ -f "${pos_arg}" ]; then
                        SPECIFIC_FILE="${pos_arg}"
                        INPUT_DIR=$(dirname "${pos_arg}")
                    else
                        echo -e "${COLOR_RED}[ERROR] Target path does not exist: '$1'.${COLOR_RESET}" >&2
                        exit 1
                    fi
                    INPUT_ALREADY_SET=true
                    shift
                    if [ $# -gt 0 ]; then
                        echo -e "${COLOR_RED}[ERROR] Multiple input arguments provided. Only one input path is allowed.${COLOR_RESET}" >&2
                        exit 1
                    fi
                fi
                break
                ;;
            -*)
                echo -e "${COLOR_RED}[ERROR] Unknown option: '$1'.${COLOR_RESET}" >&2
                echo "Run $(basename "$0") --help for usage information." >&2
                exit 1
                ;;
            *)
                if [ -n "${INPUT_ALREADY_SET:-}" ]; then
                    echo -e "${COLOR_RED}[ERROR] Multiple input arguments provided ('$1' received, but input already set).${COLOR_RESET}" >&2
                    exit 1
                fi
                local pos_arg="$1"
                pos_arg="${pos_arg/#\~/$HOME}"
                if [ -d "${pos_arg}" ]; then
                    INPUT_DIR="${pos_arg}"
                    SPECIFIC_FILE=""
                elif [ -f "${pos_arg}" ]; then
                    SPECIFIC_FILE="${pos_arg}"
                    INPUT_DIR=$(dirname "${pos_arg}")
                else
                    echo -e "${COLOR_RED}[ERROR] Target path does not exist: '$1'.${COLOR_RESET}" >&2
                    exit 1
                fi
                INPUT_ALREADY_SET=true
                shift
                ;;
        esac
    done
}

resolve_paths() {
    if [ -n "${SPECIFIC_FILE}" ]; then
        if [ ! -f "${SPECIFIC_FILE}" ]; then
            echo -e "${COLOR_RED}[ERROR] Source file does not exist: ${SPECIFIC_FILE}${COLOR_RESET}" >&2
            exit 1
        fi
        SPECIFIC_FILE=$(cd "$(dirname "${SPECIFIC_FILE}")" && pwd -P)/$(basename "${SPECIFIC_FILE}")
        INPUT_DIR=$(dirname "${SPECIFIC_FILE}")
    else
        if [ ! -d "${INPUT_DIR}" ]; then
            echo -e "${COLOR_RED}[ERROR] Source directory does not exist: ${INPUT_DIR}${COLOR_RESET}" >&2
            exit 1
        fi
        INPUT_DIR=$(cd "${INPUT_DIR}" && pwd -P)
    fi

    if [ -z "${OUTPUT_DIR}" ]; then
        OUTPUT_DIR="${INPUT_DIR}/${DEFAULT_OUTPUT_FOLDER_NAME}"
    else
        if [ "${DRY_RUN}" = false ]; then
            mkdir -p "${OUTPUT_DIR}"
            OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd -P)
        else
            if [ -d "${OUTPUT_DIR}" ]; then
                OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd -P)
            fi
        fi
    fi
}

VALID_FILES=()
VALID_DURATIONS=()
VALID_WIDTHS=()
VALID_HEIGHTS=()
VALID_RES_STRS=()
VALID_IS_HDR=()
VALID_HAS_AUDIO=()
VALID_TARGET_PATHS=()
TOTAL_SCANNED_COUNT=0
TOTAL_SKIPPED_COUNT=0
TOTAL_DURATION_SEC=0

inspect_and_validate_files() {
    VALID_FILES=()
    VALID_DURATIONS=()
    VALID_WIDTHS=()
    VALID_HEIGHTS=()
    VALID_RES_STRS=()
    VALID_IS_HDR=()
    VALID_HAS_AUDIO=()
    VALID_TARGET_PATHS=()
    TOTAL_DURATION_SEC=0
    TOTAL_SKIPPED_COUNT=0

    local candidate_files=()

    if [ -n "${SPECIFIC_FILE}" ]; then
        local bname
        bname=$(basename "${SPECIFIC_FILE}")
        if [[ "${bname}" =~ ^\. ]] || [[ "${bname}" =~ _transcoded\.mov$ ]] || [[ "${bname}" =~ _kdenlive\.mov$ ]]; then
            echo -e "${COLOR_YELLOW}Specified file '${bname}' is hidden or already transcoded.${COLOR_RESET}"
            exit 0
        fi
        candidate_files+=("${SPECIFIC_FILE}")
    elif [ "${RECURSIVE}" = true ]; then
        local escaped_output_dir
        escaped_output_dir=$(printf '%s' "${OUTPUT_DIR}" | sed 's/[][*?]/\\&/g')
        while IFS= read -r -d '' file; do
            local bname
            bname=$(basename "${file}")
            if [[ "${bname}" =~ ^\. ]] || [[ "${bname}" =~ _transcoded\.mov$ ]] || [[ "${bname}" =~ _kdenlive\.mov$ ]]; then
                continue
            fi
            candidate_files+=("${file}")
        done < <(find "${INPUT_DIR}" -mindepth 1 \( -path "${escaped_output_dir}" -o -name ".*" \) -prune -o -type f \( -iname "*.mov" -o -iname "*.mp4" -o -iname "*.m4v" \) -print0 | sort -z)
    else
        while IFS= read -r -d '' file; do
            local bname
            bname=$(basename "${file}")
            if [[ "${bname}" =~ ^\. ]] || [[ "${bname}" =~ _transcoded\.mov$ ]] || [[ "${bname}" =~ _kdenlive\.mov$ ]]; then
                continue
            fi
            candidate_files+=("${file}")
        done < <(find "${INPUT_DIR}" -maxdepth 1 -type f \( -iname "*.mov" -o -iname "*.mp4" -o -iname "*.m4v" \) -print0 | sort -z)
    fi

    TOTAL_SCANNED_COUNT=${#candidate_files[@]}

    if [ "${TOTAL_SCANNED_COUNT}" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}No video files (.mov, .mp4, .m4v) found in: ${INPUT_DIR}${COLOR_RESET}"
        exit 0
    fi

    echo -e "Source file analysis and validation (${TOTAL_SCANNED_COUNT} found)"

    local clean_input_prefix="${INPUT_DIR%/}/"
    declare -A seen_targets=()

    for file in "${candidate_files[@]}"; do
        local bname
        bname=$(basename "${file}")

        if [ ! -s "${file}" ]; then
            echo -e "  ${COLOR_RED}✖${COLOR_RESET} ${bname} ${COLOR_DIM}(empty file / 0 bytes)${COLOR_RESET}"
            TOTAL_SKIPPED_COUNT=$((TOTAL_SKIPPED_COUNT + 1))
            continue
        fi

        local probe_v
        if ! probe_v=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name,width,height,r_frame_rate,avg_frame_rate,pix_fmt,color_space,color_transfer,color_primaries \
            -show_entries format=duration \
            -of default=noprint_wrappers=1 "${file}" 2>&1); then
            echo -e "  ${COLOR_RED}✖${COLOR_RESET} ${bname} ${COLOR_DIM}(invalid or corrupted video stream)${COLOR_RESET}"
            TOTAL_SKIPPED_COUNT=$((TOTAL_SKIPPED_COUNT + 1))
            continue
        fi

        local codec_name="" width="" height="" r_fps="" avg_fps="" pix_fmt="" c_space="" c_trc="" c_prim="" duration=""
        while IFS='=' read -r key val; do
            case "${key}" in
                codec_name) codec_name="${val}" ;;
                width) width="${val}" ;;
                height) height="${val}" ;;
                r_frame_rate) r_fps="${val}" ;;
                avg_frame_rate) avg_fps="${val}" ;;
                pix_fmt) pix_fmt="${val}" ;;
                color_space) c_space="${val}" ;;
                color_transfer) c_trc="${val}" ;;
                color_primaries) c_prim="${val}" ;;
                duration) duration="${val}" ;;
            esac
        done <<< "${probe_v}"

        if [ -z "${codec_name}" ] || [ -z "${width}" ] || [ -z "${height}" ]; then
            echo -e "  ${COLOR_RED}✖${COLOR_RESET} ${bname} ${COLOR_DIM}(no video stream detected)${COLOR_RESET}"
            TOTAL_SKIPPED_COUNT=$((TOTAL_SKIPPED_COUNT + 1))
            continue
        fi

        local fps_val
        fps_val=$(awk -F'/' '{if ($2 && $2>0) printf "%.0f", $1/$2; else printf "%.0f", $1}' <<< "${r_fps:-30/1}")
        local fps_mode="CFR"
        if [ -n "${r_fps}" ] && [ -n "${avg_fps}" ] && [ "${r_fps}" != "${avg_fps}" ]; then
            fps_mode="VFR"
        fi

        local res_label="${height}p"
        if [ "${height}" -eq 1080 ] && [ "${width}" -eq 1920 ]; then
            res_label="1080p"
        elif [ "${height}" -eq 720 ] && [ "${width}" -eq 1280 ]; then
            res_label="720p"
        elif [ "${height}" -eq 2160 ] && [ "${width}" -eq 3840 ]; then
            res_label="4K (2160p)"
        elif [ "${width}" -eq 720 ] && [ "${height}" -eq 1280 ]; then
            res_label="720p vertical"
        elif [ "${width}" -eq 1080 ] && [ "${height}" -eq 1920 ]; then
            res_label="1080p vertical"
        fi

        local codec_upper
        codec_upper=$(echo "${codec_name}" | tr '[:lower:]' '[:upper:]')

        local is_hdr=false
        local hdr_tag=""
        if [[ "${c_trc}" =~ arib-std-b67|smpte2084 ]] || [[ "${c_prim}" =~ bt2020 ]] || [[ "${c_space}" =~ bt2020 ]]; then
            is_hdr=true
            hdr_tag=" · HDR"
        fi

        local has_audio=false
        if ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1 "${file}" 2>&1 | grep -q "codec_name="; then
            has_audio=true
        fi

        local stem="${bname%.*}"
        local orig_ext="${bname##*.}"
        local target_name="${stem}_transcoded.mov"

        # Determine target directory (preserve relative subfolders if recursive)
        local target_dir="${OUTPUT_DIR}"
        if [ "${RECURSIVE}" = true ] && [ -z "${SPECIFIC_FILE}" ]; then
            local rel_path="${file#"${clean_input_prefix}"}"
            local rel_dir
            rel_dir=$(dirname "${rel_path}")
            if [ "${rel_dir}" != "." ]; then
                target_dir="${OUTPUT_DIR}/${rel_dir}"
            fi
        fi

        local candidate_target="${target_dir}/${target_name}"

        if [[ -n "${seen_targets[${candidate_target}]:-}" ]] || [ -e "${candidate_target}" ]; then
            local ext_clean
            ext_clean=$(echo "${orig_ext}" | tr '[:upper:]' '[:lower:]')
            target_name="${stem}_${ext_clean}_transcoded.mov"
            candidate_target="${target_dir}/${target_name}"

            local counter=1
            while true; do
                if [[ -z "${seen_targets[${candidate_target}]:-}" ]] && [ ! -e "${candidate_target}" ]; then
                    break
                fi
                target_name="${stem}_${counter}_transcoded.mov"
                candidate_target="${target_dir}/${target_name}"
                counter=$((counter + 1))
            done
        fi
        seen_targets["${candidate_target}"]=1

        local dur_float="${duration:-0}"
        TOTAL_DURATION_SEC=$(awk -v t="${TOTAL_DURATION_SEC}" -v d="${dur_float}" 'BEGIN {printf "%.6f", t + d}')

        local res_desc="${res_label} @ ${fps_val}fps ${fps_mode} · ${codec_upper}${hdr_tag}"
        echo -e "  ${COLOR_GREEN}✔${COLOR_RESET} ${bname} ${COLOR_DIM}(${res_desc})${COLOR_RESET}"

        VALID_FILES+=("${file}")
        VALID_DURATIONS+=("${dur_float}")
        VALID_WIDTHS+=("${width}")
        VALID_HEIGHTS+=("${height}")
        VALID_RES_STRS+=("${res_desc}")
        VALID_IS_HDR+=("${is_hdr}")
        VALID_HAS_AUDIO+=("${has_audio}")
        VALID_TARGET_PATHS+=("${candidate_target}")
    done

    echo ""
}

check_disk_space() {
    local valid_count=${#VALID_FILES[@]}
    if [ "${valid_count}" -eq 0 ]; then
        echo -e "${COLOR_RED}[ERROR] No valid source files to convert.${COLOR_RESET}" >&2
        exit 1
    fi

    local rate_bps
    if [ "${FORMAT}" = "prores" ]; then
        rate_bps="${PRORES_BYTE_RATE}"
    else
        rate_bps="${H264_BYTE_RATE}"
    fi

    local estimated_bytes
    estimated_bytes=$(
        for i in "${!VALID_FILES[@]}"; do
            printf '%s\t%s\t%s\n' "${VALID_DURATIONS[$i]}" "${VALID_WIDTHS[$i]}" "${VALID_HEIGHTS[$i]}"
        done | awk -F'\t' -v base="${rate_bps}" -v fps="${TARGET_FPS}" '
        {
            dur = $1 + 0
            w = $2 + 0
            h = $3 + 0
            if (w <= 0 || h <= 0) {
                w = 1920
                h = 1080
            }
            res_factor = (w * h) / (1920.0 * 1080.0)
            fps_factor = (fps > 0 ? fps : 30.0) / 30.0
            clip_bytes = dur * base * res_factor * fps_factor
            total += clip_bytes
        }
        END {
            printf "%.0f", total
        }'
    )

    local required_bytes=$(( (estimated_bytes * DISK_SAFETY_MARGIN_NUM) / DISK_SAFETY_MARGIN_DEN ))

    local check_dir="${OUTPUT_DIR}"
    while [ ! -d "${check_dir}" ]; do
        local parent
        parent=$(dirname "${check_dir}")
        if [ "${parent}" = "${check_dir}" ]; then
            break
        fi
        check_dir="${parent}"
    done

    if [ "${DRY_RUN}" = false ]; then
        mkdir -p "${OUTPUT_DIR}"
    fi

    local avail_bytes
    avail_bytes=$(df -PB 1 "${check_dir}" | awk 'NR==2 {print $4}')

    local dur_formatted
    dur_formatted=$(format_duration "${TOTAL_DURATION_SEC}")
    local est_formatted
    est_formatted=$(format_bytes "${estimated_bytes}")
    local req_formatted
    req_formatted=$(format_bytes "${required_bytes}")
    local avail_formatted
    avail_formatted=$(format_bytes "${avail_bytes}")

    local partition_ref="${check_dir}"

    echo -e "${COLOR_BOLD}Disk space check${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Duration to convert       :${COLOR_RESET} ${dur_formatted}"
    echo -e "  ${COLOR_DIM}Estimated output size     :${COLOR_RESET} ${est_formatted}"
    echo -e "  ${COLOR_DIM}Required (+20% safety)    :${COLOR_RESET} ${req_formatted}"
    echo -e "  ${COLOR_DIM}Available                 :${COLOR_RESET} ${avail_formatted} (partition of ${partition_ref})"

    if [ "${avail_bytes}" -lt "${required_bytes}" ]; then
        echo -e "${COLOR_RED}✖ Insufficient disk space!${COLOR_RESET}" >&2
        echo -e "  Available: ${avail_formatted}, but at least ${req_formatted} is required (+20% safety margin to prevent disk exhaustion).${COLOR_RESET}" >&2
        echo -e "  Free up space or choose another destination folder with ${COLOR_CYAN}-o|--output${COLOR_RESET}." >&2
        exit 1
    fi

    echo -e "${COLOR_GREEN}✔ Sufficient disk space.${COLOR_RESET}"
    echo ""
}

CONVERTED_COUNT=0
FAILED_COUNT=0
TOTAL_CONVERTED_SIZE=0

convert_files() {
    local total_files=${#VALID_FILES[@]}

    if [ "${DRY_RUN}" = true ]; then
        echo -e "${COLOR_YELLOW}[DRY-RUN] Simulation completed without errors.${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_BOLD}Conversion (${total_files} files)${COLOR_RESET}"
    echo ""

    TMP_DIR=$(mktemp -d "/tmp/transcoder_tmp.XXXXXX")
    local err_log="${TMP_DIR}/ffmpeg.err"

    for i in "${!VALID_FILES[@]}"; do
        local src_file="${VALID_FILES[$i]}"
        local bname
        bname=$(basename "${src_file}")
        local final_target="${VALID_TARGET_PATHS[$i]}"
        local target_dir
        target_dir=$(dirname "${final_target}")
        local target_name
        target_name=$(basename "${final_target}")
        local partial_target="${target_dir}/.${target_name%.mov}.part.mov"
        local dur_float="${VALID_DURATIONS[$i]}"
        local dur_total_us
        dur_total_us=$(awk -v d="${dur_float}" 'BEGIN {printf "%.0f", d * 1000000}')
        local is_hdr="${VALID_IS_HDR[$i]}"
        local has_audio="${VALID_HAS_AUDIO[$i]}"
        local res_desc="${VALID_RES_STRS[$i]}"

        mkdir -p "${target_dir}"

        local idx=$((i + 1))
        echo -e "[${idx}/${total_files}] Processing: ${bname} ${COLOR_DIM}(${res_desc})${COLOR_RESET}"
        echo -e "      → ${final_target}"

        CURRENT_PARTIAL="${partial_target}"

        local ffmpeg_cmd=(
            ffmpeg -y -hide_banner -loglevel error
            -i "${src_file}"
            -fps_mode cfr -r "${TARGET_FPS}"
        )

        if [ "${FORMAT}" = "prores" ]; then
            ffmpeg_cmd+=( -c:v prores_ks -profile:v 1 -pix_fmt yuv422p10le )
            if [ "${is_hdr}" = true ]; then
                ffmpeg_cmd+=( -vf "zscale=t=linear:npl=100,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv422p10le" )
            fi
        else
            ffmpeg_cmd+=( -c:v libx264 -preset fast -crf 18 -g 1 -pix_fmt yuv420p )
            if [ "${is_hdr}" = true ]; then
                ffmpeg_cmd+=( -vf "zscale=t=linear:npl=100,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p" )
            fi
        fi

        ffmpeg_cmd+=( -color_primaries bt709 -color_trc bt709 -colorspace bt709 )

        if [ "${has_audio}" = true ]; then
            ffmpeg_cmd+=( -c:a pcm_s16le -ar 48000 )
        else
            ffmpeg_cmd+=( -an )
        fi

        ffmpeg_cmd+=( -progress pipe:1 "${partial_target}" )

        local start_clip_time
        start_clip_time=$(date +%s)

        exec 3< <(exec "${ffmpeg_cmd[@]}" 2>"${err_log}")
        FFMPEG_PID=$!

        local out_time_us=0
        local speed="1.00x"

        while IFS='=' read -u 3 -r key val; do
            case "${key}" in
                out_time_us)
                    out_time_us="${val}"
                    ;;
                speed)
                    speed=$(echo "${val}" | sed 's/^[ \t]*//')
                    ;;
                progress)
                    if [ "${val}" = "end" ]; then
                        break
                    fi
                    local now
                    now=$(date +%s)
                    local elapsed=$((now - start_clip_time))
                    local elapsed_str
                    elapsed_str=$(format_duration "${elapsed}")

                    local pct=0
                    if [ "${dur_total_us}" -gt 0 ]; then
                        pct=$(( (out_time_us * 100) / dur_total_us ))
                        if [ "${pct}" -gt 100 ]; then pct=100; fi
                    fi

                    local eta_str="00:00:00"
                    local speed_num
                    speed_num=$(echo "${speed}" | sed 's/x//' | tr -d ' ')
                    if awk -v s="${speed_num}" 'BEGIN {exit !(s > 0.05)}' 2>/dev/null && [ "${dur_total_us}" -gt "${out_time_us}" ]; then
                        local rem_us=$((dur_total_us - out_time_us))
                        local rem_sec
                        rem_sec=$(awk -v r="${rem_us}" -v s="${speed_num}" 'BEGIN {printf "%.0f", (r / 1000000) / s}')
                        eta_str=$(format_duration "${rem_sec}")
                    fi

                    printf "      progress %3d%% · elapsed %s · ETA %s · speed=%s\r" \
                        "${pct}" "${elapsed_str}" "${eta_str}" "${speed}"
                    ;;
            esac
        done
        exec 3<&-

        wait "${FFMPEG_PID}" || {
            local exit_status=$?
            echo "" >&2
            echo -e "      ${COLOR_RED}✖ Error during transcoding of ${bname} (exit code ${exit_status})${COLOR_RESET}" >&2
            if [ -f "${err_log}" ]; then
                tail -n 5 "${err_log}" | sed 's/^/        /' >&2
            fi
            cleanup_partial
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        }

        FFMPEG_PID=""

        if [ -f "${partial_target}" ]; then
            mv "${partial_target}" "${final_target}"
            CURRENT_PARTIAL=""
            local file_size
            file_size=$(stat -c%s "${final_target}" 2>/dev/null || wc -c < "${final_target}")
            TOTAL_CONVERTED_SIZE=$((TOTAL_CONVERTED_SIZE + file_size))
            local size_str
            size_str=$(format_bytes "${file_size}")

            local end_clip_time
            end_clip_time=$(date +%s)
            local clip_duration=$((end_clip_time - start_clip_time))
            local clip_dur_str
            clip_dur_str=$(format_duration "${clip_duration}")

            printf "      progress 100%% · elapsed %s · speed=%s\r" "${clip_dur_str}" "${speed}"
            echo -e "\n      ${COLOR_GREEN}✔ Completed${COLOR_RESET} in ${clip_dur_str} ${COLOR_DIM}(size: ${size_str})${COLOR_RESET}"
            CONVERTED_COUNT=$((CONVERTED_COUNT + 1))
        else
            echo -e "      ${COLOR_RED}✖ Error: output file not found.${COLOR_RESET}" >&2
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        echo ""
    done

    cleanup_tmp
}

print_summary_and_notify() {
    local start_time="${1:-}"
    local total_time_sec=0
    if [ -n "${start_time}" ]; then
        local now
        now=$(date +%s)
        total_time_sec=$((now - start_time))
    fi

    local time_formatted
    time_formatted=$(format_duration "${total_time_sec}")
    local size_formatted
    size_formatted=$(format_bytes "${TOTAL_CONVERTED_SIZE}")

    local total_failed=$((TOTAL_SKIPPED_COUNT + FAILED_COUNT))

    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Processing Summary${COLOR_RESET}"
    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Total files analyzed       :${COLOR_RESET} ${TOTAL_SCANNED_COUNT}"
    echo -e "  ${COLOR_DIM}Successfully converted     :${COLOR_RESET} ${COLOR_GREEN}${COLOR_BOLD}${CONVERTED_COUNT}${COLOR_RESET}"
    if [ "${total_failed}" -gt 0 ]; then
        echo -e "  ${COLOR_DIM}Failed / Skipped           :${COLOR_RESET} ${COLOR_YELLOW}${total_failed}${COLOR_RESET}"
    else
        echo -e "  ${COLOR_DIM}Failed / Skipped           :${COLOR_RESET} 0"
    fi
    echo -e "  ${COLOR_DIM}Disk space used            :${COLOR_RESET} ${size_formatted}"
    echo -e "  ${COLOR_DIM}Total time elapsed         :${COLOR_RESET} ${time_formatted}"
    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Destination:${COLOR_RESET} ${OUTPUT_DIR}"
    echo -e "${COLOR_BLUE}──────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo ""

    if command -v notify-send >/dev/null 2>&1; then
        local notify_title="Video Transcoder"
        local notify_msg="${CONVERTED_COUNT} videos successfully converted in ${time_formatted} (${size_formatted})."
        if [ "${FAILED_COUNT}" -gt 0 ]; then
            notify_msg="${CONVERTED_COUNT} succeeded, ${FAILED_COUNT} failed in ${time_formatted}."
            notify-send -i "dialog-warning" -a "Video Transcoder" "${notify_title}" "${notify_msg}" 2>/dev/null || true
        else
            notify-send -i "video-x-generic" -a "Video Transcoder" "${notify_title}" "${notify_msg}" 2>/dev/null || true
        fi
    fi
}

main() {
    local global_start_time
    global_start_time=$(date +%s)

    check_dependencies

    if [ $# -eq 0 ]; then
        if [ -t 0 ]; then
            run_interactive_mode
        else
            show_help
            exit 0
        fi
    else
        parse_arguments "$@"
    fi

    resolve_paths
    print_banner
    inspect_and_validate_files
    check_disk_space
    convert_files
    print_summary_and_notify "${global_start_time}"
}

main "$@"
