#!/usr/bin/env bash
# shellcheck shell=bash

macos_reject_unsupported_options() {
    if [[ -n "${NETNS:-}" ]]; then
        log_err "Network namespaces are Linux-only and are not available on macOS."
        exit 1
    fi
    if [[ "${MODE:-passive}" != "passive" ]]; then
        log_err "Active probing and selective-egress mode are Linux-only. macOS capture does not provide net-tap's zero-egress guarantee."
        exit 1
    fi
    if [[ "${ACTION}" == "on" && ( -n "${SPEED:-}" || "${HW_TYPE:-ethernet}" == "sfp" ) ]]; then
        log_err "SFP diagnostics and forced link speed are Linux-only."
        exit 1
    fi
    if [[ "${ACTION}" == "on" && -n "${DURATION:-}" ]]; then
        log_err "Timed auto-shutdown is not supported by the macOS capture backend yet."
        exit 1
    fi
    if [[ "${ACTION}" == "on" && "${DISK_THRESH:-85}" != "85" ]]; then
        log_err "The disk-usage watchdog threshold is Linux-only; macOS capture uses tcpdump ring-buffer limits."
        exit 1
    fi
}

_macos_state_file() {
    local safe_iface="${IFACE//\//_}"
    printf '%s/%s.state' "${STATE_DIR}" "${safe_iface}"
}

macos_capture_process_matches() {
    local pid="$1" iface="$2" pcap_file="$3" command_line
    process_matches "${pid}" '.*tcpdump.*' || return 1
    command_line="$(process_command "${pid}")" || return 1
    [[ "${command_line}" == *"-i ${iface}"* && "${command_line}" == *"${pcap_file}"* ]]
}

macos_acquire_lock() {
    local lock_dir="$1" lock_pid=""
    if ! mkdir "${lock_dir}" 2>/dev/null; then
        if [[ -f "${lock_dir}/pid" && ! -L "${lock_dir}/pid" ]]; then
            lock_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
        fi
        if [[ "${lock_pid}" =~ ^[1-9][0-9]*$ ]] && process_matches "${lock_pid}" '.*(bash|net-tap).*' 'net-tap'; then
            log_err "Another net-tap operation holds ${lock_dir} (PID ${lock_pid})."
            return 1
        fi
        rm -f "${lock_dir}/pid"
        if ! rmdir "${lock_dir}" 2>/dev/null || ! mkdir "${lock_dir}" 2>/dev/null; then
            log_err "Could not acquire session lock ${lock_dir}."
            return 1
        fi
    fi
    MACOS_LOCK_DIR="${lock_dir}"
    if ! printf '%s\n' "$$" > "${lock_dir}/pid"; then
        macos_release_lock
        log_err "Could not record owner for session lock ${lock_dir}."
        return 1
    fi
}

macos_release_lock() {
    if [[ -n "${MACOS_LOCK_DIR:-}" ]]; then
        rm -f "${MACOS_LOCK_DIR}/pid"
        rmdir "${MACOS_LOCK_DIR}" 2>/dev/null || true
        MACOS_LOCK_DIR=""
    fi
}

_macos_startup_cleanup() {
    local exit_code=$?
    if [[ "${exit_code}" -ne 0 ]]; then
        local pid
        local i
        for i in "${!PIDS_TCPDUMP[@]}"; do
            pid="${PIDS_TCPDUMP[$i]}"
            if macos_capture_process_matches "${pid}" "${IFACES_ARR[$i]}" "${PCAP_FILES[$i]}"; then
                kill -TERM "${pid}" 2>/dev/null || true
            fi
        done
        [[ -n "${state_tmp:-}" ]] && rm -f "${state_tmp}"
    fi
    macos_release_lock
    return "${exit_code}"
}

