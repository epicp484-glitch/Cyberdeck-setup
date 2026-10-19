#!/usr/bin/env bash
# Root half of AI mode: stops the background services listed in config.env and
# makes sure the AI services are running. ai-mode.sh / exit-ai-mode.sh call it
# through sudo (install.sh adds a sudo rule for exactly this file).
#
#   ai-mode-root.sh enter | exit | status
#
# It only reads the root-owned copy of the config in its own install folder.
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/scripts/lib/common.sh"
unset CYBERDECK_CONFIG
load_config "$DIR"

STATE_DIR=/run/cyberdeck
STOPPED="$STATE_DIR/stopped-services"

[[ "$(id -u)" -eq 0 ]] || die "ai-mode-root.sh must run as root (use sudo)."

enter() {
  mkdir -p "$STATE_DIR"
  touch "$STOPPED"
  local svc
  for svc in "${AI_MODE_STOP_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      if run timeout 30 systemctl stop "$svc"; then
        grep -qxF "$svc" "$STOPPED" || echo "$svc" >> "$STOPPED"
        ok "stopped $svc"
      else
        warn "could not stop $svc"
      fi
    fi
  done

  for svc in docker.service ollama.service cyberdeck-kiwix.service; do
    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
      run systemctl start "$svc" && ok "started $svc" || warn "could not start $svc"
    fi
  done
  if [[ "$(docker inspect -f '{{.State.Running}}' open-webui 2>/dev/null)" != "true" ]]; then
    run docker start open-webui >/dev/null && ok "started open-webui" || warn "could not start open-webui"
  fi
}

leave() {
  [[ -f "$STOPPED" ]] || return 0
  local svc
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    run systemctl start "$svc" && ok "started $svc again" || warn "could not start $svc"
  done < "$STOPPED"
  is_dry_run || rm -f "$STOPPED"
}

status() {
  local svc
  for svc in ollama.service cyberdeck-kiwix.service docker.service; do
    printf '%-26s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null)"
  done
  printf '%-26s %s\n' "open-webui (container)" "$(docker inspect -f '{{.State.Status}}' open-webui 2>/dev/null || echo missing)"
  if [[ -s "$STOPPED" ]]; then
    echo "stopped for AI mode: $(tr '\n' ' ' < "$STOPPED")"
  fi
}

case "${1:-}" in
  enter) enter ;;
  exit) leave ;;
  status) status ;;
  *) echo "usage: $0 enter|exit|status" >&2; exit 2 ;;
esac
