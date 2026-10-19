#!/usr/bin/env python3
"""Send one chat through Open WebUI the way the browser does (with a chat id and
message id, so Open WebUI runs tools). Used with fake_tool_ollama.py."""

import json
import time
import urllib.request
import uuid

BASE = "http://127.0.0.1:3000"


def req(path, body=None, tok=None):
    headers = {"Content-Type": "application/json"}
    if tok:
        headers["Authorization"] = "Bearer " + tok
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(urllib.request.Request(BASE + path, data=data, headers=headers), timeout=120) as r:
        return r.read().decode()


tok = json.loads(req("/api/v1/auths/signin", {"email": "admin@localhost", "password": "admin"}))["token"]
for _ in range(30):  # wait until Open WebUI sees the stand-in model
    if any(m["id"] == "fake-tool-caller:latest" for m in json.loads(req("/api/models", tok=tok))["data"]):
        break
    time.sleep(2)
req(
    "/api/chat/completions",
    {
        "model": "fake-tool-caller:latest",
        "chat_id": "local:" + str(uuid.uuid4()),
        "id": str(uuid.uuid4()),
        "messages": [{"role": "user", "content": "what is a capacitor"}],
        "tool_ids": ["offline_wikipedia"],
        "stream": True,
        "params": {"function_calling": "native"},
    },
    tok,
)
print("chat sent")
