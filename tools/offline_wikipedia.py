"""
title: Offline Wikipedia
author: cyberdeck
description: Look things up in the offline Wikipedia served by the local Kiwix server, so answers are based on (and name) a real Wikipedia article. Works with no internet.
version: 1.0.0
license: MIT
"""

# This one file is used two ways:
#   1. Uploaded into Open WebUI as a Tool (the `Tools` class at the bottom).
#   2. Imported by the `wiki-ask` command-line tool (tools/wiki_ask.py).
# It only uses the Python standard library (plus pydantic, which Open WebUI
# already has), so it runs anywhere with no extra installs and no internet.

import asyncio
import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from html.parser import HTMLParser

try:  # Open WebUI provides pydantic; the CLI works without it.
    from pydantic import BaseModel, Field
except ImportError:  # pragma: no cover - only hit outside Open WebUI
    BaseModel = object  # type: ignore[misc,assignment]

    def Field(default=None, **_kwargs):  # type: ignore[no-redef]
        return default


DEFAULT_KIWIX_URL = "http://127.0.0.1:8090"
DEFAULT_MAX_CHARS = 6000

# Words that say nothing about the topic. Stripped from questions before
# looking up article titles ("what is a capacitor" -> "capacitor").
STOPWORDS = set(
    """
    a about above after again against all am an and any are as at be because been
    before being below between both but by can could did do does doing down during
    each explain few for from further had has have having he her here hers herself
    him himself his how i if in into is it its itself just know let me more most my
    myself no nor not now of off on once only or other our ours ourselves out over
    own please same she should so some such tell than that the their theirs them
    themselves then there these they this those through to too under until up very
    was we were what when where which while who whom why will with would you your
    yours yourself yourselves define definition meaning mean means describe give
    information info wikipedia article whats what's who's thing things work works
    """.split()
)


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
@dataclass
class Candidate:
    title: str
    path: str  # path inside the book, e.g. "A/Capacitor" or "Capacitor"
    score: float = 0.0


@dataclass
class Article:
    title: str
    path: str
    url: str
    text: str
    paragraphs: list[str] = field(default_factory=list)


class WikiError(Exception):
    """Something went wrong talking to Kiwix (message is human readable)."""


