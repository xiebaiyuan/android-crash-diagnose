#!/usr/bin/env bash
# Collect Android crash artifacts and optionally ask Claude CLI to analyze them.

set -euo pipefail

PACKAGE="com.example.app"
OUT_DIR="/tmp"
DEVICE=""
ANALYZE=0
PULL_TOMBSTONES=1
PULL_ANR=1
BUGREPORT=0
TAIL_LINES=1200
CLAUDE_CMD="claude"
FILTER='\[MyApp\]|AndroidRuntime|FATAL EXCEPTION|Caused by|Caused[[:space:]]*$|^[[:space:]]*by:|crash_dump|tombstoned|DEBUG|backtrace|signal [0-9]+|SIGSEGV|SIGABRT|Abort message|APP_START_DURATION|ANR in|am_crash|am_anr'

usage() {
    cat <<'EOF'
Usage: android_crash_collect_analyze.sh [options]

Collect Android crash logs, dropbox records, tombstones/ANR traces when accessible,
package them under /tmp, and optionally invoke Claude CLI for analysis.

Options:
  -p, --package <name>       App package name (default: com.example.app)
  -k, --keyword <regex>      Extra grep -E pattern, OR-ed with defaults
  -t, --tag <text>           Extra literal tag/text, escaped and OR-ed with defaults
  -o, --out-dir <dir>        Output directory (default: /tmp)
  -s, --serial <serial>      adb device serial
      --analyze              Run Claude CLI after collection
      --claude-cmd <cmd>     Claude CLI command name/path (default: claude)
      --bugreport            Also collect adb bugreport; can be slow and large
      --no-tombstones        Do not try adb pull /data/tombstones
      --no-anr               Do not try adb pull /data/anr
      --tail-lines <count>   Full logcat tail lines embedded in Claude prompt (default: 1200)
  -h, --help                 Show this help

Examples:
  bash android_tools/android_crash_collect_analyze.sh -p com.example.app
  bash android_tools/android_crash_collect_analyze.sh -p com.example.app -t MyApp --analyze
  bash android_tools/android_crash_collect_analyze.sh -s emulator-5554 --bugreport

Output:
  /tmp/<package>_crash_bundle_<timestamp>/
  /tmp/<package>_crash_bundle_<timestamp>.tar.gz

Privacy:
  Logs may contain account, URL, token, device, or business data. This script only calls
  Claude when --analyze is provided explicitly.
EOF
}

