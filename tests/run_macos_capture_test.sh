#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="${SCRIPT_DIR}/../bin/net-tap.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/net-tap-macos-capture.XXXXXX")"
export STATE_DIR="${TEST_DIR}/state"

cleanup() {
    if [[ -f "${STATE_DIR}/lo0.state" ]]; then
        "${BIN_PATH}" off -i lo0 >/dev/null 2>&1 || true
    fi
    rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" || "${EUID}" -ne 0 ]]; then
    echo "This capture lifecycle test requires macOS and root privileges." >&2
    exit 1
fi

echo "[TEST] Starting and stopping a loopback-only tcpdump capture..."
"${BIN_PATH}" on -i lo0 -o "${TEST_DIR}/captures" -C 1 -W 1
"${BIN_PATH}" status -i lo0 | grep -q "Capture: RUNNING"
"${BIN_PATH}" off -i lo0
[[ ! -e "${STATE_DIR}/lo0.state" ]]
pcap_found=0
for pcap_file in "${TEST_DIR}/captures"/*_lo0_trace.pcap*; do
    [[ -f "${pcap_file}" ]] && pcap_found=1
done
[[ "${pcap_found}" -eq 1 ]]
echo "macOS capture lifecycle passed."
