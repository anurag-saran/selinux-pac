#!/usr/bin/env bash
# training_lab_runner.sh — typewriter / section helpers for demo_present.sh and demo_e2e_*.sh
set -euo pipefail

TLAB_RED='\033[0;31m'
TLAB_GREEN='\033[0;32m'
TLAB_YELLOW='\033[1;33m'
TLAB_CYAN='\033[0;36m'
TLAB_BOLD='\033[1m'
TLAB_DIM='\033[2m'
TLAB_NC='\033[0m'

TLAB_TYPE_DELAY="${TLAB_TYPE_DELAY:-0.02}"
TLAB_NO_TYPE=0
TLAB_AUTO=0
TLAB_VM_PROJECT="${TLAB_VM_PROJECT:-${PROJECT_ROOT:-.}}"

tlab_print_section() {
    echo
    echo -e "${TLAB_BOLD}${TLAB_CYAN}════════════════════════════════════════════════════════════${TLAB_NC}"
    echo -e "${TLAB_BOLD}${TLAB_CYAN}  $*${TLAB_NC}"
    echo -e "${TLAB_BOLD}${TLAB_CYAN}════════════════════════════════════════════════════════════${TLAB_NC}"
    echo
}

tlab_why() {
    echo -e "${TLAB_YELLOW}Why:${TLAB_NC} $*"
    echo
}

tlab_question() {
    echo -e "${TLAB_DIM}Question:${TLAB_NC} $*"
    echo
}

tlab_explain() {
    echo -e "${TLAB_DIM}What this does:${TLAB_NC} $*"
    echo
}

tlab_lab_only_banner() {
    echo
    echo -e "${TLAB_RED}${TLAB_BOLD}LAB ONLY${TLAB_NC}${TLAB_RED} — $*${TLAB_NC}"
    echo
}

tlab_checkpoint() {
    echo -e "${TLAB_GREEN}Checkpoint:${TLAB_NC} $*"
    echo
}

tlab_pause() {
    if [[ "${TLAB_AUTO}" -eq 1 ]]; then
        return 0
    fi
    read -r -p "$(echo -e "${TLAB_DIM}Press Enter for the next step…${TLAB_NC} ")" _
}

tlab_pause_lab() {
    if [[ "${TLAB_AUTO}" -eq 1 ]]; then
        return 0
    fi
    echo
    read -r -p "$(echo -e "${TLAB_BOLD}Press Enter to start the next lab…${TLAB_NC} ")" _
}

tlab_type_line() {
    local prompt="$1"
    local ps1="${TLAB_PS1:-\$}"
    if [[ "${TLAB_NO_TYPE}" -eq 1 ]]; then
        echo -e "${TLAB_GREEN}${ps1}${TLAB_NC} ${prompt}"
        return 0
    fi
    echo -n -e "${TLAB_GREEN}${ps1}${TLAB_NC} "
    local i c
    for ((i = 0; i < ${#prompt}; i++)); do
        c="${prompt:i:1}"
        echo -n "${c}"
        sleep "${TLAB_TYPE_DELAY}"
    done
    echo
}

tlab_run_shell() {
    local script="$1"
    bash -lc "${script}"
}

tlab_run_cmd() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    tlab_run_shell "${cmd}"
}

tlab_run_cmd_sudo() {
    local cmd="$1"
    tlab_type_line "sudo ${cmd#sudo }"
    sudo bash -lc "${cmd}"
}

tlab_detect_vm() {
    if ! command -v getenforce >/dev/null 2>&1; then
        return 1
    fi
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    [[ "${mode}" != "Disabled" ]]
}
