#!/usr/bin/env bash
# Capture filtered Android app logs and crash signals while saving a full raw log.

set -euo pipefail

PACKAGE="com.example.app"
FILTER='\[MyApp\]|AndroidRuntime|FATAL EXCEPTION|Caused by|Caused[[:space:]]*$|^[[:space:]]*by:|crash_dump|tombstoned|SIGSEGV|SIGABRT|APP_START_DURATION'
OUT_DIR="/tmp"
CLEAR_LOGCAT=1
FOLLOW_PID=0
RAW_ONLY=0
DEVICE=""
WAIT_SECONDS=30

usage() {
    cat <<'EOF'
Usage: app_crash_logcat.sh [options]

Capture Android logcat for one app, print matched lines in terminal, and save logs to /tmp.
Designed to catch Java crashes, native tombstones, crash_dump, SIGSEGV/SIGABRT, and custom tags.

Options:
  -p, --package <name>       App package name (default: com.example.app)
  -k, --keyword <regex>      Extra grep -E pattern, OR-ed with defaults
  -t, --tag <text>           Extra literal tag/text, escaped and OR-ed with defaults
  -o, --out-dir <dir>        Output directory (default: /tmp)
  -s, --serial <serial>      adb device serial
      --pid-only             Filter logcat by current app PID only; may miss crash_dump/tombstoned
      --no-clear             Do not run adb logcat -c before capture
      --raw-only             Save raw log only, do not create filtered log file
      --wait <seconds>       Wait for app PID before starting (default: 30)
  -h, --help                 Show this help

Examples:
  ./android_tools/app_crash_logcat.sh
  ./android_tools/app_crash_logcat.sh -p com.example.app -t MyApp
  ./android_tools/app_crash_logcat.sh -k 'MyTag|IllegalStateException' -o /tmp
  ./android_tools/app_crash_logcat.sh -s emulator-5554 --no-clear

Output:
  /tmp/<package>_logcat_<timestamp>.raw.log       full logcat stream
  /tmp/<package>_logcat_<timestamp>.filtered.log  matched terminal lines
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

get_pid() {
    adb_cmd shell pidof "${PACKAGE}" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

wait_for_pid() {
    local pid=""
    local end=$((SECONDS + WAIT_SECONDS))

    while [[ ${SECONDS} -le ${end} ]]; do
        pid=$(get_pid)
        if [[ -n "${pid}" ]]; then
            printf '%s' "${pid}"
            return 0
        fi
        sleep 1
    done

    return 1
}

cleanup() {
    local status=$?
    if [[ -n "${RAW_LOG:-}" ]]; then
        echo ""
        echo "raw log: ${RAW_LOG}"
        if [[ "${RAW_ONLY}" -eq 0 ]]; then
            echo "filtered log: ${FILTERED_LOG}"
        fi
    fi
    exit "${status}"
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
        --pid-only)
            FOLLOW_PID=1
            shift
            ;;
        --no-clear)
            CLEAR_LOGCAT=0
            shift
            ;;
        --raw-only)
            RAW_ONLY=1
            shift
            ;;
        --wait)
            require_value "$1" "${2-}"
            WAIT_SECONDS="$2"
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
mkdir -p "${OUT_DIR}"

TS=$(date +%Y%m%d_%H%M%S)
SAFE_PACKAGE=${PACKAGE//[^A-Za-z0-9_.-]/_}
RAW_LOG="${OUT_DIR}/${SAFE_PACKAGE}_logcat_${TS}.raw.log"
FILTERED_LOG="${OUT_DIR}/${SAFE_PACKAGE}_logcat_${TS}.filtered.log"

if [[ "${CLEAR_LOGCAT}" -eq 1 ]]; then
    adb_cmd logcat -c
fi

PID=""
if PID=$(wait_for_pid); then
    echo "package: ${PACKAGE}"
    echo "pid: ${PID}"
else
    echo "warning: PID for ${PACKAGE} not found after ${WAIT_SECONDS}s; capturing global logcat to avoid missing crashes" >&2
fi

echo "raw log: ${RAW_LOG}"
if [[ "${RAW_ONLY}" -eq 0 ]]; then
    echo "filtered log: ${FILTERED_LOG}"
fi
echo "filter: ${FILTER}"
echo "Press Ctrl-C to stop."

trap cleanup EXIT INT TERM

LOGCAT_ARGS=(-v time)
if [[ "${FOLLOW_PID}" -eq 1 ]]; then
    if [[ -z "${PID}" ]]; then
        echo "error: --pid-only requires a running PID for ${PACKAGE}" >&2
        exit 1
    fi
    LOGCAT_ARGS+=(--pid="${PID}")
fi

if [[ "${RAW_ONLY}" -eq 1 ]]; then
    adb_cmd logcat "${LOGCAT_ARGS[@]}" | tee "${RAW_LOG}"
else
    adb_cmd logcat "${LOGCAT_ARGS[@]}" | tee "${RAW_LOG}" | grep --line-buffered -E "${FILTER}" | tee "${FILTERED_LOG}"
fi
