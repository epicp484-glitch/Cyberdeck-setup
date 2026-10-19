#!/usr/bin/env python3
"""Install the offline Wikipedia tool into Open WebUI and create the
"Cyberdeck AI" chat model that has the tool switched on.

Safe to run again: it updates the tool/model if they changed and does nothing
if they are already up to date. Uses only the Python standard library.

Open WebUI runs with WEBUI_AUTH=False (single user, no login), in which case
signing in returns a token for the built-in admin account.

Usage:
  openwebui_setup.py install --url http://127.0.0.1:3000 --tool-file offline_wikipedia.py \
      --base-model qwen3.5:4b --kiwix-url http://127.0.0.1:8090
  openwebui_setup.py check --url http://127.0.0.1:3000
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

TOOL_ID = "offline_wikipedia"
TOOL_NAME = "Offline Wikipedia"
TOOL_DESCRIPTION = "Looks things up in the offline Wikipedia (Kiwix) on this computer."

SYSTEM_PROMPT = """You are Cyberdeck AI, a helpful assistant running fully offline on a small computer.
You have a tool called search_wikipedia that searches an offline copy of Wikipedia.
For any factual question (science, history, people, places, how things work, definitions), call search_wikipedia first, then answer from the article text it returns.
Keep answers short and clear. At the end of the answer, name the Wikipedia article you used, like: Source: Wikipedia - <article title>.
If the article does not answer the question, say so, then give your best general knowledge and say it is not from Wikipedia.
For small talk or tasks that are not factual questions (writing, maths, coding), just answer normally."""


class Api:
    def __init__(self, base_url: str, timeout: float = 60):
        self.base = base_url.rstrip("/")
        self.timeout = timeout
        self.token: str | None = None

    def request(self, method: str, path: str, body=None, ok_404: bool = False):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            # Open WebUI answers "not found" with 401 or 404 depending on the route.
            if ok_404 and (e.code == 404 or (e.code == 401 and "not found" in detail.lower())):
                return None
            raise SystemExit(f"Open WebUI {method} {path} failed ({e.code}): {detail[:500]}")
        except (urllib.error.URLError, OSError) as e:
            raise SystemExit(f"Can't reach Open WebUI at {self.base}: {getattr(e, 'reason', e)}")

    def wait_until_up(self, seconds: int) -> None:
        deadline = time.time() + seconds
        while True:
            try:
                with urllib.request.urlopen(self.base + "/health", timeout=5) as resp:
                    if resp.status == 200:
                        return
            except (urllib.error.URLError, OSError):
                pass
            if time.time() > deadline:
                raise SystemExit(f"Open WebUI did not come up at {self.base} within {seconds}s")
            time.sleep(3)

    def sign_in(self) -> None:
        res = self.request("POST", "/api/v1/auths/signin", {"email": "admin@localhost", "password": "admin"})
        self.token = (res or {}).get("token")
        if not self.token:
            raise SystemExit(
                "Could not sign in to Open WebUI. The tool can only be installed automatically when "
                "WEBUI_AUTH is off (the default here). Install tools/offline_wikipedia.py by hand: "
                "Workspace > Tools > + > paste the file."
            )


def ensure_tool(api: Api, tool_file: str, valves: dict) -> str:
    with open(tool_file, encoding="utf-8") as f:
        content = f.read()
    form = {
        "id": TOOL_ID,
        "name": TOOL_NAME,
        "content": content,
        "meta": {"description": TOOL_DESCRIPTION, "manifest": {}},
        # Readable by every user of this Open WebUI (there is only one on the deck).
        "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}],
    }
    existing = api.request("GET", f"/api/v1/tools/id/{TOOL_ID}", ok_404=True)
    if existing is None:
        api.request("POST", "/api/v1/tools/create", form)
        result = "installed"
    elif existing.get("content") != content:
        api.request("POST", f"/api/v1/tools/id/{TOOL_ID}/update", form)
        result = "updated"
    else:
        result = "already up to date"

    current = api.request("GET", f"/api/v1/tools/id/{TOOL_ID}/valves", ok_404=True) or {}
    if any(current.get(k) != v for k, v in valves.items()):
        api.request("POST", f"/api/v1/tools/id/{TOOL_ID}/valves/update", {**current, **valves})
        if result == "already up to date":
            result = "settings updated"
    return result


def wait_for_base_model(api: Api, base_model: str, seconds: int) -> None:
    """Open WebUI lists Ollama's models; wait until it sees ours."""
    deadline = time.time() + seconds
    while True:
        res = api.request("GET", "/api/models") or {}
        ids = {m.get("id") for m in res.get("data", [])}
        if base_model in ids or f"{base_model}:latest" in ids:
            return
        if time.time() > deadline:
            raise SystemExit(
                f"Open WebUI can't see the Ollama model '{base_model}' (it sees: {sorted(i for i in ids if i)}). "
                "Is Ollama running and the model downloaded? Try: ollama list"
            )
        time.sleep(3)


