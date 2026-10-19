#!/usr/bin/env bash
# =============================================================================
#  Full install test inside a Linux Mint Docker container (systemd as PID 1).
#
#    tests/run-docker-test.sh          run every phase
#    KEEP=1 tests/run-docker-test.sh   leave the container running afterwards
#
#  Phases:
#    1. ./install.sh --dry-run    must succeed and change nothing
#    2. ./install.sh              full install
#    3. ./install.sh              again: everything must be skipped (idempotent)
#    4. AI mode / exit AI mode    on a virtual X display; screenshot of the kiosk
#    5. offline                   network unplugged: --offline-check + re-run install
#    6. reboot                    restart the machine, services must come back
#
#  To keep the test small it uses a tiny test model (random weights, a few
#  hundred KB) and a tiny Wikipedia-style .zim instead of the multi-GB real
#  files. Set TEST_REAL_MODEL=1 to download the real model from config.env.
#  Needs: docker, python3 (with venv). Uses ~8 GB of disk (Open WebUI image).
# =============================================================================
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
BUILD="$TESTS_DIR/.build"
OUT="$TESTS_DIR/output"
IMAGE="cyberdeck-test:mint"
NAME="${CONTAINER_NAME:-cyberdeck-test}"
BASE_IMAGE="${BASE_IMAGE:-linuxmintd/mint22.3-amd64}"
mkdir -p "$BUILD" "$OUT"

bold() { printf '\n\e[1;35m=== %s ===\e[0m\n' "$*"; }
pass() { printf '\e[32m  PASS\e[0m %s\n' "$*"; }
fail() { printf '\e[31m  FAIL\e[0m %s\n' "$*"; exit 1; }
trap 'fail "test script error at line $LINENO: $BASH_COMMAND"' ERR

in_box() { docker exec "$NAME" "$@"; }                       # as root
as_deck() { docker exec -u deck -w /home/deck -e HOME=/home/deck "$NAME" "$@"; }

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo "Container kept: docker exec -it -u deck $NAME bash   (remove: docker rm -f $NAME)"
  else
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm -f "$NAME-docker" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
bold "Preparing test files"
# -----------------------------------------------------------------------------
if [[ ! -x "$BUILD/venv/bin/python" ]]; then
  python3 -m venv "$BUILD/venv"
  "$BUILD/venv/bin/pip" install -q libzim gguf numpy
fi
[[ -f "$BUILD/fixtures/wikipedia_en_test_2026-10.zim" ]] || {
  mkdir -p "$BUILD/fixtures"
  "$BUILD/venv/bin/python" "$TESTS_DIR/fixtures/make_test_zim.py" "$BUILD/fixtures/wikipedia_en_test_2026-10.zim" >/dev/null
}
[[ -f "$BUILD/fixtures/tiny.gguf" ]] || "$BUILD/venv/bin/python" "$TESTS_DIR/fixtures/make_tiny_gguf.py" "$BUILD/fixtures/tiny.gguf" >/dev/null
pass "test .zim and tiny test model built"

# Settings for the test run (on top of config.env).
cat > "$BUILD/fixtures/test.env" <<'EOF'
CYBERDECK_USER="deck"
ZIM_URL="file:///fixtures/wikipedia_en_test_2026-10.zim"
AI_MODE_STOP_SERVICES+=("cron.service")
EOF
if [[ "${TEST_REAL_MODEL:-0}" != "1" ]]; then
  cat >> "$BUILD/fixtures/test.env" <<'EOF'
OLLAMA_MODEL="cyberdeck-tiny-test"
OLLAMA_MODEL_FILE="/fixtures/tiny.gguf"
OLLAMA_CONTEXT_LENGTH="2048"
EOF
fi

