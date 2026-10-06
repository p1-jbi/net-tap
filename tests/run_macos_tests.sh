#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="${SCRIPT_DIR}/../bin/net-tap.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"
TEST_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/net-tap-macos-tests.XXXXXX")"
trap 'rm -rf "${TEST_STATE_DIR}"' EXIT

export STATE_DIR="${TEST_STATE_DIR}/state"
export PYTHONDONTWRITEBYTECODE=1

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This test suite must run on macOS." >&2
    exit 1
fi

echo "[TEST] Help works without Linux networking dependencies..."
"${BIN_PATH}" --help >/dev/null

echo "[TEST] Analysis runs against the synthetic PCAP fixture..."
analysis_json="$("${BIN_PATH}" analyze -d "${FIXTURES_DIR}" --json 2>/dev/null)"
printf '%s' "${analysis_json}" | python3 -c '
import json, jsonschema, pathlib, sys
schema = json.loads(pathlib.Path(sys.argv[1]).read_text())
jsonschema.validate(json.load(sys.stdin), schema)
' "${SCRIPT_DIR}/schema/analysis.schema.json"

echo "[TEST] Linux-only egress modes fail explicitly..."
if "${BIN_PATH}" on --mode active -i en0 >/dev/null 2>&1; then
    echo "Active mode unexpectedly succeeded on macOS." >&2
    exit 1
fi
if "${BIN_PATH}" probe -i en0 --arp-scan 192.0.2.0/24 >/dev/null 2>&1; then
    echo "Active probing unexpectedly succeeded on macOS." >&2
    exit 1
fi
if "${BIN_PATH}" on -n test-namespace -i en0 >/dev/null 2>&1; then
    echo "Network namespace mode unexpectedly succeeded on macOS." >&2
    exit 1
fi

echo "[TEST] macOS session listing returns JSON..."
"${BIN_PATH}" list --json | python3 -c 'import json,sys; assert json.load(sys.stdin) == []'
mkdir -p "${STATE_DIR}"
chmod 755 "${STATE_DIR}"
cat > "${STATE_DIR}/en0.state" <<EOF
declare -- IFACE="en0"
declare -- MODE="passive"
declare -- TIMESTAMP="20261005_120000"
declare -- OUT_DIR="${TEST_STATE_DIR}/captures"
declare -- ROTATE_SIZE="100"
declare -- ROTATE_COUNT="10"
declare -a PIDS_TCPDUMP=([0]="2147483647")
declare -a PCAP_FILES=([0]="${TEST_STATE_DIR}/captures/trace.pcap")
declare -a TCPDUMP_ERRS=([0]="${TEST_STATE_DIR}/captures/tcpdump.log")
EOF
chmod 600 "${STATE_DIR}/en0.state"
"${BIN_PATH}" list --json | python3 -c '
import json,sys
sessions = json.load(sys.stdin)
assert len(sessions) == 1 and sessions[0]["interface"] == "en0"
assert sessions[0]["status"] == "STOPPED"
'

echo "[TEST] macOS egress safeguards install and restore through scoped PF anchors..."
(
    NET_TAP_OS=Darwin
    STATE_DIR="${TEST_STATE_DIR}/state"
    MOCK_PF_RULE=""
    MOCK_ARP_DISABLED=0
    MOCK_ARP_RESTORED=0
    log_err() { echo "$*" >&2; }
    log_warn() { echo "$*" >&2; }
    pfctl() {
        case "$1" in
            -E) printf 'Token : 4321\n' ;;
            -sr) printf 'anchor "com.apple/*" all\n' ;;
            -a)
                case "$3" in
                    -f) MOCK_PF_RULE="$(cat "$4")" ;;
                    -sr) printf '%s\n' "${MOCK_PF_RULE}" ;;
                    -F) MOCK_PF_RULE="" ;;
                    *) return 1 ;;
                esac
                ;;
            -X) [[ "$2" == "4321" ]] ;;
            *) return 1 ;;
        esac
    }
    ifconfig() {
        if [[ $# -eq 1 ]]; then
            printf 'flags=8863<UP,BROADCAST,ARP>\n'
        elif [[ "$2" == "-arp" ]]; then
            MOCK_ARP_DISABLED=1
        elif [[ "$2" == "arp" ]]; then
            MOCK_ARP_RESTORED=1
        else
            return 1
        fi
    }
    source "${SCRIPT_DIR}/../lib/macos.sh"
    PF_ANCHORS=()
    ARP_CHANGED_IFACES=()
    PF_ENABLE_TOKEN=""
    macos_pf_acquire_lease
    macos_install_egress_guard "enTest" "com.apple/net-tap/session_123_0"
    [[ "${PF_ENABLE_TOKEN}" == "4321" ]]
    [[ "${MOCK_PF_RULE}" == "block drop out quick on enTest all" ]]
    [[ "${MOCK_ARP_DISABLED}" -eq 1 ]]
    macos_restore_egress_guards
    [[ -z "${MOCK_PF_RULE}" && -z "${PF_ENABLE_TOKEN}" ]]
    [[ "${MOCK_ARP_RESTORED}" -eq 1 ]]
)
echo "macOS tests passed."
