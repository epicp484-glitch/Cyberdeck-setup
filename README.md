# Cyberdeck-setup

One script that turns a fresh Linux Mint mini PC into an **offline AI cyberdeck**:
a local AI model you can chat with, an offline copy of Wikipedia, and a tool that
lets the AI look things up in that Wikipedia and tell you which article it used.
After setup it needs **no internet at all**.

It's built for my deck, but it should work on any x86_64 Linux Mint machine.
Take it and tweak `config.env` for your own device.

---

## What hardware it's for

| Part      | My deck                                              |
|-----------|------------------------------------------------------|
| Computer  | Beelink Mini S12 (Intel N95, 4 cores, 12 GB RAM)     |
| OS        | Linux Mint (Cinnamon, x86_64)                        |
| Screen    | 7-inch display                                       |
| Input     | Mini keyboard + mouse                                |
| Power     | Power bank                                           |
| Internet  | Only during install. Fully offline afterwards        |

You need roughly **25 GB free disk space** (model ~3.4 GB, Wikipedia ~12 GB, Open WebUI ~4 GB).

## What gets installed

| Piece | What it does | Where |
|-------|--------------|-------|
| **Ollama** | Runs the AI model (default `qwen3.5:4b`) | system service `ollama`, port 11434 |
| **Open WebUI** | The chat app in your browser | Docker container `open-webui`, port 3000 |
| **Kiwix** | Serves the offline Wikipedia | system service `cyberdeck-kiwix`, port 8090 |
| **Offline Wikipedia tool** | Lets the AI search Wikipedia and cite the article | inside Open WebUI, plus the `wiki-ask` command |
| **AI mode** | One click: strips the desktop down and opens the AI fullscreen | "AI Mode" / "Exit AI Mode" icons |

All three services start by themselves when the deck boots. Everything only listens
on `127.0.0.1` (this computer), so nothing is exposed to a network.

---

## How to run it

On the deck, connected to the internet:

```bash
git clone https://github.com/epicp484-glitch/Cyberdeck-setup.git
cd Cyberdeck-setup
./install.sh
```

It asks for your password once, then shows each step as `[3/11] ...` with a ✓ when done.
The first run takes a while (it downloads about 20 GB). When it says **Cyberdeck is ready**,
you can unplug the internet for good.

Other options:

```bash
./install.sh --dry-run        # show every step and command, change nothing
./install.sh --offline-check  # test that everything works without internet
./install.sh --help
```

**Safe to run again.** Every step checks whether it's already done and skips it.
If something fails (say the Wi-Fi dropped), fix it and run `./install.sh` again — it carries
on where it stopped, and even resumes a half-finished Wikipedia download.
Re-run it after any change to `config.env` to apply the change.

A log of every run is kept in `~/.local/state/cyberdeck/install.log`.

---

## Using it

- **Chat:** open <http://127.0.0.1:3000>. The model **"Cyberdeck AI (Wikipedia)"** is picked by default
  and has the Wikipedia tool switched on. Ask a factual question and it looks the answer up, then ends with
  `Source: Wikipedia - <article>`. Click the source under the answer to read the text it used.
- **Terminal:**
  ```bash
  wiki-ask "what is a capacitor"
  wiki-ask --no-ai "Apollo 11"     # only show the Wikipedia text it found
  wiki-ask --help
  ```
- **Browse Wikipedia yourself:** the "Offline Wikipedia" icon, or <http://127.0.0.1:8090>.

## AI mode

