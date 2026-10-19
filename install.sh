#!/usr/bin/env bash
# =============================================================================
#  Cyberdeck installer — rebuilds the whole offline AI setup from scratch.
#
#    ./install.sh                  install / update everything (safe to re-run)
#    ./install.sh --dry-run        show every step without changing anything
#    ./install.sh --offline-check  test that everything works with no internet
#
#  All settings are in config.env.
# =============================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

usage() {
  cat <<EOF
Cyberdeck installer

Usage: ./install.sh [option]

  (no option)       Install or update everything. Safe to run again: finished
                    steps are skipped.
  --dry-run         Print every step and command without changing anything.
  --offline-check   Check that Ollama, Open WebUI, Kiwix and the Wikipedia
                    tool all work without internet.
  -h, --help        Show this help.

Settings: $REPO_DIR/config.env (personal overrides: config.local.env)
EOF
}

MODE="install"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --offline-check) MODE="offline-check" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $arg" ;;
  esac
done
export DRY_RUN

load_config "$REPO_DIR"

if [[ "$MODE" == "offline-check" ]]; then
  exec bash "$REPO_DIR/scripts/offline-check.sh"
fi

TARGET_USER="$(detect_user)"
TARGET_HOME="$(user_home "$TARGET_USER")"
[[ -n "$TARGET_HOME" ]] || die "User '$TARGET_USER' does not exist (check CYBERDECK_USER in config.env)."
TOTAL_STEPS=11

# ---------------------------------------------------------------------------
# Logging and error handling
# ---------------------------------------------------------------------------
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cyberdeck"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install.log"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n===== %s  install.sh %s =====\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"