escape_ere() {
    printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

adb_cmd() {
    if [[ -n "${DEVICE}" ]]; then
        adb -s "${DEVICE}" "$@"
    else
        adb "$@"
    fi
}

require_adb() {
    if ! command -v adb >/dev/null 2>&1; then
        echo "error: adb not found in PATH" >&2
        exit 1
    fi
}

require_value() {
    local option="$1"
    local value="${2-}"
    if [[ -z "${value}" ]]; then
        echo "error: ${option} requires a value" >&2
        exit 1
    fi
}

require_positive_integer() {
    local option="$1"
    local value="$2"
    if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" -eq 0 ]]; then
        echo "error: ${option} requires a positive integer" >&2
        exit 1
    fi
}

ensure_device() {
    if ! adb_cmd get-state >/dev/null 2>"${BUNDLE_DIR}/adb_get_state.err"; then
        echo "error: no adb device is ready. Use -s/--serial if multiple devices are connected." >&2
        echo "see: ${BUNDLE_DIR}/adb_get_state.err" >&2
        exit 1
    fi
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

capture_adb() {
    local label="$1"
    local outfile="$2"
    shift 2

    echo "collect: ${label} -> ${outfile}"
    if adb_cmd "$@" >"${outfile}" 2>"${outfile}.err"; then
        if [[ ! -s "${outfile}.err" ]]; then
            rm -f "${outfile}.err"
        fi
    else
        echo "warning: failed to collect ${label}; see ${outfile}.err" >&2
    fi
}

make_filtered_log() {
    local input="$1"
    local output="$2"

    if grep -E "${FILTER}" "${input}" >"${output}"; then
        return 0
    fi
    : >"${output}"
}

write_summary() {
    {
        echo "# Android Crash Bundle"
        echo ""
        echo "- package: ${PACKAGE}"
        echo "- device: ${DEVICE:-default adb target}"
        echo "- created_at: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "- bundle_dir: ${BUNDLE_DIR}"
        echo "- archive: ${ARCHIVE}"
        echo "- filter: ${FILTER}"
        echo ""
        echo "## Key files"
        echo ""
        echo "- logcat_all.log: full logcat from all buffers"
        echo "- logcat_crash_filtered.log: crash/tag focused lines"
        echo "- dropbox/*.txt: Android dropbox crash/tombstone/anr records"
        echo "- tombstones/: pulled /data/tombstones when adb has permission"
        echo "- anr/: pulled /data/anr when adb has permission"
        echo "- dumpsys_activity_crashes.txt / dumpsys_activity_anr.txt: activity manager crash/anr state"
        echo ""
        echo "## Quick counts"
        echo ""
        printf -- "- filtered log lines: "
        wc -l <"${BUNDLE_DIR}/logcat_crash_filtered.log" | tr -d ' '
        printf -- "- full logcat lines: "
        wc -l <"${BUNDLE_DIR}/logcat_all.log" | tr -d ' '
        printf -- "- tombstone files: "
        find "${BUNDLE_DIR}/tombstones" -type f 2>/dev/null | wc -l | tr -d ' '
        printf -- "- anr files: "
        find "${BUNDLE_DIR}/anr" -type f 2>/dev/null | wc -l | tr -d ' '
    } >"${BUNDLE_DIR}/SUMMARY.md"
}

append_file_excerpt() {
    local title="$1"
    local file="$2"
    local max_lines="$3"

    if [[ -s "${file}" ]]; then
        echo ""
        echo "## ${title}"
        echo ""
        echo '```'
        sed -n "1,${max_lines}p" "${file}"
        echo '```'
    fi
}

make_claude_input() {
    CLAUDE_INPUT="${BUNDLE_DIR}/claude_analysis_input.md"
    {
        echo "请分析这个 Android 崩溃诊断包，给出："
        echo "1. 最可能的崩溃类型和根因；"
        echo "2. Java/native/ANR 分别是否有证据；"
        echo "3. 关键日志证据，引用文件名和行片段；"
        echo "4. 下一步排查建议，优先给可执行命令或代码检查方向；"
        echo "5. 如果证据不足，请明确还缺哪些日志。"
        echo ""
        echo "诊断包路径：${BUNDLE_DIR}"
        echo "压缩包路径：${ARCHIVE}"
        echo "请优先阅读 SUMMARY.md、logcat_crash_filtered.log、dropbox/、tombstones/，必要时再看 logcat_all.log。"

        append_file_excerpt "SUMMARY.md" "${BUNDLE_DIR}/SUMMARY.md" 200
        append_file_excerpt "logcat_crash_filtered.log" "${BUNDLE_DIR}/logcat_crash_filtered.log" 1600

        echo ""
        echo "## logcat_all.log tail ${TAIL_LINES} lines"
        echo ""
        echo '```'
        tail -n "${TAIL_LINES}" "${BUNDLE_DIR}/logcat_all.log"
        echo '```'

        local file
        for file in "${BUNDLE_DIR}"/dropbox/*.txt; do
            [[ -e "${file}" ]] || continue
            append_file_excerpt "dropbox/$(basename "${file}")" "${file}" 500
        done

        while IFS= read -r file; do
            append_file_excerpt "tombstones/${file#${BUNDLE_DIR}/tombstones/}" "${file}" 900
        done < <(find "${BUNDLE_DIR}/tombstones" -type f | sort)

        while IFS= read -r file; do
            append_file_excerpt "anr/${file#${BUNDLE_DIR}/anr/}" "${file}" 900
        done < <(find "${BUNDLE_DIR}/anr" -type f | sort)
    } >"${CLAUDE_INPUT}"
}

run_claude_analysis() {
    if ! command -v "${CLAUDE_CMD}" >/dev/null 2>&1; then
        echo "error: Claude CLI not found: ${CLAUDE_CMD}" >&2
        echo "analysis input: ${CLAUDE_INPUT}" >&2
        exit 1
    fi

    CLAUDE_REPORT="${BUNDLE_DIR}/claude_analysis.md"
    echo "analyze: ${CLAUDE_CMD} -> ${CLAUDE_REPORT}"
    "${CLAUDE_CMD}" -p "$(cat "${CLAUDE_INPUT}")" | tee "${CLAUDE_REPORT}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--package)
            require_value "$1" "${2-}"
            PACKAGE="$2"
            shift 2
            ;;
        -k|--keyword)
            require_value "$1" "${2-}"
            FILTER="${FILTER}|$2"
            shift 2
            ;;
        -t|--tag)
            require_value "$1" "${2-}"
            FILTER="${FILTER}|$(escape_ere "$2")"
            shift 2
            ;;
        -o|--out-dir)
            require_value "$1" "${2-}"
            OUT_DIR="$2"
            shift 2
            ;;
        -s|--serial)
            require_value "$1" "${2-}"
            DEVICE="$2"
            shift 2
            ;;
        --analyze)
            ANALYZE=1
            shift
            ;;
        --claude-cmd)
            require_value "$1" "${2-}"
            CLAUDE_CMD="$2"
            shift 2
            ;;
        --bugreport)
            BUGREPORT=1
            shift
            ;;
        --no-tombstones)
            PULL_TOMBSTONES=0
            shift
            ;;
        --no-anr)
            PULL_ANR=0
            shift
            ;;
        --tail-lines)
            require_value "$1" "${2-}"
            require_positive_integer "$1" "$2"
            TAIL_LINES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_adb
TS=$(date +%Y%m%d_%H%M%S)
SAFE_PACKAGE=$(safe_name "${PACKAGE}")
BUNDLE_DIR="${OUT_DIR}/${SAFE_PACKAGE}_crash_bundle_${TS}"
ARCHIVE="${BUNDLE_DIR}.tar.gz"
mkdir -p "${BUNDLE_DIR}" "${BUNDLE_DIR}/dropbox" "${BUNDLE_DIR}/tombstones" "${BUNDLE_DIR}/anr"

ensure_device

capture_adb "adb devices" "${BUNDLE_DIR}/adb_devices.txt" devices -l
capture_adb "device properties" "${BUNDLE_DIR}/device_getprop.txt" shell getprop
capture_adb "device time" "${BUNDLE_DIR}/device_time.txt" shell date
capture_adb "package dumpsys" "${BUNDLE_DIR}/package_${SAFE_PACKAGE}.txt" shell dumpsys package "${PACKAGE}"
capture_adb "package pid" "${BUNDLE_DIR}/pidof_${SAFE_PACKAGE}.txt" shell pidof "${PACKAGE}"
capture_adb "activity crashes" "${BUNDLE_DIR}/dumpsys_activity_crashes.txt" shell dumpsys activity crashes
capture_adb "activity anr" "${BUNDLE_DIR}/dumpsys_activity_anr.txt" shell dumpsys activity anr
capture_adb "logcat all buffers" "${BUNDLE_DIR}/logcat_all.log" logcat -b all -d -v threadtime

make_filtered_log "${BUNDLE_DIR}/logcat_all.log" "${BUNDLE_DIR}/logcat_crash_filtered.log"

DROPBOX_TAGS=(
    data_app_crash
    system_app_crash
    data_app_native_crash
    system_app_native_crash
    data_app_anr
    system_app_anr
    SYSTEM_TOMBSTONE
    SYSTEM_TOMBSTONE_PROTO
)

for tag in "${DROPBOX_TAGS[@]}"; do
    capture_adb "dropbox ${tag}" "${BUNDLE_DIR}/dropbox/${tag}.txt" shell dumpsys dropbox --print "${tag}"
done

capture_adb "tombstones listing" "${BUNDLE_DIR}/tombstones_listing.txt" shell ls -lt /data/tombstones
if [[ "${PULL_TOMBSTONES}" -eq 1 ]]; then
    echo "collect: /data/tombstones -> ${BUNDLE_DIR}/tombstones"
    if ! adb_cmd pull /data/tombstones "${BUNDLE_DIR}/tombstones" >"${BUNDLE_DIR}/tombstones_pull.log" 2>&1; then
        echo "warning: failed to pull /data/tombstones; see ${BUNDLE_DIR}/tombstones_pull.log" >&2
    fi
fi

capture_adb "anr listing" "${BUNDLE_DIR}/anr_listing.txt" shell ls -lt /data/anr
if [[ "${PULL_ANR}" -eq 1 ]]; then
    echo "collect: /data/anr -> ${BUNDLE_DIR}/anr"
    if ! adb_cmd pull /data/anr "${BUNDLE_DIR}/anr" >"${BUNDLE_DIR}/anr_pull.log" 2>&1; then
        echo "warning: failed to pull /data/anr; see ${BUNDLE_DIR}/anr_pull.log" >&2
    fi
fi

if [[ "${BUGREPORT}" -eq 1 ]]; then
    echo "collect: bugreport -> ${BUNDLE_DIR}/bugreport.zip"
    if ! adb_cmd bugreport "${BUNDLE_DIR}/bugreport.zip" >"${BUNDLE_DIR}/bugreport.log" 2>&1; then
        echo "warning: failed to collect bugreport; see ${BUNDLE_DIR}/bugreport.log" >&2
    fi
fi

write_summary
tar -czf "${ARCHIVE}" -C "$(dirname "${BUNDLE_DIR}")" "$(basename "${BUNDLE_DIR}")"
make_claude_input

if [[ "${ANALYZE}" -eq 1 ]]; then
    run_claude_analysis
fi

echo ""
echo "bundle: ${BUNDLE_DIR}"
echo "archive: ${ARCHIVE}"
echo "summary: ${BUNDLE_DIR}/SUMMARY.md"
echo "claude input: ${CLAUDE_INPUT}"
if [[ "${ANALYZE}" -eq 0 ]]; then
    echo "next: ${CLAUDE_CMD} -p \"\$(cat '${CLAUDE_INPUT}')\""
fi
