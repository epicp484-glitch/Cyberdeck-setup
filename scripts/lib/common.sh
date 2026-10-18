# shellcheck shell=bash
# Shared helpers for the cyberdeck scripts. Source this file, don't run it.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_RESET=$'\e[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_RESET=""
fi

DRY_RUN="${DRY_RUN:-0}"
CURRENT_STEP="${CURRENT_STEP:-starting}"

step() {  # step <number> <total> <title>
  CURRENT_STEP="$3"
  printf '\n%s[%s/%s] %s%s\n' "${C_BOLD}${C_BLUE}" "$1" "$2" "$3" "${C_RESET}"
}
info() { printf '  %s→%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()   { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
skip() { printf '  %s✓ %s (already done)%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
warn() { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die() {
  printf '\n%s✗ ERROR:%s %s\n' "${C_BOLD}${C_RED}" "${C_RESET}" "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Running commands (respects --dry-run)
# ---------------------------------------------------------------------------
is_dry_run() { [[ "${DRY_RUN}" == "1" ]]; }

# Print a command the way you would type it.
quote_cmd() {
  local out="" arg
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$arg "; else out+="$(printf '%q' "$arg") "; fi
  done
  printf '%s' "${out% }"
}

# run <cmd...>: run a command that changes the system (printed only in dry-run).
run() {
  if is_dry_run; then
    printf '  %s[dry-run]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(quote_cmd "$@")"
    return 0
  fi
  "$@"
}

# as_root <cmd...>: like run, but with sudo when we are not root.
as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then run "$@"; else run sudo "$@"; fi
}

# root <cmd...>: read-only command that needs root (runs even in dry-run).
root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# as_user <user> <cmd...>: run a command as the desktop user.
as_user() {
  local user="$1"; shift
  if [[ "$(id -un)" == "$user" ]]; then run "$@"; else run sudo -u "$user" -H "$@"; fi
}

# write_file <dest> <mode> [owner[:group]] < content
# Writes stdin to <dest> (with sudo) only if it differs from what is there.
# Returns 0 if the file was (or in dry-run would be) changed, 1 if unchanged.
write_file() {
  local dest="$1" mode="$2" owner="${3:-root:root}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if root test -f "$dest" && root cmp -s "$tmp" "$dest"; then
    # Content is the same; still fix permissions quietly.
    if ! is_dry_run; then root chmod "$mode" "$dest"; root chown "$owner" "$dest"; fi
    rm -f "$tmp"
    return 1
  fi
  if is_dry_run; then
    printf '  %s[dry-run]%s write %s (mode %s, owner %s, %s lines)\n' \
      "${C_YELLOW}" "${C_RESET}" "$dest" "$mode" "$owner" "$(wc -l < "$tmp")"
    rm -f "$tmp"
    return 0
  fi
  root mkdir -p "$(dirname "$dest")"
  root install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# load_config <dir containing config.env>
load_config() {
  local dir="$1"
  [[ -f "$dir/config.env" ]] || die "config.env not found in $dir"
  # shellcheck source=/dev/null
  source "$dir/config.env"
  if [[ -f "$dir/config.local.env" ]]; then
    # shellcheck source=/dev/null
    source "$dir/config.local.env"
  fi
  if [[ -n "${CYBERDECK_CONFIG:-}" ]]; then
    [[ -f "$CYBERDECK_CONFIG" ]] || die "CYBERDECK_CONFIG points to a missing file: $CYBERDECK_CONFIG"
    # shellcheck source=/dev/null
    source "$CYBERDECK_CONFIG"
  fi
  OLLAMA_URL="http://127.0.0.1:${OLLAMA_PORT}"
  OPEN_WEBUI_URL="http://127.0.0.1:${OPEN_WEBUI_PORT}"
  KIWIX_URL="http://127.0.0.1:${KIWIX_PORT}"
  export OLLAMA_URL OPEN_WEBUI_URL KIWIX_URL
}

# The desktop user everything is set up for.
detect_user() {
  if [[ -n "${CYBERDECK_USER:-}" ]]; then
    echo "$CYBERDECK_USER"
  elif [[ "$(id -u)" -ne 0 ]]; then
    id -un
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  else
    echo root
  fi
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# ---------------------------------------------------------------------------
# Small checks
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

http_ok() { curl -fsS -o /dev/null --max-time "${2:-5}" "$1" 2>/dev/null; }

# wait_for_url <url> <seconds> <name>
wait_for_url() {
  local url="$1" timeout="$2" name="$3" waited=0
  is_dry_run && { info "would wait for $name at $url"; return 0; }
  until http_ok "$url"; do
    if (( waited >= timeout )); then
      return 1
    fi
    if (( waited > 0 && waited % 30 == 0 )); then info "still waiting for $name (${waited}s)..."; fi
    sleep 2
    waited=$((waited + 2))
  done
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

systemd_running() { [[ -d /run/systemd/system ]]; }
