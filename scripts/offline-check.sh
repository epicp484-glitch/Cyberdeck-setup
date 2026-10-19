#!/usr/bin/env bash
# Offline check: proves the deck works with no internet.
# Everything below talks only to this computer. For a real test, switch off
# Wi-Fi / unplug the network first — the check tells you whether it is offline.
#
# Run with: ./install.sh --offline-check   (or: cyberdeck-offline-check)
# Exit code 0 = everything works.
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/scripts/lib/common.sh"
load_config "$DIR"

QUERY="${OFFLINE_CHECK_QUERY:-capacitor}"
PASS=0 FAIL=0 WARN=0
pass() { ok "$*"; PASS=$((PASS + 1)); }
fail() { printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*"; FAIL=$((FAIL + 1)); }
note() { warn "$*"; WARN=$((WARN + 1)); }
section() { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

# docker needs root unless the user is in the docker group
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then DOCKER=(sudo docker); fi

printf '%sCyberdeck offline check%s\n' "${C_BOLD}" "${C_RESET}"

section "Network"
if curl -fsS -o /dev/null --max-time 5 https://ollama.com 2>/dev/null \
   || curl -fsS -o /dev/null --max-time 5 http://archive.ubuntu.com 2>/dev/null; then
  note "Internet is reachable. These checks use only this computer, but for a real test switch Wi-Fi off and run again."
else
  pass "No internet connection — this is a real offline test"
fi

section "Services start on boot"
for svc in ollama.service cyberdeck-kiwix.service docker.service; do
  if systemctl is-enabled --quiet "$svc" 2>/dev/null && systemctl is-active --quiet "$svc" 2>/dev/null; then
    pass "$svc is running and enabled"
  else
    fail "$svc: $(systemctl is-active "$svc" 2>/dev/null), boot: $(systemctl is-enabled "$svc" 2>/dev/null) (try: sudo systemctl enable --now $svc)"
  fi
done
policy="$("${DOCKER[@]}" inspect -f '{{.State.Status}} {{.HostConfig.RestartPolicy.Name}}' open-webui 2>/dev/null)"
if [[ "$policy" == "running unless-stopped" || "$policy" == "running always" ]]; then
  pass "open-webui container is running (restart: ${policy#* })"
else
  fail "open-webui container: ${policy:-missing} (try: ./install.sh)"
fi

section "Ollama ($OLLAMA_URL)"
if version="$(curl -fsS --max-time 5 "$OLLAMA_URL/api/version" 2>/dev/null)"; then
  pass "Ollama responds: $version"
  model="$OLLAMA_MODEL"; [[ "$model" == *:* ]] || model="$model:latest"
  if curl -fsS --max-time 10 "$OLLAMA_URL/api/tags" | python3 -c 'import json,sys; m=sys.argv[1]; sys.exit(0 if any(x["name"]==m for x in json.load(sys.stdin)["models"]) else 1)' "$model"; then
    pass "Model $OLLAMA_MODEL is downloaded"
  else
    fail "Model $OLLAMA_MODEL is missing (run ./install.sh while online)"
  fi
  info "Asking the model a tiny question (first answer can take a minute while it loads)..."
  start=$(date +%s)
  reply="$(curl -fsS --max-time 600 "$OLLAMA_URL/api/generate" \
            -d "{\"model\":\"$OLLAMA_MODEL\",\"prompt\":\"Say hello in three words.\",\"stream\":false,\"think\":false,\"options\":{\"num_predict\":16}}" 2>&1 \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("response","").strip())' 2>/dev/null)"
  if [[ -n "$reply" ]]; then
    pass "Model answers ($(( $(date +%s) - start ))s): ${reply:0:60}"
  else
    fail "Model did not answer (see: journalctl -u ollama -n 50)"
  fi
else
  fail "Ollama is not responding (try: sudo systemctl restart ollama)"
fi

section "Kiwix offline Wikipedia ($KIWIX_URL)"
book="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
import offline_wikipedia as w
print(w.KiwixClient(sys.argv[2], sys.argv[3]).book)
' "$DIR/tools" "$KIWIX_URL" "$KIWIX_BOOK" 2>/dev/null)"
if [[ -n "$book" ]]; then
  pass "Kiwix is serving: $book"
  if curl -fsSL --max-time 15 "$KIWIX_URL/content/$book/" 2>/dev/null | grep -qi "<html"; then
    pass "Kiwix serves pages (main page of $book loads)"
  else
    fail "Kiwix main page for $book did not load"
  fi
else
  fail "Kiwix is not serving any book (try: sudo systemctl restart cyberdeck-kiwix)"
fi

section "Offline Wikipedia tool"
if out="$(python3 "$DIR/tools/wiki_ask.py" --no-ai --json "$QUERY" 2>&1)" \
   && title="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["articles"][0]["title"])' <<< "$out" 2>/dev/null)"; then
  pass "Wikipedia lookup works: \"$QUERY\" -> article \"$title\""
else
  fail "Wikipedia lookup failed: ${out:0:200}"
fi
if out="$(timeout 900 python3 "$DIR/tools/wiki_ask.py" --json "what is a $QUERY" 2>&1)" \
   && answer="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["answer"].strip()[:80].replace("\n"," "))' <<< "$out" 2>/dev/null)" \
   && [[ -n "$answer" ]]; then
  pass "wiki-ask answers with the model: ${answer}…"
else
  fail "wiki-ask could not get an answer: ${out:0:200}"
fi
# Run the tool exactly as Open WebUI does, inside its container.
tool_test='
import asyncio, sys, types
mod = types.ModuleType("offline_wikipedia")
exec(compile(sys.stdin.read(), "offline_wikipedia.py", "exec"), mod.__dict__)
t = mod.Tools(); t.valves.KIWIX_URL = sys.argv[1]
print(asyncio.run(t.search_wikipedia(sys.argv[2]))[:300])
'
if res="$("${DOCKER[@]}" exec -i open-webui python3 -c "$tool_test" "$KIWIX_URL" "$QUERY" < "$DIR/tools/offline_wikipedia.py" 2>&1)" \
   && [[ "$res" == *"Wikipedia article"* ]]; then
  pass "Tool works inside the Open WebUI container"
else
  fail "Tool failed inside the Open WebUI container: ${res:0:200}"
fi

section "Open WebUI ($OPEN_WEBUI_URL)"
if http_ok "$OPEN_WEBUI_URL/health" 10; then
  pass "Open WebUI health check is OK"
  if curl -fsS --max-time 20 "$OPEN_WEBUI_URL/" 2>/dev/null | grep -qi "<html"; then
    pass "Open WebUI page loads"
  else
    fail "Open WebUI page did not load"
  fi
  if res="$(python3 "$DIR/tools/openwebui_setup.py" check --url "$OPEN_WEBUI_URL" --model-id "$OPEN_WEBUI_MODEL_ID" --wait 30 2>&1)"; then
    pass "$res"
  else
    fail "${res:-Open WebUI setup check failed} (run ./install.sh to reinstall the tool)"
  fi
else
  fail "Open WebUI is not responding (see: sudo docker logs open-webui --tail 50)"
fi

section "AI mode"
if python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.1")' 2>/dev/null; then
  pass "Kiosk window (WebKitGTK) is available"
elif have chromium || have chromium-browser || have firefox; then
  pass "Kiosk browser available ($(command -v chromium chromium-browser firefox 2>/dev/null | head -1))"
else
  fail "No kiosk browser found (install gir1.2-webkit2-4.1 or chromium)"
fi
if [[ -x "$DIR/scripts/ai-mode.sh" && -x "$DIR/scripts/exit-ai-mode.sh" ]]; then
  pass "AI mode scripts are installed"
else
  fail "AI mode scripts are missing in $DIR/scripts"
fi

printf '\n%sResult:%s %d passed, %d failed, %d warnings\n' "${C_BOLD}" "${C_RESET}" "$PASS" "$FAIL" "$WARN"
if (( FAIL == 0 )); then
  printf '%s✓ The cyberdeck works offline.%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
  exit 0
fi
exit 1