# The machine running the tests may sit behind a TLS-inspecting proxy.
: > "$BUILD/extra-ca.crt"
CA="${TEST_CA_CERT:-${SSL_CERT_FILE:-}}"
if [[ -n "$CA" && -s "$CA" && "$CA" != /etc/ssl/certs/* ]]; then
  cp "$CA" "$BUILD/extra-ca.crt"
  echo "  using extra CA certificate from $CA"
fi

# Ollama's own download server may be blocked where the tests run. Then the test
# machine gets Ollama pre-installed from the official ollama/ollama image, in the
# same place the official installer puts it, and install.sh skips the download.
PREINSTALL_OLLAMA=0
if ! curl -fsS -o /dev/null --max-time 15 https://ollama.com/install.sh 2>/dev/null; then
  PREINSTALL_OLLAMA=1
  if [[ ! -x "$BUILD/ollama/bin/ollama" ]]; then
    echo "  ollama.com is not reachable from here; taking Ollama from the ollama/ollama image"
    docker pull -q ollama/ollama:latest >/dev/null
    cid=$(docker create ollama/ollama:latest)
    rm -rf "$BUILD/ollama" && mkdir -p "$BUILD/ollama/bin" "$BUILD/ollama/lib"
    docker cp "$cid:/usr/bin/ollama" "$BUILD/ollama/bin/ollama"
    docker cp "$cid:/usr/lib/ollama" "$BUILD/ollama/lib/ollama"
    docker rm "$cid" >/dev/null
    # CPU only: drop the GPU libraries (several GB).
    rm -rf "$BUILD/ollama/lib/ollama"/{cuda_*,mlx*,vulkan,include,rocm*}
    docker rmi ollama/ollama:latest >/dev/null 2>&1 || true
  fi
fi

DISABLE_MINT_REPO=0
if ! curl -fsS -o /dev/null --max-time 15 http://packages.linuxmint.com/ 2>/dev/null; then
  DISABLE_MINT_REPO=1
  echo "  packages.linuxmint.com is not reachable from here; the test machine uses only the Ubuntu archive"
fi

# -----------------------------------------------------------------------------
bold "Building the Linux Mint test machine ($BASE_IMAGE)"
# -----------------------------------------------------------------------------
docker build -q -t "$IMAGE" --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg DISABLE_MINT_REPO="$DISABLE_MINT_REPO" -f "$TESTS_DIR/docker/Dockerfile" "$BUILD" >/dev/null
pass "image $IMAGE built"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm -f "$NAME-docker" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname cyberdeck --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec \
  -v "$NAME-docker:/var/lib/docker" \
  -v "$REPO_DIR:/home/deck/Cyberdeck-setup:ro" \
  -v "$BUILD/fixtures:/fixtures:ro" \
  -e CYBERDECK_CONFIG=/fixtures/test.env \
  "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  state="$(in_box systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
pass "test machine booted (systemd: $state)"

if (( PREINSTALL_OLLAMA )); then
  docker cp "$BUILD/ollama/bin/ollama" "$NAME:/usr/local/bin/ollama"
  docker cp "$BUILD/ollama/lib/ollama" "$NAME:/usr/local/lib/ollama"
  in_box chown -R root:root /usr/local/bin/ollama /usr/local/lib/ollama
  pass "Ollama pre-installed at /usr/local/bin/ollama (official installer not reachable)"
fi

# install.sh is run as the desktop user from the (read-only) repo, like on the deck.
install_sh() { docker exec -u deck -w /home/deck/Cyberdeck-setup -e HOME=/home/deck \
  -e CYBERDECK_CONFIG=/fixtures/test.env "$NAME" ./install.sh "$@"; }

# -----------------------------------------------------------------------------
bold "Phase 1: dry run changes nothing"
# -----------------------------------------------------------------------------
install_sh --dry-run > "$OUT/1-dry-run.log" 2>&1 || { tail -30 "$OUT/1-dry-run.log"; fail "dry run failed"; }
grep -q "Dry run finished" "$OUT/1-dry-run.log" || fail "dry run did not finish"
in_box test ! -e /opt/cyberdeck || fail "dry run created /opt/cyberdeck"
in_box test ! -e /etc/systemd/system/cyberdeck-kiwix.service || fail "dry run created a service"
in_box sh -c '! command -v docker' || fail "dry run installed docker"
pass "dry run printed $(grep -c '\[dry-run\]' "$OUT/1-dry-run.log") commands and changed nothing"

# -----------------------------------------------------------------------------
bold "Phase 2: full install"
# -----------------------------------------------------------------------------
start=$(date +%s)
install_sh > "$OUT/2-install.log" 2>&1 || { tail -40 "$OUT/2-install.log"; fail "install failed"; }
grep -q "Cyberdeck is ready" "$OUT/2-install.log" || fail "install did not finish"
pass "install finished in $(( $(date +%s) - start ))s (log: tests/output/2-install.log)"

# -----------------------------------------------------------------------------
bold "Phase 3: second run is idempotent"
# -----------------------------------------------------------------------------
start=$(date +%s)
install_sh > "$OUT/3-reinstall.log" 2>&1 || { tail -40 "$OUT/3-reinstall.log"; fail "second install failed"; }
skipped=$(grep -c "(already done)" "$OUT/3-reinstall.log")
if grep -E "Installing|Downloading|Copied|created|installed$|Created" "$OUT/3-reinstall.log" | grep -v "already" ; then
  fail "second run did work again (see above)"
fi
pass "second run skipped $skipped steps and changed nothing ($(( $(date +%s) - start ))s)"

# -----------------------------------------------------------------------------
bold "Phase 4: AI mode on a virtual screen"
# -----------------------------------------------------------------------------
cat > "$BUILD/fixtures/ai-mode-test.sh" <<'EOF'
#!/bin/bash
# Runs inside the test machine as "deck", in a D-Bus session with a virtual X screen.
set -u
Xvfb :99 -screen 0 1024x600x24 >/dev/null 2>&1 &
export DISPLAY=:99
sleep 2
openbox >/dev/null 2>&1 &   # a window manager, like Cinnamon's
sleep 1
xterm -T "some other app" -e sleep 600 &
sleep 2
echo "windows before: $(wmctrl -l | wc -l)"
gsettings set org.cinnamon.desktop.interface enable-animations true
gsettings set org.cinnamon.desktop.session idle-delay 300
before="$(gsettings get org.cinnamon.desktop.interface enable-animations) $(gsettings get org.cinnamon.desktop.session idle-delay)"

ai-mode --no-kiosk || exit 10
during="$(gsettings get org.cinnamon.desktop.interface enable-animations) $(gsettings get org.cinnamon.desktop.session idle-delay)"
echo "settings before: $before / during: $during"
[[ "$during" == "false uint32 0" ]] || exit 11
sleep 1
pgrep -f "some other app" >/dev/null && exit 12      # other app was closed
systemctl is-active --quiet cron && exit 13          # background service stopped
curl -fsS http://127.0.0.1:11434/api/ps | grep -q '"name"' || { sleep 5; curl -fsS http://127.0.0.1:11434/api/ps | grep -q '"name"'; } || exit 14   # model preloaded

# The kiosk window itself: open it, wait for Open WebUI to render, take a screenshot.
python3 /opt/cyberdeck/scripts/kiosk.py --windowed http://127.0.0.1:3000 >/tmp/kiosk.log 2>&1 &
sleep 40
import -window root /tmp/kiosk.png
wmctrl -l | grep -q "Cyberdeck AI\|Open WebUI" || { cat /tmp/kiosk.log; exit 15; }

exit-ai-mode || exit 16
after="$(gsettings get org.cinnamon.desktop.interface enable-animations) $(gsettings get org.cinnamon.desktop.session idle-delay)"
echo "settings after: $after"
[[ "$after" == "$before" ]] || exit 17
pgrep -f /opt/cyberdeck/scripts/kiosk.py && exit 18   # kiosk closed
systemctl is-active --quiet cron || exit 19           # service back
echo "AI MODE TEST OK"
EOF
chmod +x "$BUILD/fixtures/ai-mode-test.sh"
if as_deck dbus-run-session -- /fixtures/ai-mode-test.sh > "$OUT/4-ai-mode.log" 2>&1; then
  pass "AI mode: effects off, other apps closed, services stopped, model preloaded, kiosk opened"
  pass "Exit AI mode: settings restored, kiosk closed, services back"
else
  code=$?
  tail -30 "$OUT/4-ai-mode.log"
  as_deck tail -40 /home/deck/.local/state/cyberdeck/ai-mode.log || true
  fail "AI mode test failed (exit $code, see tests/output/4-ai-mode.log)"
fi
docker cp "$NAME:/tmp/kiosk.png" "$OUT/kiosk-screenshot.png" >/dev/null 2>&1 && pass "kiosk screenshot: tests/output/kiosk-screenshot.png"

# -----------------------------------------------------------------------------
bold "Phase 5: offline (network unplugged)"
# -----------------------------------------------------------------------------
docker network disconnect bridge "$NAME"
in_box sh -c '! curl -s -o /dev/null --max-time 5 https://download.docker.com' || fail "container still has internet"
pass "network disconnected"
install_sh --offline-check > "$OUT/5-offline-check.log" 2>&1 || { cat "$OUT/5-offline-check.log"; fail "offline check failed"; }
grep -q "No internet connection" "$OUT/5-offline-check.log" || fail "offline check did not notice it is offline"
pass "offline check: $(grep 'Result:' "$OUT/5-offline-check.log" | sed 's/\x1b\[[0-9;]*m//g')"
install_sh > "$OUT/5-offline-reinstall.log" 2>&1 || { tail -30 "$OUT/5-offline-reinstall.log"; fail "re-running install.sh offline failed"; }
pass "re-running install.sh with no internet still works (everything skipped)"

# -----------------------------------------------------------------------------
bold "Phase 6: reboot, services come back by themselves"
# -----------------------------------------------------------------------------
docker restart "$NAME" >/dev/null
for _ in $(seq 1 90); do
  state="$(in_box systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
docker network disconnect bridge "$NAME" >/dev/null 2>&1 || true
for _ in $(seq 1 120); do in_box curl -fsS -o /dev/null http://127.0.0.1:3000/health 2>/dev/null && break; sleep 2; done
install_sh --offline-check > "$OUT/6-after-reboot.log" 2>&1 || { cat "$OUT/6-after-reboot.log"; fail "offline check after reboot failed"; }
pass "after reboot: $(grep 'Result:' "$OUT/6-after-reboot.log" | sed 's/\x1b\[[0-9;]*m//g')"

bold "ALL TESTS PASSED"