Double-click **AI Mode** on the desktop (it's also in the menu). It:

1. turns off desktop effects, animations and screen blanking (it saves your settings first),
2. closes your other windows (politely, like clicking X), stops background apps
   (update manager tray, desktop icons, Warpinator…) and services you don't need offline
   (printing, modem manager, update timers…),
3. makes sure Ollama, Open WebUI and Kiwix are running and loads the model into RAM,
4. opens the chat **fullscreen** in a tiny kiosk window.

To leave: press **Ctrl+Q** in the AI window (closing it exits AI mode), double-click
**Exit AI Mode**, or run `exit-ai-mode`. That puts all your settings, apps and services back
and frees the model's RAM.

Kiosk window keys: `Ctrl+Q` leave · `F5` reload · `Ctrl +`/`Ctrl -`/`Ctrl 0` zoom · `Alt+←` back · `F11` fullscreen.

What AI mode turns off is listed in `config.env` (`AI_MODE_GSETTINGS`, `AI_MODE_STOP_APPS`,
`AI_MODE_STOP_SERVICES`). Add or remove lines there, then run `./install.sh` again.

---

## Changing the model

1. Pick a model from <https://ollama.com/library>. Good choices for 12 GB of RAM:

   | Model | Size | Notes |
   |-------|------|-------|
   | `qwen3.5:0.8b` | ~1 GB | fastest, simplest answers |
   | `qwen3.5:2b` | ~2.7 GB | quick |
   | `qwen3.5:4b` | ~3.4 GB | **default**, good balance on an N95 |
   | `qwen3.5:9b` | ~6.6 GB | smarter, but slow on an N95 |

2. Edit `config.env`:
   ```bash
   OLLAMA_MODEL="qwen3.5:2b"
   ```
3. Run `./install.sh` (while online). It downloads the new model and points the
   "Cyberdeck AI" chat model at it. The old model stays on disk; remove it with
   `ollama rm qwen3.5:4b` if you need the space.

No internet on the deck? Download a `.gguf` file elsewhere, copy it over, and set
`OLLAMA_MODEL_FILE="/path/to/model.gguf"` — it gets imported instead of downloaded.

## Changing the Wikipedia

`ZIM_URL` in `config.env` chooses the file. The default is `wikipedia_en_all_mini` (~12 GB): the
intro and infobox of **every** English article, which is exactly what a small model can use.
For full articles, use `wikipedia_en_all_nopic` (~50 GB). All files: <https://download.kiwix.org/zim/wikipedia/>.
Kiwix deletes old dated files; if the URL is gone, the installer automatically finds the newest file with the same name.
Already have a `.zim`? Set `ZIM_PATH="/path/to/file.zim"` and nothing is downloaded.

Big files (models, `.zim`) are downloaded, never stored in this repo (see `.gitignore`).

---

## Settings

Everything is in **`config.env`**: model, ports, Wikipedia URL/path, install paths and AI mode
options. Each line has a comment. For personal changes you don't want in git, create
`config.local.env` with just the lines you want to change (it's git-ignored).

## What's in this repo

```
install.sh                 the one entry point
config.env                 all settings
docker/docker-compose.yml  Open WebUI
tools/
  offline_wikipedia.py     the Wikipedia tool (Open WebUI tool + library)
  wiki_ask.py              wiki-ask command
  openwebui_setup.py       installs the tool + "Cyberdeck AI" model into Open WebUI
scripts/
  ai-mode.sh               AI mode
  exit-ai-mode.sh          back to the normal desktop
  ai-mode-root.sh          the small part of AI mode that needs root (stops/starts services)
  kiosk.py                 the lightweight fullscreen browser window
  offline-check.sh         the --offline-check
  lib/common.sh            shared helpers (logging, --dry-run, config loading)
assets/                    launcher icons
tests/                     Docker test of the whole install
```

The installer copies the scripts, tools and config to `/opt/cyberdeck`, so the deck keeps
working even if you delete the cloned repo.

## How the Wikipedia tool works

1. Picks the important words from your question (`"what is a capacitor"` → `capacitor`).
2. Searches Kiwix by article title and by full text, and ranks the results (exact titles win,
   disambiguation pages are skipped).
3. Downloads the best article and cleans it up: removes menus, references, `[1]` markers and
   tables, but keeps the infobox facts as `Label: value` lines.
4. Trims it to fit a small model (`WIKI_MAX_CHARS`, default 6000 characters ≈ 1500 tokens):
   the introduction first, then the paragraphs that share the most words with your question.
5. Hands that text to the model with the article title and asks it to answer from it and
   name the article. In Open WebUI the article also shows up as a clickable source.

It only uses the Python standard library, so it has no extra dependencies.

---

## Testing (for development)

The whole install can be tested in a Linux Mint Docker container with systemd, without a real deck:

```bash
tests/run-docker-test.sh          # KEEP=1 keeps the container for poking around
```

It runs the dry run (must change nothing), a full install, a second install (must skip
everything), AI mode and exit AI mode on a virtual screen (with a screenshot of the kiosk
window in `tests/output/`), then unplugs the network and runs `--offline-check`, and finally
reboots the container and checks that everything comes back by itself.
To keep it fast it uses a tiny test model and a tiny test Wikipedia instead of the big downloads
(`TEST_REAL_MODEL=1` uses the real model).

---

## Troubleshooting

| Problem | Try this |
|---------|----------|
| The installer stopped with **✗ FAILED** | Read the lines above it: they say which step and command failed. Fix it (often: no internet) and run `./install.sh` again. Full log: `~/.local/state/cyberdeck/install.log` |
| Chat page doesn't load | `sudo docker ps` should show `open-webui`. Logs: `sudo docker logs open-webui --tail 50`. Restart: `sudo docker restart open-webui`. The first start after install can take a few minutes. |
| "Model not found" / no models in the chat | `ollama list` should show your model. If not, run `./install.sh` while online. Check Ollama: `systemctl status ollama` |
| Answers are very slow | Normal for the first question (the model is loading, ~10–30 s). Use AI mode (keeps the model loaded) or a smaller model (`qwen3.5:2b`). |
| AI doesn't use Wikipedia | Make sure the chat uses **"Cyberdeck AI (Wikipedia)"**, not the plain model. In the chat box, the tools button (wrench icon) should show "Offline Wikipedia" switched on. Run `./install.sh` to reinstall the tool. |
| "Can't reach the Kiwix server" | `systemctl status cyberdeck-kiwix`, then `journalctl -u cyberdeck-kiwix -n 50`. Check the `.zim` file is in `/opt/cyberdeck/data/zim/`. |
| `wiki-ask` finds no article | Try fewer, simpler words: `wiki-ask --no-ai "capacitor"`. |
| Wikipedia download keeps failing | Run `./install.sh` again — it resumes. Or download the `.zim` on another computer and set `ZIM_PATH`. |
| AI mode can't stop services ("sudo rule") | Run `./install.sh` again; it installs the rule in `/etc/sudoers.d/cyberdeck`. |
| Stuck in AI mode / desktop looks wrong | Run `exit-ai-mode` in a terminal (Ctrl+Alt+T). It restores the saved settings. Log: `~/.local/state/cyberdeck/ai-mode.log` |
| AI window text too small/big on the 7" screen | `Ctrl +` / `Ctrl -` in the window, or set `AI_MODE_ZOOM` in `config.env`. |
| `docker: permission denied` | Log out and back in once after the install (your user was added to the `docker` group). Or use `sudo docker`. |
| Is it really offline-ready? | Turn Wi-Fi off and run `./install.sh --offline-check`. |

Useful status commands:

```bash
systemctl status ollama cyberdeck-kiwix docker
sudo docker ps
sudo /opt/cyberdeck/scripts/ai-mode-root.sh status
```

---

## Decisions

Things I had to decide without asking. Change any of them in `config.env`.

- **Model:** `qwen3.5:4b`. That is the Ollama tag for Qwen 3.5 4B (confirmed by Ollama's
  Qwen 3.5 announcement; ~3.4 GB, q4_K_M). Qwen 3.5's "thinking" is **switched off** in the
  Cyberdeck AI chat model and in `wiki-ask`, because on an N95 it makes every answer much slower,
  and the Wikipedia text already contains the facts.
- **Context window:** 8192 tokens (`OLLAMA_CONTEXT_LENGTH`). It fits easily in 12 GB next to a 4B
  model and leaves room for ~1500 tokens of Wikipedia text plus the conversation.
- **Ollama:** installed with the official script from ollama.com and run as its normal
  `ollama` system service. Settings go into a separate systemd drop-in (`ollama.service.d/cyberdeck.conf`),
  so updating Ollama doesn't overwrite them. One model and one request at a time to save RAM.
- **Wikipedia file:** `wikipedia_en_all_mini_2026-06.zim` (~12 GB, intro + infobox of every article).
  The full-text "nopic" version (~50 GB) is 4× bigger, and a 4B model can only read about one intro's
  worth of text per question anyway. If Kiwix removes that dated file, the installer picks the newest one.
- **Kiwix runs natively, not in Docker:** the `kiwix-tools` package from the Ubuntu archive
  (version 3.5 on Mint 22), as a locked-down systemd service. It's lighter than another container
  and its image registry was not needed. It serves every `.zim` in `/opt/cyberdeck/data/zim/`.
- **Open WebUI image:** `openwebui/open-webui:latest` from Docker Hub (the official image, also on
  ghcr.io). Not pinned, so a fresh install gets the newest version. To pin it, set a version tag such as
  `openwebui/open-webui:0.12.3` in `OPEN_WEBUI_IMAGE`.
- **Open WebUI networking:** host network mode, so it reaches Ollama and Kiwix on `127.0.0.1` and
  neither has to listen on the network. Open WebUI itself only listens on `127.0.0.1:3000`.
- **No login screen** (`WEBUI_AUTH=False`): it's a single-user deck. This is also what lets the
  installer add the tool automatically. If you set `OPEN_WEBUI_BIND=0.0.0.0` to use it from
  your phone, anyone on that network can use it.
- **Open WebUI kept light and offline:** `OFFLINE_MODE` on, update checks, telemetry, web search,
  image generation and the OpenAI connection off. The extra AI calls it normally makes after each
  answer (titles, tags, follow-up suggestions, autocomplete) are off too, because on an N95 each one costs seconds.
- **How the tool gets into the chat:** the installer adds it to Open WebUI as the tool "Offline Wikipedia"
  and creates a chat model "Cyberdeck AI (Wikipedia)" based on your Ollama model, with the tool
  switched on, native tool calling and a system prompt telling it to look things up and name
  the article. This chat model is the default.
- **One tool file for both uses:** `tools/offline_wikipedia.py` is the Open WebUI tool *and* the library
  `wiki-ask` uses, so they always behave the same. Standard library only.
- **Amount of Wikipedia text:** 6000 characters (~1500 tokens) from 1 article per question. More
  text makes a small model slower and more confused, not smarter.
- **AI mode kiosk browser:** a tiny custom window built on WebKitGTK (`scripts/kiosk.py`), because a
  full browser uses far more RAM. If WebKitGTK isn't available it falls back to Chromium, then Firefox.
- **What AI mode turns off:** Cinnamon effects/animations, screen blanking, other open windows, the
  update manager tray, desktop icons, Warpinator and the on-screen keyboard, plus printing, modem manager,
  colour management, firmware/package update services and background maintenance timers.
  **Bluetooth is left on** in case your keyboard uses it. Wi-Fi is left alone too.
- **Closing other windows** means the normal polite close, so an app with unsaved work can still
  ask to save. Set `AI_MODE_WINDOWS="minimize"` if you'd rather keep them open.
- **Closing the AI window exits AI mode** (`AI_MODE_EXIT_ON_CLOSE`). In AI mode the model stays loaded
  the whole time. Leaving AI mode unloads it to free RAM for the desktop.
- **Passwordless root for AI mode:** AI mode needs to stop/start system services. The installer adds a
  sudo rule that allows only `/opt/cyberdeck/scripts/ai-mode-root.sh enter|exit|status` (root-owned,
  reads only the root-owned config). Nothing else gets passwordless sudo.
- **Install location:** `/opt/cyberdeck` for scripts, tools, config and data (`/opt/cyberdeck/data`),
  so the setup doesn't depend on where you cloned the repo. Ollama keeps models in its usual place
  (`/usr/share/ollama/.ollama`).
- **Docker:** from Docker's official repository (newest version, includes the Compose plugin). Set
  `DOCKER_SOURCE="ubuntu"` to use Ubuntu's own packages instead. Docker log files are capped at 10 MB.
- **System upgrade:** `install.sh` runs `apt-get upgrade` (skipped if done in the last 6 hours).
  Set `SYSTEM_UPGRADE="false"` to skip it.
- **Auto-start on boot:** systemd for Ollama and Kiwix, and Docker's `restart: unless-stopped` for Open WebUI.
- **Testing:** done in a Linux Mint 22.3 Docker container with systemd, not on a real Beelink. The cloud
  machine it was built on couldn't reach ollama.com, download.kiwix.org, Hugging Face or packages.linuxmint.com.
  So the test pre-installs Ollama from the official `ollama/ollama` Docker image, uses a tiny random-weight
  test model and a small Wikipedia-style test file, and turns off the Mint package repo inside the test machine.
  Everything else ran for real: apt, Docker's repo, pulling Open WebUI, all services, the tool install,
  AI mode on a virtual screen, the offline check with the network unplugged, and a reboot.
  The real downloads (Ollama installer, `qwen3.5:4b`, the 12 GB Wikipedia file) first run on the deck itself.