start_tap_macos() {
    macos_reject_unsupported_options
    require_root

    if [[ -z "${IFACE}" ]]; then
        log_err "Interface (-i <interface>) is required."
        exit 1
    fi
    if ! command -v tcpdump >/dev/null 2>&1; then
        log_err "Missing required dependency: tcpdump (install Wireshark or libpcap tools)."
        exit 1
    fi

    IFS=',' read -ra IFACES_ARR <<< "${IFACE}"
    for iface in "${IFACES_ARR[@]}"; do
        if ! ifconfig "${iface}" >/dev/null 2>&1; then
            log_err "Interface '${iface}' does not exist."
            exit 1
        fi
    done

    local state_file
    state_file="$(_macos_state_file)"
    mkdir -p "${STATE_DIR}" "${OUT_DIR}"
    chmod 755 "${STATE_DIR}"
    local lock_dir="${state_file}.lockdir"
    macos_acquire_lock "${lock_dir}" || exit 1
    local -a PIDS_TCPDUMP=() PCAP_FILES=() TCPDUMP_ERRS=()
    local state_tmp=""
    trap '_macos_startup_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ -f "${state_file}" ]]; then
        log_err "A net-tap capture session is already registered for ${IFACE}."
        exit 1
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local iface pcap_file error_file
    for iface in "${IFACES_ARR[@]}"; do
        pcap_file="${OUT_DIR}/${timestamp}_${iface}_trace.pcap"
        error_file="${OUT_DIR}/${timestamp}_${iface}_tcpdump.log"
        local -a tcpdump_cmd=(tcpdump -i "${iface}" -B 65536 -s 0 -C "${ROTATE_SIZE}" -W "${ROTATE_COUNT}" -w "${pcap_file}")
        if tcpdump --time-stamp-precision micro -h >/dev/null 2>&1; then
            tcpdump_cmd+=(--time-stamp-precision micro)
        fi
        if [[ "${COMPRESS_PCAPS}" -eq 1 ]]; then
            tcpdump_cmd+=(-z gzip)
        fi
        if [[ -n "${BPF_FILTER}" ]]; then
            tcpdump_cmd+=(-- "${BPF_FILTER}")
        fi

        nohup "${tcpdump_cmd[@]}" </dev/null >"${error_file}" 2>&1 &
        local pid=$!
        PIDS_TCPDUMP+=("${pid}")
        PCAP_FILES+=("${pcap_file}")
        TCPDUMP_ERRS+=("${error_file}")
        local attempts=0
        while (( attempts < 50 )); do
            if macos_capture_process_matches "${pid}" "${iface}" "${pcap_file}"; then
                break
            fi
            if ! kill -0 "${pid}" 2>/dev/null; then
                log_err "tcpdump failed to start on ${iface}. Check ${error_file}."
                exit 1
            fi
            sleep 0.1
            attempts=$((attempts + 1))
        done
        if ! macos_capture_process_matches "${pid}" "${iface}" "${pcap_file}"; then
            log_err "tcpdump did not become ready on ${iface}. Check ${error_file}."
            exit 1
        fi
    done

    MODE="passive"
    TIMESTAMP="${timestamp}"
    state_tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
    chmod 600 "${state_tmp}"
    {
        declare -p IFACE MODE TIMESTAMP OUT_DIR ROTATE_SIZE ROTATE_COUNT
        declare -p PIDS_TCPDUMP PCAP_FILES TCPDUMP_ERRS
    } > "${state_tmp}"
    if ! mv -f "${state_tmp}" "${state_file}"; then
        for pid in "${PIDS_TCPDUMP[@]}"; do
            kill -TERM "${pid}" 2>/dev/null || true
        done
        log_err "Could not write capture state file '${state_file}'."
        exit 1
    fi
    chmod 644 "${state_file}"

    trap - EXIT INT TERM HUP
    macos_release_lock
    log_warn "macOS capture is read-only with respect to interface configuration, but does not block host egress. It is not equivalent to Linux zero-egress mode."
    log_ok "Capture started on ${IFACE}; output: ${OUT_DIR}"
}

stop_tap_macos() {
    require_root
    macos_reject_unsupported_options
    if [[ -z "${IFACE}" ]]; then
        log_err "Interface (-i <interface>) is required."
        exit 1
    fi
    local state_file
    state_file="$(_macos_state_file)"
    local lock_dir="${state_file}.lockdir"
    macos_acquire_lock "${lock_dir}" || exit 1
    trap 'macos_release_lock' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ ! -f "${state_file}" ]]; then
        log_warn "No active net-tap capture session found for ${IFACE}."
        trap - EXIT INT TERM HUP
        macos_release_lock
        return 0
    fi
    if ! load_state_file "${state_file}"; then
        log_err "State file '${state_file}' failed security verification or is corrupted."
        exit 1
    fi
    local pid i
    IFS=',' read -ra IFACES_ARR <<< "${IFACE}"
    for i in "${!PIDS_TCPDUMP[@]}"; do
        pid="${PIDS_TCPDUMP[$i]}"
        if macos_capture_process_matches "${pid}" "${IFACES_ARR[$i]}" "${PCAP_FILES[$i]}"; then
            kill -TERM "${pid}" 2>/dev/null || true
            local attempts=0
            while macos_capture_process_matches "${pid}" "${IFACES_ARR[$i]}" "${PCAP_FILES[$i]}" && (( attempts < 50 )); do
                sleep 0.1
                attempts=$((attempts + 1))
            done
            if macos_capture_process_matches "${pid}" "${IFACES_ARR[$i]}" "${PCAP_FILES[$i]}"; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        else
            log_warn "Capture PID ${pid} no longer matches its recorded tcpdump command; refusing to signal it."
        fi
    done
    rm -f "${state_file}"
    trap - EXIT INT TERM HUP
    macos_release_lock
    log_ok "Capture stopped; PCAP files were flushed. macOS interface settings were not changed."
}