# ---------------------------------------------------------------------------
# HTML -> clean text
# ---------------------------------------------------------------------------
class _ArticleParser(HTMLParser):
    """Turns a Wikipedia article page into a title + list of plain paragraphs.

    Drops scripts, styles, reference markers, navigation boxes and most tables.
    Infobox rows are kept as "Label: value" lines because they hold compact
    facts that small models answer well from.
    """

    SKIP_TAGS = {"script", "style", "noscript", "sup", "math", "svg", "figure", "nav", "footer", "button", "audio", "video"}
    SKIP_CLASS_WORDS = (
        "navbox", "reflist", "references", "reference", "mw-editsection", "hatnote",
        "metadata", "noprint", "toc", "thumb", "gallery", "mw-empty-elt", "sistersitebox",
        "ambox", "mbox", "shortdescription", "mw-cite-backlink", "catlinks", "printfooter",
    )
    BLOCK_TAGS = {"p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "dd", "dt", "blockquote", "pre", "tr", "caption", "div", "section", "br"}
    STOP_SECTIONS = {"references", "external links", "see also", "further reading", "notes", "bibliography", "sources", "citations", "footnotes"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.blocks: list[str] = []
        self._buf: list[str] = []
        self._skip_stack: list[str] = []  # tags we are skipping inside
        self._in_title = False
        self._title_tag = ""  # text of <title>, used if the page has no <h1>
        self._in_h1 = False
        self._heading: str | None = None
        self._stopped = False
        self._table_depth = 0
        self._infobox_depth = 0
        self._cell_texts: list[str] = []
        self._in_cell = False

    # -- helpers ---------------------------------------------------------
    def _flush(self) -> None:
        text = _squash("".join(self._buf))
        self._buf = []
        if not text or self._stopped:
            return
        if self._heading is not None:
            if text.lower().strip(" :") in self.STOP_SECTIONS:
                self._stopped = True
                return
            text = f"## {text}"
            self._heading = None
        self.blocks.append(text)

    def _should_skip(self, tag: str, attrs: dict) -> bool:
        if tag in self.SKIP_TAGS:
            return True
        cls = (attrs.get("class") or "").lower()
        if any(word in cls.split() or word in cls for word in self.SKIP_CLASS_WORDS):
            return True
        if attrs.get("role") in {"navigation", "note"}:
            return True
        style = (attrs.get("style") or "").replace(" ", "").lower()
        return "display:none" in style

    # -- parser callbacks --------------------------------------------------
    def handle_starttag(self, tag, attrs_list):
        attrs = dict(attrs_list)
        if self._skip_stack:
            if tag not in ("br", "img", "hr", "meta", "link", "input", "wbr"):
                self._skip_stack.append(tag)
            return
        if tag == "title":
            self._in_title = True
            return
        if tag == "br":
            self._buf.append("\n")
            return
        if tag == "table":
            self._table_depth += 1
            cls = (attrs.get("class") or "").lower()
            if "infobox" in cls and not self._infobox_depth:
                self._flush()
                self._infobox_depth = self._table_depth
            elif not self._infobox_depth:
                self._skip_stack.append(tag)  # ordinary tables are noisy for a small model
            return
        if self._should_skip(tag, attrs):
            self._skip_stack.append(tag)
            return
        if self._infobox_depth:
            if tag in ("th", "td"):
                self._in_cell = True
                self._buf = []
            return
        if tag in self.BLOCK_TAGS:
            self._flush()
        if tag in ("h2", "h3", "h4"):
            self._heading = tag
        if tag == "h1":
            self._in_h1 = True

    def handle_endtag(self, tag):
        if self._skip_stack:
            # Pop until the matching tag (HTML in the wild is not always balanced).
            if tag in self._skip_stack:
                while self._skip_stack:
                    if self._skip_stack.pop() == tag:
                        break
            if tag == "table" and self._table_depth:
                self._table_depth -= 1
            return
        if tag == "title":
            self._in_title = False
            return
        if tag == "table":
            if self._infobox_depth == self._table_depth:
                self._infobox_depth = 0
            self._table_depth = max(0, self._table_depth - 1)
            return
        if self._infobox_depth:
            if tag in ("th", "td") and self._in_cell:
                self._cell_texts.append(_squash("".join(self._buf)))
                self._buf = []
                self._in_cell = False
            elif tag == "tr":
                cells = [c for c in self._cell_texts if c]
                self._cell_texts = []
                if len(cells) >= 2:
                    self.blocks.append(f"{cells[0]}: {' '.join(cells[1:])}")
                elif len(cells) == 1 and not self._stopped and len(cells[0]) < 200:
                    self.blocks.append(cells[0])
            return
        if tag == "h1" and self._in_h1:
            self._in_h1 = False
            heading = _squash("".join(self._buf))
            self._buf = []
            if heading and not self.title:
                self.title = heading
            return
        if tag in self.BLOCK_TAGS:
            self._flush()

    def handle_data(self, data):
        if self._skip_stack:
            return
        if self._in_title:
            self._title_tag += data
            return
        if self._infobox_depth and not self._in_cell:
            return
        self._buf.append(data)

    def close(self):
        super().close()
        self._flush()
        if not self.title:
            self.title = _squash(self._title_tag)


def _squash(text: str) -> str:
    text = text.replace("\xa0", " ")
    text = re.sub(r"\[\s*(\d+|[a-z]|citation needed|note \d+|nb \d+)\s*\]", "", text, flags=re.I)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\s*\n\s*", " ", text)
    text = re.sub(r"\s+([,.;:)])", r"\1", text)
    text = re.sub(r"\(\s*\)", "", text)
    return text.strip()


def clean_article_html(page_html: str) -> tuple[str, list[str]]:
    """Return (title, paragraphs) from a raw article page."""
    parser = _ArticleParser()
    try:
        parser.feed(page_html)
        parser.close()
    except Exception:  # never let odd HTML crash a lookup
        pass
    paragraphs = [b for b in parser.blocks if len(b) > 1]
    # Drop exact duplicates while keeping order.
    seen: set[str] = set()
    unique = []
    for p in paragraphs:
        if p not in seen:
            seen.add(p)
            unique.append(p)
    return parser.title, unique


# ---------------------------------------------------------------------------
# Picking the useful text
# ---------------------------------------------------------------------------
def keywords(question: str) -> list[str]:
    words = re.findall(r"[\w'’-]+", question.lower())
    out = []
    for w in words:
        w = w.strip("'’-")
        if w and w not in STOPWORDS and (len(w) > 1 or w.isdigit()):
            out.append(w)
    return out


def _trim_to_sentence(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    if end > limit * 0.5:
        return cut[: end + 1]
    return cut.rsplit(" ", 1)[0] + " …"


def select_text(paragraphs: list[str], question: str, max_chars: int) -> str:
    """Fit an article into max_chars.

    The introduction (everything before the first section heading, plus the
    infobox) is always kept first because that is where Wikipedia summarises a
    topic. Remaining room goes to the paragraphs that share the most words
    with the question, kept in article order so the text still reads well.
    """
    if not paragraphs:
        return ""
    # Everything before the first "## heading" is the introduction.
    intro: list[tuple[int, str]] = []
    rest: list[tuple[int, str]] = []
    for i, p in enumerate(paragraphs):
        (rest if rest or p.startswith("## ") else intro).append((i, p))

    chosen: list[tuple[int, str]] = []
    used = 0
    for i, p in intro:
        if used >= max_chars:
            break
        piece = _trim_to_sentence(p, max_chars - used)
        chosen.append((i, piece))
        used += len(piece) + 2

    if used < max_chars and rest:
        kw = set(keywords(question))
        scored = []
        for idx, p in rest:
            if p.startswith("## "):
                continue
            words = set(re.findall(r"\w+", p.lower()))
            overlap = len(kw & words)
            scored.append((overlap, -idx, idx, p))
        scored.sort(reverse=True)
        for overlap, _neg, idx, p in scored:
            if used >= max_chars - 80:
                break
            if overlap == 0 and used > max_chars * 0.6:
                continue
            piece = _trim_to_sentence(p, max_chars - used)
            if len(piece) < 40:
                continue
            chosen.append((idx, piece))
            used += len(piece) + 2

    chosen.sort(key=lambda t: t[0])
    return "\n\n".join(p for _, p in chosen).strip()


# ---------------------------------------------------------------------------
# Kiwix client
# ---------------------------------------------------------------------------
class _LinkCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str]] = []
        self._href: str | None = None
        self._text: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href = dict(attrs).get("href")
            self._text = []

    def handle_data(self, data):
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.links.append((self._href, _squash("".join(self._text))))
            self._href = None


class KiwixClient:
    """Tiny client for kiwix-serve's HTTP API (works with kiwix-tools 3.x)."""

    def __init__(self, base_url: str = DEFAULT_KIWIX_URL, book: str = "", timeout: float = 15.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._book = book.strip()

    # -- HTTP ----------------------------------------------------------------
    def _get(self, path: str, params: dict | None = None) -> str:
        url = self.base_url + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"User-Agent": "cyberdeck-wiki/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                charset = resp.headers.get_content_charset() or "utf-8"
                return resp.read().decode(charset, errors="replace")
        except urllib.error.HTTPError as e:
            raise WikiError(f"Kiwix returned HTTP {e.code} for {path}") from e
        except (urllib.error.URLError, OSError) as e:
            raise WikiError(
                f"Can't reach the Kiwix server at {self.base_url} ({getattr(e, 'reason', e)}). "
                "Is it running? Try: systemctl status cyberdeck-kiwix"
            ) from e

    # -- books ---------------------------------------------------------------
    def list_books(self) -> list[dict]:
        """Books served by Kiwix: [{'id': 'wikipedia_en_all_mini_2026-06', 'title': ..., 'name': ...}]."""
        books: list[dict] = []
        try:
            xml_text = self._get("/catalog/v2/entries", {"count": "-1"})
            root = ET.fromstring(xml_text)
            ns = {"a": "http://www.w3.org/2005/Atom"}
            for entry in root.findall("a:entry", ns):
                title = (entry.findtext("a:title", default="", namespaces=ns) or "").strip()
                name = (entry.findtext("a:name", default="", namespaces=ns) or "").strip()
                for link in entry.findall("a:link", ns):
                    href = link.get("href", "")
                    if link.get("type", "").startswith("text/html") and "/content/" in href:
                        books.append({"id": href.rstrip("/").split("/content/", 1)[1].split("/")[0], "title": title, "name": name})
                        break
        except (WikiError, ET.ParseError):
            pass
        if not books:  # older servers: scrape the welcome page
            try:
                collector = _LinkCollector()
                collector.feed(self._get("/"))
                for href, text in collector.links:
                    m = re.search(r"/content/([^/?#]+)", href or "")
                    if m and not any(b["id"] == m.group(1) for b in books):
                        books.append({"id": m.group(1), "title": text, "name": m.group(1)})
            except WikiError:
                raise
        return books

    @property
    def book(self) -> str:
        if not self._book:
            books = self.list_books()
            if not books:
                raise WikiError("The Kiwix server is running but has no .zim files loaded.")
            wiki = [b for b in books if b["id"].lower().startswith("wikipedia") or b["name"].lower().startswith("wikipedia")]
            self._book = (wiki or books)[0]["id"]
        return self._book

    def article_url(self, path: str) -> str:
        return f"{self.base_url}/content/{self.book}/{path.lstrip('/')}"

    # -- search --------------------------------------------------------------
    def _path_from_href(self, href: str) -> str | None:
        href = html.unescape(href or "")
        parsed = urllib.parse.urlparse(href)
        m = re.search(r"/content/([^/]+)/(.+)$", parsed.path)
        if not m or m.group(1) != self.book:
            return None
        return urllib.parse.unquote(m.group(2))

    def suggest(self, term: str, count: int = 8) -> list[Candidate]:
        """Title search (fast, good when the question names the topic)."""
        for params in ({"books.name": self.book, "term": term, "count": count},
                       {"content": self.book, "term": term, "count": count}):
            try:
                data = json.loads(self._get("/suggest", params))
            except (WikiError, ValueError):
                continue
            out = []
            for item in data if isinstance(data, list) else []:
                if item.get("kind") == "pattern":
                    continue
                path = item.get("path") or item.get("value")
                title = html.unescape(re.sub(r"<[^>]+>", "", item.get("label") or item.get("value") or ""))
                if path and title:
                    out.append(Candidate(title=title, path=urllib.parse.unquote(path)))
            return out
        return []

    def search(self, query: str, count: int = 8) -> list[Candidate]:
        """Full-text search (finds articles that talk about the question)."""
        attempts = [
            ("xml", {"books.name": self.book, "pattern": query, "pageLength": count, "format": "xml"}),
            ("html", {"books.name": self.book, "pattern": query, "pageLength": count}),
            ("html", {"content": self.book, "pattern": query, "pageLength": count}),
        ]
        for kind, params in attempts:
            try:
                body = self._get("/search", params)
            except WikiError:
                continue
            results: list[Candidate] = []
            if kind == "xml":
                try:
                    root = ET.fromstring(body)
                except ET.ParseError:
                    continue
                for item in root.iter("item"):
                    title = (item.findtext("title") or "").strip()
                    path = self._path_from_href(item.findtext("link") or "")
                    if title and path:
                        results.append(Candidate(title=title, path=path))
            else:
                collector = _LinkCollector()
                collector.feed(body)
                for href, text in collector.links:
                    path = self._path_from_href(href)
                    if path and text and not any(r.path == path for r in results):
                        results.append(Candidate(title=text, path=path))
            if results:
                return results[:count]
        return []

    def fetch(self, path: str) -> str:
        quoted = urllib.parse.quote(path, safe="/:@!$&'()*+,;=-._~")
        return self._get(f"/content/{self.book}/{quoted}")


# ---------------------------------------------------------------------------
# The lookup itself
# ---------------------------------------------------------------------------
def _title_overlap(title: str, kw: list[str]) -> float:
    if not kw:
        return 0.0
    words = set(re.findall(r"\w+", title.lower()))
    return sum(1 for k in kw if k in words) / len(kw)


def rank_candidates(question: str, suggestions: list[Candidate], fulltext: list[Candidate]) -> list[Candidate]:
    kw = keywords(question)
    phrase = " ".join(kw)
    merged: dict[str, Candidate] = {}

    def add(c: Candidate, base: float) -> None:
        key = c.path.lower()
        cur = merged.setdefault(key, Candidate(c.title, c.path, 0.0))
        cur.score += base

    for i, c in enumerate(suggestions):
        add(c, max(0.5, 3.0 - 0.4 * i))
    for i, c in enumerate(fulltext):
        add(c, max(0.3, 2.5 - 0.3 * i))
    for c in merged.values():
        t = c.title.lower().strip()
        c.score += 2.0 * _title_overlap(c.title, kw)
        if phrase and t == phrase:
            c.score += 5.0
        elif phrase and (t == phrase + "s" or t + "s" == phrase):
            c.score += 4.0
        if "(disambiguation)" in t or t.startswith("list of"):
            c.score -= 3.0
        # Titles much longer than the question are usually more specific topics.
        extra = len(re.findall(r"\w+", t)) - max(1, len(kw))
        if extra > 0:
            c.score -= 0.25 * extra
    return sorted(merged.values(), key=lambda c: c.score, reverse=True)


def _looks_like_disambiguation(paragraphs: list[str]) -> bool:
    head = " ".join(paragraphs[:3]).lower()
    return "may refer to" in head or "may also refer to" in head


def lookup(
    question: str,
    kiwix_url: str = DEFAULT_KIWIX_URL,
    book: str = "",
    max_chars: int = DEFAULT_MAX_CHARS,
    max_articles: int = 1,
    timeout: float = 15.0,
) -> list[Article]:
    """Find the best Wikipedia article(s) for a question and return trimmed text.

    Raises WikiError if Kiwix can't be reached. Returns [] if nothing matched.
    """
    question = question.strip()
    if not question:
        return []
    client = KiwixClient(kiwix_url, book=book, timeout=timeout)
    kw = keywords(question)
    term = " ".join(kw) or question
    suggestions = client.suggest(term)
    if not suggestions and len(kw) > 1:
        # Try the most specific-looking word on its own ("capacitor" in "how does a capacitor store energy").
        suggestions = client.suggest(max(kw, key=len))
    fulltext = client.search(term)
    if term != question:
        for c in client.search(question):
            if not any(f.path == c.path for f in fulltext):
                fulltext.append(c)
    if not suggestions and not fulltext and len(kw) > 1:
        # Kiwix full-text search wants every word to match. Search each keyword
        # on its own and prefer articles that turn up for several of them.
        hits: dict[str, Candidate] = {}
        for word in sorted(kw, key=len, reverse=True)[:5]:
            for i, c in enumerate(client.search(word)):
                cur = hits.setdefault(c.path, Candidate(c.title, c.path, 0.0))
                cur.score += 1.0 - 0.05 * i
        fulltext = [c for c in sorted(hits.values(), key=lambda c: c.score, reverse=True) if c.score >= 1.5]
    ranked = rank_candidates(question, suggestions, fulltext)

    articles: list[Article] = []
    budget = max(500, int(max_chars))
    per_article = budget // max(1, max_articles)
    for cand in ranked[: max_articles + 4]:
        if len(articles) >= max_articles:
            break
        try:
            page = client.fetch(cand.path)
        except WikiError:
            continue
        title, paragraphs = clean_article_html(page)
        if not paragraphs or _looks_like_disambiguation(paragraphs):
            continue
        text = select_text(paragraphs, question, per_article)
        if len(text) < 40:
            continue
        articles.append(
            Article(
                title=title or cand.title,
                path=cand.path,
                url=client.article_url(cand.path),
                text=text,
                paragraphs=paragraphs,
            )
        )
    return articles


def format_context(articles: list[Article]) -> str:
    """Text handed to the model."""
    parts = []
    for a in articles:
        parts.append(f'=== Wikipedia article: "{a.title}" ===\n{a.text}')
    return "\n\n".join(parts)


def sources_line(articles: list[Article]) -> str:
    names = ", ".join(f'"{a.title}"' for a in articles)
    return f"Source: offline Wikipedia, article {names}" if len(articles) == 1 else f"Sources: offline Wikipedia, articles {names}"


SYSTEM_PROMPT = (
    "You are a helpful offline assistant on a small computer with no internet. "
    "Answer the user's question using the Wikipedia text provided. "
    "Keep the answer short and clear. If the text does not contain the answer, say so "
    "and give your best general knowledge, clearly marked as not from Wikipedia. "
    "Finish with one line naming the Wikipedia article you used, like: Source: Wikipedia - <title>."
)


# ---------------------------------------------------------------------------
# Open WebUI tool
# ---------------------------------------------------------------------------
class Tools:
    class Valves(BaseModel):
        KIWIX_URL: str = Field(
            default=DEFAULT_KIWIX_URL,
            description="Address of the local Kiwix server.",
        )
        KIWIX_BOOK: str = Field(
            default="",
            description="Kiwix book to search. Leave empty to use the first Wikipedia book.",
        )
        MAX_CHARS: int = Field(
            default=DEFAULT_MAX_CHARS,
            description="Maximum characters of article text given to the model (~4 chars per token).",
        )
        MAX_ARTICLES: int = Field(default=1, description="How many articles to include.")

    def __init__(self):
        self.valves = self.Valves()
        # We send our own citation (with the article title and link) below.
        self.citation = False

    async def search_wikipedia(self, query: str, __event_emitter__=None) -> str:
        """
        Look up a topic in the offline Wikipedia on this computer and return the article text.
        Use this for any factual question (science, history, people, places, how things work).
        Base your answer on the returned text and name the Wikipedia article you used.
        :param query: The topic or question to look up, e.g. "capacitor" or "who built the pyramids".
        :return: The most relevant Wikipedia article text, trimmed to fit.
        """

        async def status(text: str, done: bool = False) -> None:
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": text, "done": done}})

        await status(f"Searching offline Wikipedia for: {query}")
        try:
            articles = await asyncio.to_thread(
                lookup,
                query,
                self.valves.KIWIX_URL,
                self.valves.KIWIX_BOOK,
                int(self.valves.MAX_CHARS),
                int(self.valves.MAX_ARTICLES),
            )
        except WikiError as e:
            await status("Offline Wikipedia is not reachable", done=True)
            return f"The offline Wikipedia could not be searched: {e}"

        if not articles:
            await status("No Wikipedia article found", done=True)
            return (
                f'No article about "{query}" was found in the offline Wikipedia. '
                "Tell the user that, then answer from general knowledge and say it is not from Wikipedia."
            )

        if __event_emitter__:
            for a in articles:
                await __event_emitter__(
                    {
                        "type": "citation",
                        "data": {
                            "document": [a.text],
                            "metadata": [{"source": a.url, "name": f"Wikipedia: {a.title}"}],
                            "source": {"name": f"Wikipedia: {a.title}", "url": a.url},
                        },
                    }
                )
        titles = ", ".join(a.title for a in articles)
        await status(f"Read Wikipedia: {titles}", done=True)
        return (
            format_context(articles)
            + "\n\n(Answer from the text above. End your answer with: Source: Wikipedia - "
            + titles
            + ")"
        )