def ensure_model(api: Api, model_id: str, name: str, base_model: str, num_ctx: int) -> str:
    form = {
        "id": model_id,
        "base_model_id": base_model,
        "name": name,
        "meta": {
            "description": "Answers from the offline Wikipedia on this deck.",
            "toolIds": [TOOL_ID],
            "capabilities": {"vision": False, "citations": True, "usage": False},
            "suggestion_prompts": [
                {"content": "What is a capacitor?"},
                {"content": "How does photosynthesis work?"},
                {"content": "Who was the first person on the Moon?"},
            ],
        },
        "params": {
            "system": SYSTEM_PROMPT,
            "function_calling": "native",
            "think": False,  # thinking makes a 4B model much slower on an N95
            "num_ctx": num_ctx,
            "temperature": 0.4,
        },
        "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}],
        "is_active": True,
    }
    existing = api.request("GET", f"/api/v1/models/model?id={urllib.request.quote(model_id)}", ok_404=True)
    if existing is None:
        api.request("POST", "/api/v1/models/create", form)
        return "created"
    same = (
        existing.get("base_model_id") == base_model
        and existing.get("name") == name
        and (existing.get("meta") or {}).get("toolIds") == [TOOL_ID]
        and all((existing.get("params") or {}).get(k) == v for k, v in form["params"].items())
    )
    if same:
        return "already up to date"
    api.request("POST", "/api/v1/models/model/update", form)
    return "updated"


def check(api: Api, model_id: str) -> int:
    problems = []
    tool = api.request("GET", f"/api/v1/tools/id/{TOOL_ID}", ok_404=True)
    if not tool:
        problems.append("Wikipedia tool is not installed in Open WebUI")
    model = api.request("GET", f"/api/v1/models/model?id={urllib.request.quote(model_id)}", ok_404=True)
    if not model:
        problems.append(f"chat model '{model_id}' is missing")
    elif TOOL_ID not in ((model.get("meta") or {}).get("toolIds") or []):
        problems.append(f"chat model '{model_id}' does not have the Wikipedia tool switched on")
    for p in problems:
        print(f"problem: {p}", file=sys.stderr)
    if not problems:
        print(f"Open WebUI has the '{TOOL_NAME}' tool and the '{model_id}' model")
    return 1 if problems else 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("action", choices=["install", "check"])
    p.add_argument("--url", default="http://127.0.0.1:3000")
    p.add_argument("--tool-file")
    p.add_argument("--kiwix-url", default="http://127.0.0.1:8090")
    p.add_argument("--kiwix-book", default="")
    p.add_argument("--max-chars", type=int, default=6000)
    p.add_argument("--max-articles", type=int, default=1)
    p.add_argument("--base-model", default="qwen3.5:4b")
    p.add_argument("--model-id", default="cyberdeck-ai")
    p.add_argument("--model-name", default="Cyberdeck AI (Wikipedia)")
    p.add_argument("--num-ctx", type=int, default=8192)
    p.add_argument("--wait", type=int, default=600, help="seconds to wait for Open WebUI to start")
    args = p.parse_args()

    api = Api(args.url)
    api.wait_until_up(args.wait)
    api.sign_in()
    if args.action == "check":
        return check(api, args.model_id)

    if not args.tool_file:
        p.error("--tool-file is required for install")
    valves = {
        "KIWIX_URL": args.kiwix_url,
        "KIWIX_BOOK": args.kiwix_book,
        "MAX_CHARS": args.max_chars,
        "MAX_ARTICLES": args.max_articles,
    }
    print(f"Wikipedia tool: {ensure_tool(api, args.tool_file, valves)}")
    wait_for_base_model(api, args.base_model, 180)
    print(f"Chat model '{args.model_name}': {ensure_model(api, args.model_id, args.model_name, args.base_model, args.num_ctx)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