status_tap_macos() {
    verify_capture_dependencies
    macos_reject_unsupported_options
    if [[ -z "${IFACE}" ]]; then
        log_err "Interface (-i <interface>) is required."
        exit 1
    fi
    local iface state_file
    IFS=',' read -ra IFACES_ARR <<< "${IFACE}"
    for iface in "${IFACES_ARR[@]}"; do
        local port_info port_status operstate
        port_info="$(detect_port_status "${iface}")"
        IFS='|' read -r port_status _ _ operstate <<< "${port_info}"
        echo "Interface ${iface}: ${port_status} (state: ${operstate}; macOS link diagnostics are limited)"
    done
    state_file="$(_macos_state_file)"
    if [[ -f "${state_file}" ]] && load_state_file "${state_file}"; then
        local running=0 pid
        IFS=',' read -ra IFACES_ARR <<< "${IFACE}"
        local i
        for i in "${!PIDS_TCPDUMP[@]}"; do
            pid="${PIDS_TCPDUMP[$i]}"
            macos_capture_process_matches "${pid}" "${IFACES_ARR[$i]}" "${PCAP_FILES[$i]}" && running=$((running + 1))
        done
        echo "Capture: $([[ ${running} -gt 0 ]] && echo RUNNING || echo STOPPED) (${running} tcpdump process(es))"
        echo "Output directory: ${OUT_DIR}"
    else
        echo "Capture: not running"
    fi
}

list_sessions_macos() {
    local state_file
    local found=0
    local requested_iface="${IFACE:-}"
    local -a json_sessions=()
    macos_reject_unsupported_options
    if [[ ! -d "${STATE_DIR}" ]]; then
        if [[ "${JSON_OUT:-0}" -eq 1 ]]; then
            echo "[]"
        else
            echo "No active net-tap sessions found in ${STATE_DIR}."
        fi
        return 0
    fi
    for state_file in "${STATE_DIR}"/*.state; do
        [[ -f "${state_file}" ]] || continue
        IFACE=""
        MODE="passive"
        TIMESTAMP=""
        OUT_DIR=""
        PIDS_TCPDUMP=()
        if ! load_state_file "${state_file}"; then
            log_warn "Ignoring invalid state file '${state_file}'."
            continue
        fi
        [[ -n "${IFACE:-}" ]] || continue
        if [[ -n "${requested_iface}" && "${IFACE}" != "${requested_iface}" ]]; then
            continue
        fi
        local running=0 pid
        local -a session_ifaces=()
        IFS=',' read -ra session_ifaces <<< "${IFACE}"
        local i
        for i in "${!PIDS_TCPDUMP[@]}"; do
            pid="${PIDS_TCPDUMP[$i]}"
            macos_capture_process_matches "${pid}" "${session_ifaces[$i]}" "${PCAP_FILES[$i]}" && running=$((running + 1))
        done
        if [[ "${JSON_OUT:-0}" -eq 1 ]]; then
            local json_record
            json_record="$(python3 -c '
import json, sys
iface, mode, status, out_dir, timestamp, pid = sys.argv[1:]
print(json.dumps({"interface": iface, "mode": mode, "status": status,
                  "output_dir": out_dir, "timestamp": timestamp, "pid": int(pid)}))
' "${IFACE}" "${MODE:-passive}" "$([[ ${running} -gt 0 ]] && echo RUNNING || echo STOPPED)" \
                "${OUT_DIR}" "${TIMESTAMP}" "${PIDS_TCPDUMP[0]:-0}")"
            json_sessions+=("${json_record}")
        else
            printf 'Session: %s | %s | %s process(es) | %s\n' \
                "${IFACE}" "$([[ ${running} -gt 0 ]] && echo RUNNING || echo STOPPED)" "${running}" "${OUT_DIR}"
        fi
        found=$((found + 1))
    done
    if [[ "${JSON_OUT:-0}" -eq 1 ]]; then
        local IFS=','
        echo "[${json_sessions[*]}]"
    elif [[ ${found} -eq 0 ]]; then
        echo "No active net-tap sessions found in ${STATE_DIR}."
    fi
}
