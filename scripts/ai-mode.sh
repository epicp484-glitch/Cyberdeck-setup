#!/usr/bin/env bash
# AI mode: one click turns the deck into a dedicated offline AI machine.
#
#  1. switches off desktop effects / screen blanking (saving the old values)
#  2. closes other windows and stops background apps and services
#  3. makes sure Ollama, Open WebUI and Kiwix run, and preloads the model
#  4. opens Open WebUI fullscreen in a lightweight kiosk window
#
# Leave with Ctrl+Q in the AI window, the "Exit AI Mode" icon, or exit-ai-mode.
# Options: --dry-run (show what would happen), --no-kiosk (don't open the window)
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/scripts/lib/common.sh"
load_config "$DIR"

OPEN_KIOSK=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) export DRY_RUN=1 ;;
    --no-kiosk) OPEN_KIOSK=0 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cyberdeck"
SAVED="$STATE_DIR/ai-mode"      # saved desktop state lives here while AI mode is on
mkdir -p "$SAVED"
LOG="$STATE_DIR/ai-mode.log"
if [[ -t 1 ]]; then exec > >(tee -a "$LOG") 2>&1; else exec >> "$LOG" 2>&1; fi
echo "===== $(date '+%F %T') ai-mode $*"

notify() {
  echo "$1${2:+: $2}"
  is_dry_run && return 0
  have notify-send && notify-send -a Cyberdeck -i "$DIR/assets/ai-mode.svg" -t 4000 "$1" "${2:-}" 2>/dev/null || true
}

# Only one AI mode start at a time (held while the kiosk window is open).
exec 9> "$STATE_DIR/ai-mode.lock"
if ! flock -n 9; then
  notify "AI mode is already on"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Desktop settings
# ---------------------------------------------------------------------------
GSETTINGS=("${AI_MODE_GSETTINGS[@]}")
if [[ "$AI_MODE_NO_SCREEN_BLANK" == "true" ]]; then
  GSETTINGS+=(
    "org.cinnamon.desktop.session idle-delay uint32 0"
    "org.cinnamon.desktop.screensaver idle-activation-enabled false"
    "org.cinnamon.desktop.screensaver lock-enabled false"
    "org.cinnamon.settings-daemon.plugins.power sleep-display-ac 0"
    "org.cinnamon.settings-daemon.plugins.power sleep-display-battery 0"
    "org.cinnamon.settings-daemon.plugins.power sleep-inactive-ac-timeout 0"
    "org.cinnamon.settings-daemon.plugins.power sleep-inactive-battery-timeout 0"
  )
fi

apply_gsettings() {
  have gsettings || { warn "gsettings not found; skipping desktop settings"; return; }
  local entry schema key value old
  for entry in "${GSETTINGS[@]}"; do
    read -r schema key value <<< "$entry"
    # Skip keys this Cinnamon version doesn't have.
    old="$(gsettings get "$schema" "$key" 2>/dev/null)" || continue
    # Remember the original value only once, so pressing AI mode twice can't lose it.
    if ! grep -q "^$schema $key " "$SAVED/gsettings" 2>/dev/null; then
      is_dry_run || echo "$schema $key $old" >> "$SAVED/gsettings"
    fi
    run gsettings set "$schema" "$key" "$value" || warn "could not set $schema $key"
  done
}

# ---------------------------------------------------------------------------
# 2. Windows, apps, services
# ---------------------------------------------------------------------------
ancestors() {  # PIDs of this script and its parents (e.g. the terminal it runs in)
  local pid=$$
  while [[ "$pid" -gt 1 ]]; do
    echo "$pid"
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)" || break
  done
}

tidy_windows() {
  [[ "$AI_MODE_WINDOWS" == "none" ]] && return
  [[ -n "${DISPLAY:-}" ]] && have wmctrl || { warn "no X display or wmctrl; leaving windows alone"; return; }
  local keep id pid type count=0
  keep=" $(ancestors | tr '\n' ' ') $(pgrep -x cinnamon | tr '\n' ' ') $(pgrep -x nemo-desktop | tr '\n' ' ') "
  while read -r id _desk pid _rest; do
    [[ -n "$id" ]] || continue
    [[ "$keep" == *" $pid "* ]] && continue
    type="$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)"
    [[ "$type" == *DESKTOP* || "$type" == *DOCK* ]] && continue
    if [[ "$AI_MODE_WINDOWS" == "minimize" ]]; then
      run wmctrl -i -r "$id" -b add,hidden
    else
      run wmctrl -i -c "$id"   # polite close, like clicking X (apps can still ask to save)
    fi
    count=$((count + 1))
  done < <(wmctrl -l -p 2>/dev/null)
  if (( count > 0 )); then
    if [[ "$AI_MODE_WINDOWS" == "minimize" ]]; then ok "minimized $count window(s)"; else ok "closed $count window(s)"; fi
  fi
}

