#!/usr/bin/env bash
# Exit AI mode: closes the kiosk window and puts the normal desktop back
# (desktop effects, background apps, services), then frees the model's RAM.
# Options: --dry-run (show what would happen)
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/scripts/lib/common.sh"
load_config "$DIR"

for arg in "$@"; do
  case "$arg" in
    --dry-run) export DRY_RUN=1 ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cyberdeck"
SAVED="$STATE_DIR/ai-mode"
mkdir -p "$SAVED"
LOG="$STATE_DIR/ai-mode.log"
if [[ -t 1 ]]; then exec > >(tee -a "$LOG") 2>&1; else exec >> "$LOG" 2>&1; fi
echo "===== $(date '+%F %T') exit-ai-mode $*"

notify() {
  echo "$1${2:+: $2}"
  is_dry_run && return 0
  have notify-send && notify-send -a Cyberdeck -i "$DIR/assets/exit-ai-mode.svg" -t 4000 "$1" "${2:-}" 2>/dev/null || true
}

if [[ ! -f "$SAVED/active" && ! -s "$SAVED/gsettings" && ! -s "$SAVED/apps" ]]; then
  notify "AI mode is not on" "Nothing to undo"
fi
is_dry_run || rm -f "$SAVED/active"   # tells ai-mode.sh not to call us again

# 1. Close the kiosk window (whichever browser it was).
for pattern in "$DIR/scripts/kiosk.py" "$STATE_DIR/kiosk-chromium" "$STATE_DIR/kiosk-firefox"; do
  if pgrep -u "$(id -u)" -f -- "$pattern" >/dev/null 2>&1; then
    run pkill -u "$(id -u)" -f -- "$pattern"
  fi
done

# 2. Desktop settings back to how they were.
if [[ -s "$SAVED/gsettings" ]] && have gsettings; then
  while read -r schema key value; do
    [[ -n "$schema" ]] || continue
    run gsettings set "$schema" "$key" "$value" || warn "could not restore $schema $key"
  done < "$SAVED/gsettings"
  is_dry_run || rm -f "$SAVED/gsettings"
  ok "desktop settings restored"
fi

# 3. Background apps back on.
if [[ -s "$SAVED/apps" ]]; then
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    if ! pgrep -u "$(id -u)" -x "${cmd%% *}" >/dev/null 2>&1; then
      if is_dry_run; then run setsid -f sh -c "$cmd"; else setsid -f sh -c "$cmd" >/dev/null 2>&1 < /dev/null; fi
      ok "started $cmd"
    fi
  done < "$SAVED/apps"
  is_dry_run || rm -f "$SAVED/apps"
fi

# 4. System services back on.
helper="$DIR/scripts/ai-mode-root.sh"
if is_dry_run; then
  run sudo -n "$helper" exit
elif [[ "$(id -u)" -eq 0 ]]; then
  "$helper" exit
else
  sudo -n "$helper" exit || warn "could not restart system services (run ./install.sh again to fix the sudo rule)"
fi

# 5. Give the model's RAM back (it reloads automatically on the next question).
if [[ "$AI_MODE_UNLOAD_ON_EXIT" == "true" ]]; then
  if is_dry_run; then
    run curl -s "$OLLAMA_URL/api/generate" -d "{\"model\":\"$OLLAMA_MODEL\",\"keep_alive\":0}"
  else
    curl -s --max-time 30 "$OLLAMA_URL/api/generate" -d "{\"model\":\"$OLLAMA_MODEL\",\"keep_alive\":0}" >/dev/null 2>&1 || true
  fi
fi

notify "AI mode off" "Normal desktop is back"