on_error() {
  local code=$? line=$1 cmd=$2
  printf '\n%s✗ FAILED during step: %s%s\n' "${C_BOLD}${C_RED}" "$CURRENT_STEP" "${C_RESET}" >&2
  printf '  Command : %s\n  Where   : install.sh line %s (exit code %s)\n' "$cmd" "$line" "$code" >&2
  printf '  Full log: %s\n' "$LOG_FILE" >&2
  printf '  Fix the problem above and run ./install.sh again — finished steps are skipped.\n' >&2
  exit "$code"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# docker as root (works before the user's docker group membership is active)
docker_root() { as_root docker "$@"; }
docker_ro() { if is_dry_run && [[ "$(id -u)" -ne 0 ]]; then docker "$@" 2>/dev/null; else root docker "$@"; fi; }
compose() {
  docker_root compose --project-name cyberdeck \
    --file "$INSTALL_DIR/docker/docker-compose.yml" \
    --env-file "$INSTALL_DIR/docker/.env" "$@"
}

apt_install() {
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# systemd_apply <unit> <changed:0|1>: reload + (re)start a unit only when needed.
systemd_apply() {
  local unit="$1" changed="$2"
  if [[ "$changed" == "1" ]]; then
    as_root systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    as_root systemctl enable "$unit"
  fi
  if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
    as_root systemctl start "$unit"
  elif [[ "$changed" == "1" ]]; then
    as_root systemctl restart "$unit"
  fi
}

# user_read <cmd...>: run a harmless command as the desktop user (also in dry-run).
user_read() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then "$@"; else sudo -u "$TARGET_USER" -H "$@"; fi
}

# Model names without a tag mean ":latest" to Ollama.
full_model_name() { if [[ "$1" == *:* ]]; then echo "$1"; else echo "$1:latest"; fi; }

# ===========================================================================
# 1. Preflight
# ===========================================================================
step_preflight() {
  step 1 "$TOTAL_STEPS" "Checking this computer"
  is_dry_run && info "DRY RUN: nothing will be changed. Commands are printed instead."

  [[ "$(uname -m)" == "x86_64" ]] || die "This setup is for x86_64 computers (found $(uname -m))."
  [[ -r /etc/os-release ]] || die "Can't read /etc/os-release — is this Linux Mint?"
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_NAME="${PRETTY_NAME:-unknown}"
  UBUNTU_BASE="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  if [[ "${ID:-}" != "linuxmint" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* ]]; then
    die "This setup is written for Linux Mint (Ubuntu based). Found: $OS_NAME"
  fi
  [[ -n "$UBUNTU_BASE" ]] || die "Can't tell which Ubuntu release this is based on (UBUNTU_CODENAME missing)."
  ok "System: $OS_NAME (Ubuntu base: $UBUNTU_BASE), $(nproc) CPU cores, $(free -g | awk '/^Mem:/{print $2}') GB RAM"
  ok "Desktop user: $TARGET_USER ($TARGET_HOME)"

  if ! systemd_running; then
    is_dry_run && warn "systemd is not running here (fine for a dry run)." \
      || die "systemd is not running. This installer needs a normal Linux Mint system."
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    have sudo || die "sudo is not installed."
    if ! is_dry_run; then
      info "Asking for your password once (needed to install software)..."
      sudo -v || die "sudo failed — your user needs to be an administrator."
      # Keep sudo alive for the whole install.
      ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    fi
  fi

  local probe="$INSTALL_DIR" free_gb
  while [[ ! -d "$probe" ]]; do probe="$(dirname "$probe")"; done
  free_gb=$(df -BG --output=avail "$probe" | tail -1 | tr -dc '0-9')
  if (( free_gb < 25 )); then
    warn "Only ${free_gb} GB free on $(df --output=target "$probe" | tail -1). The model + Wikipedia need ~20 GB."
  else
    ok "Free disk space: ${free_gb} GB"
  fi

  if curl -fsS -o /dev/null --max-time 10 https://download.docker.com/ 2>/dev/null \
     || curl -fsS -o /dev/null --max-time 10 http://archive.ubuntu.com/ubuntu/ 2>/dev/null; then
    ok "Internet is reachable"
  else
    warn "No internet. Steps that are already done will be skipped; downloads will fail."
  fi
}

# ===========================================================================
# 2. System packages
# ===========================================================================
REQUIRED_PKGS=(git curl ca-certificates gnupg python3 python3-pip python3-venv kiwix-tools zstd
               wmctrl x11-utils libnotify-bin)
OPTIONAL_PKGS=(python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1)  # tiny kiosk browser window

step_packages() {
  step 2 "$TOTAL_STEPS" "System packages (git, curl, Python 3, pip/venv, Kiwix tools)"
  local missing=() optional=() p
  for p in "${REQUIRED_PKGS[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  for p in "${OPTIONAL_PKGS[@]}"; do pkg_installed "$p" || optional+=("$p"); done

  local stamp=/var/lib/apt/periodic/update-success-stamp fresh=0
  [[ -f /var/cache/apt/pkgcache.bin ]] && stamp=/var/cache/apt/pkgcache.bin
  if [[ -f "$stamp" ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 6 * 3600 )); then fresh=1; fi

  if (( ${#missing[@]} + ${#optional[@]} > 0 )) || [[ "$SYSTEM_UPGRADE" == "true" && "$fresh" == "0" ]]; then
    info "Updating package lists..."
    if ! as_root apt-get update -q; then
      (( ${#missing[@]} == 0 )) || die "apt-get update failed — check the internet connection."
      warn "apt-get update failed (offline?). Packages are already installed, continuing."
    fi
  else
    skip "Package lists are fresh"
  fi

  if [[ "$SYSTEM_UPGRADE" == "true" ]]; then
    if [[ "$fresh" == "1" && ${#missing[@]} -eq 0 ]]; then
      skip "System upgraded in the last 6 hours"
    else
      info "Upgrading installed packages (can take a while the first time)..."
      as_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        || warn "apt-get upgrade failed — continuing with the current packages."
    fi
  fi

  if (( ${#missing[@]} > 0 )); then
    info "Installing: ${missing[*]}"
    apt_install "${missing[@]}"
    ok "Installed required packages"
  else
    skip "Required packages are installed"
  fi

  if (( ${#optional[@]} > 0 )); then
    local available=()
    for p in "${optional[@]}"; do
      apt-cache show "$p" >/dev/null 2>&1 && available+=("$p")
    done
    if (( ${#available[@]} > 0 )); then
      info "Installing kiosk browser parts: ${available[*]}"
      apt_install "${available[@]}" || warn "Could not install ${available[*]}; AI mode will use Chromium/Firefox."
    fi
    (( ${#available[@]} == ${#optional[@]} )) \
      || warn "WebKitGTK not available on this release; AI mode will use Chromium or Firefox."
  else
    skip "Kiosk browser parts are installed"
  fi
}

# ===========================================================================
# 3. Cyberdeck files
# ===========================================================================
step_files() {
  step 3 "$TOTAL_STEPS" "Cyberdeck scripts and tools -> $INSTALL_DIR"
  local changed=0 f rel mode
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_DIR"/}"
    mode=644
    [[ -x "$f" ]] && mode=755
    if write_file "$INSTALL_DIR/$rel" "$mode" < "$f"; then changed=$((changed + 1)); fi
  done < <(find "$REPO_DIR/scripts" "$REPO_DIR/tools" "$REPO_DIR/docker" "$REPO_DIR/assets" \
             -type f ! -name '*.pyc' ! -path '*/__pycache__/*' ! -name '.env' -print0 | sort -z)
  for f in config.env config.local.env; do
    if [[ -f "$REPO_DIR/$f" ]]; then
      if write_file "$INSTALL_DIR/$f" 644 < "$REPO_DIR/$f"; then changed=$((changed + 1)); fi
    elif [[ -f "$INSTALL_DIR/$f" ]]; then
      as_root rm -f "$INSTALL_DIR/$f"; changed=$((changed + 1))
    fi
  done
  if (( changed > 0 )); then ok "Copied $changed changed file(s)"; else skip "Files are up to date"; fi

  local link target
  for link in wiki-ask:tools/wiki_ask.py ai-mode:scripts/ai-mode.sh exit-ai-mode:scripts/exit-ai-mode.sh \
              cyberdeck-offline-check:scripts/offline-check.sh; do
    target="$INSTALL_DIR/${link#*:}"
    if [[ "$(readlink "/usr/local/bin/${link%%:*}" 2>/dev/null)" != "$target" ]]; then
      as_root ln -sfn "$target" "/usr/local/bin/${link%%:*}"
      ok "Command added: ${link%%:*}"
    fi
  done

  for d in "$DATA_DIR" "$ZIM_DIR" "$OPEN_WEBUI_DATA_DIR"; do
    [[ -d "$d" ]] || as_root mkdir -p "$d"
  done
}

# ===========================================================================
# 4. Docker
# ===========================================================================
step_docker() {
  step 4 "$TOTAL_STEPS" "Docker + Docker Compose"
  if have docker && docker compose version >/dev/null 2>&1; then
    skip "Docker $(docker --version | awk '{print $3}' | tr -d ,) with Compose is installed"
  elif [[ "$DOCKER_SOURCE" == "ubuntu" ]]; then
    info "Installing Docker from the Ubuntu archive..."
    apt_install docker.io docker-compose-v2
  else
    info "Adding Docker's official package source (Ubuntu $UBUNTU_BASE)..."
    as_root install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
      as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      as_root chmod a+r /etc/apt/keyrings/docker.asc
    fi
    write_file /etc/apt/sources.list.d/docker.list 644 <<EOF || true
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $UBUNTU_BASE stable
EOF
    as_root apt-get update -q
    info "Installing Docker Engine and the Compose plugin..."
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Docker installed"
  fi

  if [[ ! -f /etc/docker/daemon.json ]]; then
    # Small log files so Docker never fills the disk.
    write_file /etc/docker/daemon.json 644 <<'EOF' || true
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "2" }
}
EOF
    systemctl is-active --quiet docker 2>/dev/null && as_root systemctl restart docker
  fi
  systemd_apply docker.service 0
  ok "Docker starts on boot"

  if [[ "$TARGET_USER" != "root" ]] && ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    as_root usermod -aG docker "$TARGET_USER"
    ok "Added $TARGET_USER to the docker group (takes effect after logging out and in)"
  fi
}

# ===========================================================================
# 5. Ollama
# ===========================================================================
ollama_unit() {
  local bin
  bin="$(command -v ollama || echo /usr/local/bin/ollama)"
  cat <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$bin serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=default.target
EOF
}

step_ollama() {
  step 5 "$TOTAL_STEPS" "Ollama (local AI engine)"
  if have ollama; then
    local version
    version="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
    skip "Ollama ${version:-} is installed"
  else
    info "Downloading and running the official Ollama installer..."
    local tmp
    tmp="$(mktemp)"
    run curl -fsSL "$OLLAMA_INSTALL_URL" -o "$tmp"
    run sh "$tmp"
    rm -f "$tmp"
    is_dry_run || have ollama || die "The Ollama installer finished but 'ollama' is not on the PATH."
    ok "Ollama installed"
  fi

  local changed=0
  if ! systemctl cat ollama.service >/dev/null 2>&1; then
    # The official installer creates this; we only get here if Ollama was installed another way.
    info "Creating the Ollama system service..."
    if ! id ollama >/dev/null 2>&1; then
      as_root useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
    fi
    ollama_unit | write_file /etc/systemd/system/ollama.service 644 && changed=1
  fi

  write_file /etc/systemd/system/ollama.service.d/cyberdeck.conf 644 <<EOF && changed=1
# Managed by cyberdeck install.sh — edit config.env instead.
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}:${OLLAMA_PORT}"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
EOF
  systemd_apply ollama.service "$changed"
  wait_for_url "$OLLAMA_URL/api/version" 90 "Ollama" \
    || die "Ollama did not start. See: journalctl -u ollama -n 50"
  ok "Ollama is running on $OLLAMA_URL and starts on boot"
}

# ===========================================================================
# 6. AI model
# ===========================================================================
model_present() {
  OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}" ollama list 2>/dev/null | awk 'NR>1 {print $1}' \
    | grep -qxF "$(full_model_name "$1")"
}

step_model() {
  step 6 "$TOTAL_STEPS" "AI model: $OLLAMA_MODEL"
  if model_present "$OLLAMA_MODEL"; then
    skip "Model $OLLAMA_MODEL is downloaded"
    return
  fi
  if [[ -n "$OLLAMA_MODEL_FILE" ]]; then
    [[ -f "$OLLAMA_MODEL_FILE" ]] || die "OLLAMA_MODEL_FILE does not exist: $OLLAMA_MODEL_FILE"
    info "Importing $OLLAMA_MODEL_FILE as $OLLAMA_MODEL..."
    local mf
    mf="$(mktemp)"
    printf 'FROM %s\n' "$OLLAMA_MODEL_FILE" > "$mf"
    run env OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}" ollama create "$OLLAMA_MODEL" -f "$mf"
    rm -f "$mf"
  else
    info "Downloading $OLLAMA_MODEL (a few GB — this takes a while)..."
    local attempt
    for attempt in 1 2 3; do
      if run env OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}" ollama pull "$OLLAMA_MODEL"; then break; fi
      (( attempt < 3 )) || die "Could not download $OLLAMA_MODEL. Check the name at https://ollama.com/library and your internet."
      warn "Download interrupted, retrying ($attempt/3)..."
      sleep 5
    done
  fi
  is_dry_run || model_present "$OLLAMA_MODEL" || die "Model $OLLAMA_MODEL is still missing after download."
  ok "Model $OLLAMA_MODEL is ready"
}

# ===========================================================================
# 7. Kiwix + Wikipedia
# ===========================================================================
zim_is_valid() {  # ZIM files start with the magic number 72173914 (bytes 5A 49 4D 04)
  [[ -s "$1" ]] && [[ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" == "5a494d04" ]]
}

# Newest file on the server with the same name prefix, e.g. wikipedia_en_all_mini_2026-09.zim
latest_zim_url() {
  local url="$1" dir base prefix name
  dir="${url%/*}/"
  base="${url##*/}"
  prefix="$(sed -E 's/_[0-9]{4}-[0-9]{2}\.zim$//' <<< "$base")"
  name="$(curl -fsSL --max-time 30 "$dir" | grep -oE "href=\"${prefix}_[0-9]{4}-[0-9]{2}\.zim\"" \
          | sed -E 's/^href="|"$//g' | sort -u | tail -1)" || true
  [[ -n "$name" ]] && echo "${dir}${name}"
}

kiwix_unit() {
  cat <<EOF
# Managed by cyberdeck install.sh — edit config.env instead.
[Unit]
Description=Kiwix server for the offline Wikipedia (cyberdeck)
After=network.target local-fs.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'exec /usr/bin/kiwix-serve --address=${KIWIX_BIND} --port=${KIWIX_PORT} --threads=2 --nodatealiases --blockexternal ${ZIM_DIR}/*.zim'
Restart=on-failure
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
Nice=5

[Install]
WantedBy=multi-user.target
EOF
}

step_kiwix() {
  step 7 "$TOTAL_STEPS" "Kiwix server + offline Wikipedia"
  have kiwix-serve || is_dry_run || die "kiwix-serve is missing (package kiwix-tools did not install)."

  local zim
  if [[ -n "$ZIM_PATH" ]]; then
    [[ -f "$ZIM_PATH" ]] || die "ZIM_PATH does not exist: $ZIM_PATH"
    zim_is_valid "$ZIM_PATH" || die "ZIM_PATH is not a valid .zim file: $ZIM_PATH"
    zim="$ZIM_DIR/$(basename "$ZIM_PATH")"
    if [[ "$(readlink -f "$zim")" != "$(readlink -f "$ZIM_PATH")" ]]; then
      as_root ln -sfn "$ZIM_PATH" "$zim"
    fi
    skip "Using your own Wikipedia file $ZIM_PATH"
    if ! is_dry_run && ! root sudo -u nobody test -r "$ZIM_PATH"; then
      warn "$ZIM_PATH is not readable by other users; Kiwix may not be able to open it."
      warn "Move it into $ZIM_DIR, or make it and its folders readable (chmod o+rx)."
    fi
  else
    local url="$ZIM_URL" base prefix existing
    base="${url##*/}"
    prefix="$(sed -E 's/_[0-9]{4}-[0-9]{2}\.zim$//' <<< "$base")"
    zim="$ZIM_DIR/$base"
    # Any already-downloaded version of the same Wikipedia counts (e.g. a newer month).
    existing="$(find "$ZIM_DIR" -maxdepth 1 -name "${prefix}*.zim" 2>/dev/null | sort | tail -1)" || true
    if zim_is_valid "$zim"; then
      skip "Wikipedia file $(basename "$zim") ($(du -h "$zim" | cut -f1))"
    elif [[ -n "$existing" ]] && zim_is_valid "$existing"; then
      zim="$existing"
      skip "Wikipedia file $(basename "$zim") ($(du -h "$zim" | cut -f1))"
    else
      if [[ "$url" != file://* ]] && ! curl -fsIL --max-time 30 -o /dev/null "$url"; then
        if [[ "$ZIM_AUTO_LATEST" == "true" ]]; then
          info "$base is not on the server any more; looking for the newest version..."
          url="$(latest_zim_url "$url")" || true
          [[ -n "$url" ]] || die "Could not find $prefix on the server. Pick a file from https://download.kiwix.org/zim/wikipedia/ and set ZIM_URL."
          zim="$ZIM_DIR/${url##*/}"
          info "Using $url"
        else
          die "ZIM_URL can't be downloaded: $url"
        fi
      fi
      local size
      size="$(curl -fsIL --max-time 30 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{s=$2} END{print s}')" || true
      if [[ -n "$size" && "$size" -gt 0 ]]; then
        info "Downloading $(basename "$zim") ($((size / 1024 / 1024 / 1024)) GB). Interrupted? Just run install.sh again — it resumes."
      else
        info "Downloading $(basename "$zim"). Interrupted? Just run install.sh again — it resumes."
      fi
      as_root mkdir -p "$ZIM_DIR"
      # Download as the current user into a .part file, then move into place.
      local part
      part="$ZIM_DIR/$(basename "$zim").part"
      as_root touch "$part"
      as_root chown "$(id -u):$(id -g)" "$part"
      run curl -fL --retry 5 --retry-delay 10 --continue-at - --progress-bar -o "$part" "$url"
      if ! is_dry_run; then
        zim_is_valid "$part" || die "The downloaded file is not a valid .zim file: $part"
      fi
      as_root mv -f "$part" "$zim"
      as_root chown root:root "$zim"
      as_root chmod 644 "$zim"
      ok "Downloaded $(basename "$zim")"
    fi
  fi

  local changed=0
  kiwix_unit | write_file /etc/systemd/system/cyberdeck-kiwix.service 644 && changed=1
  systemd_apply cyberdeck-kiwix.service "$changed"
  wait_for_url "$KIWIX_URL/" 60 "Kiwix" || die "Kiwix did not start. See: journalctl -u cyberdeck-kiwix -n 50"
  ok "Kiwix is serving $(basename "$zim") on $KIWIX_URL and starts on boot"
}

# ===========================================================================
# 8. Open WebUI
# ===========================================================================
step_open_webui() {
  step 8 "$TOTAL_STEPS" "Open WebUI (chat interface in Docker)"
  write_file "$INSTALL_DIR/docker/.env" 644 <<EOF || true
# Generated by install.sh from config.env — edit config.env instead.
OPEN_WEBUI_IMAGE=${OPEN_WEBUI_IMAGE}
OPEN_WEBUI_PORT=${OPEN_WEBUI_PORT}
OPEN_WEBUI_BIND=${OPEN_WEBUI_BIND}
OPEN_WEBUI_DATA_DIR=${OPEN_WEBUI_DATA_DIR}
OPEN_WEBUI_MODEL_ID=${OPEN_WEBUI_MODEL_ID}
OLLAMA_PORT=${OLLAMA_PORT}
EOF

  if docker_ro image inspect "$OPEN_WEBUI_IMAGE" >/dev/null 2>&1; then
    skip "Image $OPEN_WEBUI_IMAGE is downloaded"
  else
    info "Downloading $OPEN_WEBUI_IMAGE (about 2 GB)..."
    local attempt
    for attempt in 1 2 3; do
      if compose pull --quiet; then break; fi
      (( attempt < 3 )) || die "Could not download $OPEN_WEBUI_IMAGE."
      warn "Download failed, retrying ($attempt/3)..."
      sleep 5
    done
  fi

  # "up -d" only recreates the container if its settings changed.
  compose up -d --remove-orphans
  info "Waiting for Open WebUI to start (the first start can take a few minutes)..."
  wait_for_url "$OPEN_WEBUI_URL/health" 900 "Open WebUI" \
    || die "Open WebUI did not start. See: sudo docker logs open-webui --tail 50"
  ok "Open WebUI is running on $OPEN_WEBUI_URL and starts on boot (restart: unless-stopped)"
}

# ===========================================================================
# 9. Wikipedia tool inside Open WebUI
# ===========================================================================
step_webui_tool() {
  step 9 "$TOTAL_STEPS" "Offline Wikipedia tool in Open WebUI"
  local args=(install --url "$OPEN_WEBUI_URL" --tool-file "$INSTALL_DIR/tools/offline_wikipedia.py"
              --kiwix-url "$KIWIX_URL" --kiwix-book "$KIWIX_BOOK"
              --max-chars "$WIKI_MAX_CHARS" --max-articles "$WIKI_MAX_ARTICLES"
              --base-model "$OLLAMA_MODEL" --model-id "$OPEN_WEBUI_MODEL_ID"
              --model-name "$OPEN_WEBUI_MODEL_NAME" --num-ctx "$OLLAMA_CONTEXT_LENGTH")
  if is_dry_run; then
    run python3 "$INSTALL_DIR/tools/openwebui_setup.py" "${args[@]}"
    return
  fi
  local line
  while IFS= read -r line; do ok "$line"; done < <(python3 "$INSTALL_DIR/tools/openwebui_setup.py" "${args[@]}")
  python3 "$INSTALL_DIR/tools/wiki_ask.py" --no-ai "capacitor" >/dev/null 2>&1 \
    && ok "wiki-ask command works" \
    || warn "wiki-ask could not find an article for 'capacitor' (fine for small test .zim files)"
}

# ===========================================================================
# 10. AI mode launchers
# ===========================================================================
desktop_entry() {  # desktop_entry <name> <comment> <exec> <icon>
  cat <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$1
Comment=$2
Exec=$3
Icon=$4
Terminal=false
Categories=Utility;
StartupNotify=false
EOF
}

step_ai_mode() {
  step 10 "$TOTAL_STEPS" "AI mode: launchers and permissions"
  local helper="$INSTALL_DIR/scripts/ai-mode-root.sh"

  if [[ "$TARGET_USER" != "root" ]]; then
    # Lets AI mode stop/start the listed services without a password prompt.
    # Only this one root-owned script, with fixed actions, is allowed.
    local rule tmp
    rule="$TARGET_USER ALL=(root) NOPASSWD: $helper enter, $helper exit, $helper status"
    tmp="$(mktemp)"
    printf '# Managed by cyberdeck install.sh\n%s\n' "$rule" > "$tmp"
    if ! is_dry_run; then
      root visudo -cqf "$tmp" || die "Generated sudoers rule is invalid: $rule"
    fi
    if write_file /etc/sudoers.d/cyberdeck 440 < "$tmp"; then ok "AI mode can manage services without a password"
    else skip "sudo rule for AI mode"; fi
    rm -f "$tmp"
  fi

  local apps="$TARGET_HOME/.local/share/applications" desktop
  desktop="$(user_read xdg-user-dir DESKTOP 2>/dev/null || true)"
  [[ -n "$desktop" && "$desktop" != "$TARGET_HOME" ]] || desktop="$TARGET_HOME/Desktop"
  local owner
  owner="$TARGET_USER:$(id -gn "$TARGET_USER")"

  local changed=0 dir
  for dir in "$apps" "$desktop"; do
    [[ -d "$dir" ]] || as_user "$TARGET_USER" mkdir -p "$dir"
    desktop_entry "AI Mode" "Turn the deck into a dedicated offline AI machine" \
      "$INSTALL_DIR/scripts/ai-mode.sh" "$INSTALL_DIR/assets/ai-mode.svg" \
      | write_file "$dir/cyberdeck-ai-mode.desktop" 755 "$owner" && changed=1
    desktop_entry "Exit AI Mode" "Go back to the normal desktop" \
      "$INSTALL_DIR/scripts/exit-ai-mode.sh" "$INSTALL_DIR/assets/exit-ai-mode.svg" \
      | write_file "$dir/cyberdeck-exit-ai-mode.desktop" 755 "$owner" && changed=1
    desktop_entry "Offline Wikipedia" "Browse the offline Wikipedia" \
      "xdg-open $KIWIX_URL" "$INSTALL_DIR/assets/wikipedia.svg" \
      | write_file "$dir/cyberdeck-wikipedia.desktop" 755 "$owner" && changed=1
  done
  # Mark desktop icons as trusted so Nemo runs them without asking.
  if ! is_dry_run && have gio; then
    for f in "$desktop"/cyberdeck-*.desktop; do
      user_read gio set "$f" metadata::trusted true >/dev/null 2>&1 || true
    done
  fi
  if (( changed )); then ok "Launchers added to the menu and the desktop ($desktop)"
  else skip "Launchers"; fi
}

# ===========================================================================
# 11. Final check
# ===========================================================================
step_summary() {
  step 11 "$TOTAL_STEPS" "Final check"
  if is_dry_run; then
    ok "Dry run finished. Nothing was changed."
    return
  fi
  http_ok "$OLLAMA_URL/api/version" && ok "Ollama      $OLLAMA_URL" || warn "Ollama is not answering"
  http_ok "$OPEN_WEBUI_URL/health" && ok "Open WebUI  $OPEN_WEBUI_URL" || warn "Open WebUI is not answering"
  http_ok "$KIWIX_URL/" && ok "Kiwix       $KIWIX_URL" || warn "Kiwix is not answering"
  cat <<EOF

${C_BOLD}${C_GREEN}Cyberdeck is ready.${C_RESET}
  • Chat:          open $OPEN_WEBUI_URL and pick "$OPEN_WEBUI_MODEL_NAME"
  • AI mode:       double-click "AI Mode" on the desktop (or run: ai-mode)
  • Back to normal: "Exit AI Mode" icon, Ctrl+Q in the AI window, or run: exit-ai-mode
  • Terminal:      wiki-ask "what is a capacitor"
  • Test offline:  ./install.sh --offline-check
  Log: $LOG_FILE
EOF
  if [[ "$TARGET_USER" != "root" ]] && ! id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker && [[ "$(id -u)" -ne 0 ]]; then
    echo "  Note: log out and back in once so your user can run 'docker' without sudo."
  fi
}

main() {
  printf '%sCyberdeck installer%s  (config: %s)\n' "$C_BOLD" "$C_RESET" "$REPO_DIR/config.env"
  step_preflight
  step_packages
  step_files
  step_docker
  step_ollama
  step_model
  step_kiwix
  step_open_webui
  step_webui_tool
  step_ai_mode
  step_summary
}

main