stop_apps() {
  local entry name restart
  for entry in "${AI_MODE_STOP_APPS[@]}"; do
    name="${entry%%|*}"
    restart="${entry#*|}"
    [[ "$entry" == *"|"* ]] || restart=""
    if pgrep -u "$(id -u)" -x "$name" >/dev/null 2>&1; then
      run pkill -u "$(id -u)" -x "$name"
      if [[ -n "$restart" ]] && ! is_dry_run; then
        grep -qxF "$restart" "$SAVED/apps" 2>/dev/null || echo "$restart" >> "$SAVED/apps"
      fi
      ok "stopped $name"
    fi
  done
}

root_helper() {
  local helper="$DIR/scripts/ai-mode-root.sh"
  if is_dry_run; then
    run sudo -n "$helper" "$1"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$helper" "$1"
  elif ! sudo -n "$helper" "$1"; then
    warn "could not run the system part of AI mode (run ./install.sh again to fix the sudo rule)"
  fi
}

# ---------------------------------------------------------------------------
# 3. Services + model
# ---------------------------------------------------------------------------
wait_services() {
  wait_for_url "$OLLAMA_URL/api/version" 60 "Ollama" || { notify "AI mode problem" "Ollama is not running (systemctl status ollama)"; return 1; }
  wait_for_url "$KIWIX_URL/" 30 "Kiwix" || notify "AI mode warning" "Offline Wikipedia (Kiwix) is not running"
  wait_for_url "$OPEN_WEBUI_URL/health" 240 "Open WebUI" || { notify "AI mode problem" "Open WebUI did not start (docker logs open-webui)"; return 1; }
}

preload_model() {
  local keep="$AI_MODE_KEEP_ALIVE"
  [[ "$keep" =~ ^-?[0-9]+$ ]] || keep="\"$keep\""
  if is_dry_run; then
    run curl -s "$OLLAMA_URL/api/generate" -d "{\"model\":\"$OLLAMA_MODEL\",\"keep_alive\":$keep}"
    return
  fi
  # An empty prompt just loads the model into RAM. Runs in the background so the window opens right away.
  ( curl -s --max-time 600 "$OLLAMA_URL/api/generate" -d "{\"model\":\"$OLLAMA_MODEL\",\"keep_alive\":$keep}" >/dev/null \
      && echo "model $OLLAMA_MODEL loaded" || echo "model preload failed" ) &
}

# ---------------------------------------------------------------------------
# 4. Kiosk window
# ---------------------------------------------------------------------------
pick_browser() {
  local want="$AI_MODE_BROWSER"
  if [[ "$want" == "auto" || "$want" == "webkit" ]]; then
    if python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.1")' 2>/dev/null; then
      echo webkit; return
    fi
    [[ "$want" == "webkit" ]] && warn "WebKitGTK is not installed; trying other browsers"
  fi
  for b in chromium chromium-browser google-chrome firefox; do
    if [[ "$want" == "auto" || "$want" == "webkit" || "$b" == "$want"* ]] && have "$b"; then echo "$b"; return; fi
  done
  echo none
}

run_kiosk() {
  local url="$OPEN_WEBUI_URL" browser
  browser="$(pick_browser)"
  info "kiosk browser: $browser"
  case "$browser" in
    webkit)
      run python3 "$DIR/scripts/kiosk.py" --zoom "$AI_MODE_ZOOM" --data-dir "$STATE_DIR/kiosk-webkit" "$url" ;;
    chromium|chromium-browser|google-chrome)
      run "$browser" --kiosk --app="$url" --user-data-dir="$STATE_DIR/kiosk-chromium" --class=cyberdeck-kiosk \
        --no-first-run --noerrdialogs --disable-session-crashed-bubble --disable-sync --disable-translate \
        --disable-background-networking --disable-component-update --disable-features=Translate,MediaRouter \
        --force-device-scale-factor="$AI_MODE_ZOOM" ;;
    firefox)
      mkdir -p "$STATE_DIR/kiosk-firefox"
      run firefox --kiosk --new-instance --profile "$STATE_DIR/kiosk-firefox" --name cyberdeck-kiosk "$url" ;;
    *)
      notify "AI mode" "No browser found. Open $url yourself."
      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
main() {
  if [[ -f "$SAVED/active" ]]; then
    info "AI mode was already on; reopening the AI window"
  else
    notify "Starting AI mode…" "Closing other apps and loading the AI"
    apply_gsettings
    tidy_windows
    stop_apps
    root_helper enter
    is_dry_run || date '+%F %T' > "$SAVED/active"
  fi
  wait_services || exit 1
  preload_model
  ok "AI mode is on"
  (( OPEN_KIOSK )) || exit 0

  run_kiosk
  # Window closed: go back to the normal desktop (unless exit-ai-mode already did).
  if [[ "$AI_MODE_EXIT_ON_CLOSE" == "true" && -f "$SAVED/active" ]] && ! is_dry_run; then
    flock -u 9
    exec "$DIR/scripts/exit-ai-mode.sh"
  fi
}

main
