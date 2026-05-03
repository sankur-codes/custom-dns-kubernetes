#!/usr/bin/env bash
# common.sh — Shared utility functions for custom DNS demo scripts.
# Source this file; do not execute directly.

# ── Colors ───────────────────────────────────────────────────────────
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_BLUE='\033[0;34m'
_BOLD='\033[1m'
_RESET='\033[0m'

# ── Display ──────────────────────────────────────────────────────────

info()    { echo -e "${_BLUE}[INFO]${_RESET}  $*"; }
success() { echo -e "${_GREEN}[OK]${_RESET}    $*"; }
warn()    { echo -e "${_YELLOW}[WARN]${_RESET}  $*"; }

error() {
    echo -e "${_RED}[ERROR]${_RESET} $*" >&2
    exit 1
}

header() {
    echo ""
    echo -e "${_BOLD}════════════════════════════════════════════${_RESET}"
    echo -e "${_BOLD}  $*${_RESET}"
    echo -e "${_BOLD}════════════════════════════════════════════${_RESET}"
    echo ""
}

# ── Interactive ──────────────────────────────────────────────────────

# confirm "Are you sure?" — returns 0 (yes) or 1 (no). Default: No.
confirm() {
    local prompt="${1:-Continue?}"
    local reply
    echo -en "${_YELLOW}${prompt} [y/N]:${_RESET} "
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Config helpers ──────────────────────────────────────────────────

# load_project_config — source the central config.env file.
load_project_config() {
    local config="${REPO_DIR}/config.env"
    if [ ! -f "$config" ]; then
        error "config.env not found. Create it from the defaults or copy config.env.example."
    fi
    # shellcheck disable=SC1090
    source "$config"
}

# load_config FILE — source a key=value config file if it exists.
load_config() {
    local file="$1"
    if [ -f "$file" ]; then
        # shellcheck disable=SC1090
        source "$file"
        return 0
    fi
    return 1
}

# save_config FILE VAR1 VAR2 ... — write named variables to a file.
save_config() {
    local file="$1"; shift
    : > "$file"
    for var in "$@"; do
        echo "${var}=${!var}" >> "$file"
    done
}

# ── SSH helpers (for Azure scripts) ──────────────────────────────────

# ssh_exec HOST COMMAND...
ssh_exec() {
    local host="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY_PATH}" "${SSH_USER:-azureuser}@${host}" "$@"
}

# ssh_copy LOCAL_FILE HOST REMOTE_PATH
ssh_copy() {
    local src="$1" host="$2" dest="$3"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY_PATH}" "$src" "${SSH_USER:-azureuser}@${host}:${dest}"
}
