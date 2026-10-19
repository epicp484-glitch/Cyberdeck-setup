#!/usr/bin/env python3
"""A stand-in for Ollama that always decides to call the Wikipedia tool.

A tiny random-weight test model can't make tool calls, so this checks the
Open WebUI side of the chain for real: Open WebUI must pass the tool to the
"model", run search_wikipedia (which talks to the real Kiwix server) when the
model asks for it, and send the article text back. The stand-in then answers
with the start of that text, so the test can see it arrived.

Usage: fake_tool_ollama.py [PORT]   (default 11434)
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "fake-tool-caller:latest"


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("fake-ollama: " + fmt % args + "\n")

    def do_GET(self):
        if self.path.startswith("/api/version"):
            return self._json({"version": "0.40.6"})
        if self.path.startswith("/api/tags"):
            return self._json({"models": [{"name": MODEL, "model": MODEL, "size": 1, "digest": "0" * 64,
                                           "details": {"family": "fake", "parameter_size": "0B", "quantization_level": "F32"}}]})
        if self.path.startswith("/api/ps"):
            return self._json({"models": []})
        if self.path == "/":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Ollama is running")
            return
        self._json({"error": "not found"}, 404)

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(length) or b"{}")
        if self.path.startswith("/api/show"):
            return self._json({"capabilities": ["completion", "tools"], "details": {"family": "fake"}, "model_info": {}})
        if not self.path.startswith("/api/chat"):
            return self._json({"error": "not supported"}, 404)

        messages = req.get("messages", [])
        tool_names = [t.get("function", {}).get("name") for t in req.get("tools") or []]
        sys.stderr.write(f"fake-ollama: chat with {len(messages)} messages, tools offered: {tool_names}\n")
        tool_msgs = [m for m in messages if m.get("role") == "tool"]
        if tool_msgs:
            text = str(tool_msgs[-1].get("content", ""))
            sys.stderr.write("fake-ollama: TOOL RESULT: " + " ".join(text.split())[:200] + "\n")
            message = {"role": "assistant", "content": "TOOL RESULT RECEIVED: " + " ".join(text.split())[:300]}
        elif "search_wikipedia" in tool_names:
            message = {"role": "assistant", "content": "",
                       "tool_calls": [{"function": {"name": "search_wikipedia", "arguments": {"query": "capacitor"}}}]}
        else:
            message = {"role": "assistant", "content": "NO TOOLS WERE OFFERED"}

        final = {"model": MODEL, "created_at": "2026-01-01T00:00:00Z", "message": message, "done": True,
                 "done_reason": "stop", "total_duration": 1, "eval_count": 1, "prompt_eval_count": 1}
        if req.get("stream", True):
            body = (json.dumps(final) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._json(final)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11434
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
