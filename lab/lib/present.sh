#!/usr/bin/env bash
# lab/lib/present.sh — step runner for 301 and 302 talk scripts
# Source after training_lab_runner.sh (needs TLAB_* variables, E2E_DRY).

PRESENT_STEP="${PRESENT_STEP:-1}"

# One caption line above a command, shown as a shell comment.
say() {
    echo -e "${TLAB_DIM}# $*${TLAB_NC}"
}

# Type the command and leave the cursor at the end of the line.
present_type() {
    local cmd="$1" i
    echo -n -e "${TLAB_GREEN}${TLAB_PS1}${TLAB_NC}"
    if [[ "${TLAB_NO_TYPE}" -eq 1 ]]; then
        printf '%s' "${cmd}"
        return 0
    fi
    for ((i = 0; i < ${#cmd}; i++)); do
        printf '%s' "${cmd:i:1}"
        sleep "${TLAB_TYPE_DELAY}"
    done
}

# Wait for Enter. Keys are not echoed, so a stray key cannot garble the line.
present_wait() {
    if [[ "${TLAB_AUTO}" -eq 0 && "${PRESENT_STEP}" -eq 1 ]]; then
        read -r -s _ || true
    fi
    echo
}

# present_cmd COMMAND [run|fail] [DRY_RUN_SAMPLE]
#   run   A non-zero exit is shown in yellow and the talk keeps going.
#   fail  The step is meant to be refused. Exit 0 is the surprise.
# --dry-run prints DRY_RUN_SAMPLE (what a good screen shows) instead of running.
present_cmd() {
    local cmd="$1" mode="${2:-run}" sample="${3:-}" rc
    present_type "${cmd}"
    present_wait
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run)${sample:+ ${sample}}${TLAB_NC}"
        echo
        return 0
    fi
    set +e
    eval "${cmd}"
    rc=$?
    set -e
    echo
    if [[ "${mode}" == "fail" ]]; then
        if [[ "${rc}" -ne 0 ]]; then
            echo -e "${TLAB_YELLOW}exit ${rc}: blocked on purpose${TLAB_NC}"
        else
            echo -e "${TLAB_RED}exit 0: this step should have been blocked${TLAB_NC}"
        fi
        echo
    elif [[ "${rc}" -ne 0 ]]; then
        echo -e "${TLAB_YELLOW}exit ${rc}${TLAB_NC}"
        echo
    fi
    return 0
}
