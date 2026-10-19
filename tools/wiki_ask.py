#!/usr/bin/env python3
"""wiki-ask: ask the local AI a question, answered from the offline Wikipedia.

Examples:
  wiki-ask "what is a capacitor"
  wiki-ask --no-ai "Apollo 11"          # just show the Wikipedia text it found
  wiki-ask --model qwen3.5:2b "how do plants make food"

Settings come from /opt/cyberdeck/config.env (or the repo's config.env) and can
be overridden with the options below.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import textwrap
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import offline_wikipedia as wiki  # noqa: E402

CONFIG_CANDIDATES = [
    os.environ.get("CYBERDECK_CONFIG_DIR", ""),
    os.path.join(os.path.dirname(os.path.realpath(__file__)), ".."),
    "/opt/cyberdeck",
]


def load_config() -> dict:
    """Read config.env (+ config.local.env) by letting bash evaluate it."""
    for d in CONFIG_CANDIDATES:
        path = os.path.join(d, "config.env") if d else ""
        if path and os.path.isfile(path):
            local = os.path.join(d, "config.local.env")
            script = f"set -a; source {shlex.quote(path)}; "
            if os.path.isfile(local):
                script += f"source {shlex.quote(local)}; "
            script += "env -0"
            try:
                out = subprocess.run(["bash", "-c", script], capture_output=True, check=True).stdout
            except (OSError, subprocess.CalledProcessError):
                continue
            return dict(item.split("=", 1) for item in out.decode().split("\0") if "=" in item)
    return {}


def ask_ollama(url: str, model: str, question: str, context: str, articles, num_ctx: int, stream_out) -> str:
    user_msg = f"Wikipedia text:\n\n{context}\n\nQuestion: {question}"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": wiki.SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        "stream": True,
        "think": False,  # thinking is slow on a small CPU; the article already has the facts
        "options": {"num_ctx": num_ctx, "temperature": 0.3},
    }

    def post(body: dict):
        req = urllib.request.Request(
            url.rstrip("/") + "/api/chat",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        return urllib.request.urlopen(req, timeout=600)

    try:
        resp = post(payload)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        if "think" in detail.lower():  # model without a thinking switch
            payload.pop("think")
            resp = post(payload)
        else:
            raise SystemExit(f"Ollama error ({e.code}): {detail.strip()}")
    except (urllib.error.URLError, OSError) as e:
        raise SystemExit(
            f"Can't reach Ollama at {url} ({getattr(e, 'reason', e)}). Try: systemctl status ollama"
        )

    answer = []
    with resp:
        for line in resp:
            if not line.strip():
                continue
            chunk = json.loads(line)
            if chunk.get("error"):
                raise SystemExit(f"Ollama error: {chunk['error']}")
            piece = chunk.get("message", {}).get("content", "")
            if piece:
                answer.append(piece)
                if stream_out:
                    stream_out.write(piece)
                    stream_out.flush()
            if chunk.get("done"):
                break
    text = "".join(answer)
    # Make sure the article is always named, even if the model forgot.
    if not all(a.title.lower() in text.lower() for a in articles):
        extra = f"\n\n{wiki.sources_line(articles)}"
        if stream_out:
            stream_out.write(extra)
        text += extra
    if stream_out:
        stream_out.write("\n")
    return text


def main(argv=None) -> int:
    cfg = load_config()
    p = argparse.ArgumentParser(
        prog="wiki-ask",
        description="Ask the local AI a question using the offline Wikipedia.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(__doc__.split("Examples:", 1)[1]) if __doc__ else None,
    )
    p.add_argument("question", nargs="+", help="your question")
    p.add_argument("--no-ai", action="store_true", help="only show the Wikipedia text, don't ask the model")
    p.add_argument("--json", action="store_true", help="print the result as JSON")
    p.add_argument("--model", default=cfg.get("OLLAMA_MODEL", "qwen3.5:4b"))
    p.add_argument("--kiwix-url", default=f"http://127.0.0.1:{cfg.get('KIWIX_PORT', '8090')}")
    p.add_argument("--ollama-url", default=f"http://127.0.0.1:{cfg.get('OLLAMA_PORT', '11434')}")
    p.add_argument("--book", default=cfg.get("KIWIX_BOOK", ""), help="Kiwix book name (default: auto)")
    p.add_argument("--max-chars", type=int, default=int(cfg.get("WIKI_MAX_CHARS", "6000") or 6000))
    p.add_argument("--articles", type=int, default=int(cfg.get("WIKI_MAX_ARTICLES", "1") or 1))
    args = p.parse_args(argv)
    question = " ".join(args.question)

    try:
        articles = wiki.lookup(question, args.kiwix_url, args.book, args.max_chars, args.articles)
    except wiki.WikiError as e:
        print(f"wiki-ask: {e}", file=sys.stderr)
        return 2

    if not articles:
        msg = f'No Wikipedia article found for "{question}".'
        print(json.dumps({"question": question, "articles": [], "error": msg}) if args.json else msg)
        return 1

    context = wiki.format_context(articles)
    sources = wiki.sources_line(articles)
    if args.no_ai:
        if args.json:
            print(json.dumps({"question": question, "articles": [{"title": a.title, "url": a.url, "text": a.text} for a in articles]}, indent=2))
        else:
            print(context)
            print(f"\n{sources}")
        return 0

    num_ctx = int(cfg.get("OLLAMA_CONTEXT_LENGTH", "8192") or 8192)
    if not args.json:
        print(f"📖 Using Wikipedia: {', '.join(a.title for a in articles)}\n", file=sys.stderr)
    answer = ask_ollama(args.ollama_url, args.model, question, context, articles, num_ctx, None if args.json else sys.stdout)
    if args.json:
        print(json.dumps({"question": question, "answer": answer, "articles": [{"title": a.title, "url": a.url} for a in articles]}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
