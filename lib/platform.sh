#!/usr/bin/env bash
# shellcheck shell=bash

NET_TAP_OS="${NET_TAP_OS:-$(uname -s)}"

stat_value() {
    local format="$1" path="$2"
    python3 -c '
import os, stat, sys
info = os.stat(sys.argv[2])
fields = {"%u": info.st_uid, "%a": format(stat.S_IMODE(info.st_mode), "o"), "%h": info.st_nlink}
print(fields[sys.argv[1]])
' "${format}" "${path}"
}

canonical_path() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

canonical_path_allow_missing() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

process_comm() {
    local pid="$1"
    if [[ "${NET_TAP_OS}" == "Linux" ]]; then
        cat "/proc/${pid}/comm" 2>/dev/null
    else
        ps -p "${pid}" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    fi
}

process_command() {
    local pid="$1"
    if [[ "${NET_TAP_OS}" == "Linux" ]]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null
    else
        ps -ww -p "${pid}" -o command= 2>/dev/null
    fi
}

process_matches() {
    local pid="$1" expected_comm="$2" expected_cmd="${3:-}"
    local actual_comm actual_cmd

    kill -0 "${pid}" 2>/dev/null || return 1
    actual_comm="$(process_comm "${pid}")" || return 1
    [[ "${actual_comm}" =~ ^(${expected_comm})$ ]] || return 1
    if [[ -n "${expected_cmd}" ]]; then
        actual_cmd="$(process_command "${pid}")" || return 1
        [[ "${actual_cmd}" =~ ${expected_cmd} ]] || return 1
    fi
}

find_files_in_dir() {
    local directory="$1"
    shift
    local file pattern name
    for file in "${directory}"/*; do
        [[ -f "${file}" ]] || continue
        name="${file##*/}"
        for pattern in "$@"; do
            # shellcheck disable=SC2053
            if [[ "${name}" == ${pattern} ]]; then
                printf '%s\0' "${file}"
                break
            fi
        done
    done
}
