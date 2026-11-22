#!/usr/bin/env python3
"""Fetch new X bookmarks, research linked URLs, save to ~/.hermes/research/.

Runs on the VM host (cron --no-agent). No LLM — deterministic fetch + URL scrape
+ teachable summary (via research_teachable_finisher).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from html import unescape
from pathlib import Path

HERMES = Path("/srv/hermes/.hermes")
SCRIPTS = HERMES / "scripts"
RESEARCH = HERMES / "research"
STATE_FILE = RESEARCH / "state.json"
FETCH = SCRIPTS / "twitter_bookmark_fetch.sh"

# Sibling module: deployed beside this file in ~/.hermes/scripts/.
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))
from research_teachable_finisher import (  # noqa: E402
    DONE_HEADING,
    craft_summary,
    extract_parts,
)

MAX_NEW = int(__import__("os").environ.get("BOOKMARK_RESEARCH_MAX", "3"))
FETCH_COUNT = int(__import__("os").environ.get("BOOKMARK_FETCH_COUNT", "15"))
URL_TIMEOUT = 15
URL_BYTES = 120_000


def log(msg: str) -> None:
    print(msg, flush=True)


def load_state() -> dict:
    if STATE_FILE.is_file():
        return json.loads(STATE_FILE.read_text())
    return {"processed_ids": [], "last_run": None}


def save_state(state: dict) -> None:
    RESEARCH.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def fetch_bookmarks() -> list[dict]:
    if not FETCH.is_file():
        raise FileNotFoundError(f"missing fetch script: {FETCH}")
    proc = subprocess.run(
        [str(FETCH), str(FETCH_COUNT)],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "fetch failed")
    data = json.loads(proc.stdout)
    if not data.get("successful"):
        raise RuntimeError(json.dumps(data))
    return (data.get("data") or {}).get("data") or []


def urls_in_text(text: str) -> list[str]:
    return re.findall(r"https?://[^\s<>\"']+", text or "")


def scrape_url(url: str) -> str:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "hermes-bookmark-research/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=URL_TIMEOUT) as resp:
            raw = resp.read(URL_BYTES)
            ctype = resp.headers.get("Content-Type", "")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return f"(fetch failed: {exc})"

    if "html" not in ctype.lower():
        return f"(non-html content-type: {ctype or 'unknown'})"

    text = raw.decode("utf-8", errors="replace")
    title_m = re.search(r"<title[^>]*>([^<]+)</title>", text, re.I)
    title = unescape(title_m.group(1).strip()) if title_m else ""
    body = re.sub(r"(?is)<script.*?>.*?</script>", " ", text)
    body = re.sub(r"(?is)<style.*?>.*?</style>", " ", body)
    body = re.sub(r"<[^>]+>", " ", body)
    body = unescape(re.sub(r"\s+", " ", body)).strip()
    excerpt = body[:1500] + ("…" if len(body) > 1500 else "")
    if title:
        return f"Title: {title}\n\n{excerpt}"
    return excerpt or "(empty page)"


def slug(text: str, max_len: int = 48) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", (text or "untitled").lower()).strip("-")
    return (s[:max_len] or "untitled").strip("-")


def research_bookmark(item: dict) -> Path:
    tweet_id = str(item.get("id") or item.get("tweet_id") or "unknown")
    text = item.get("text") or ""
    created = item.get("created_at") or ""
    urls = urls_in_text(text)

    sections = [
        f"# Bookmark research — {tweet_id}",
        "",
        f"- **Saved:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        f"- **Tweet created:** {created}",
        "",
        "## Tweet",
        "",
        text,
        "",
    ]

    if urls:
        sections.append("## Linked pages")
        sections.append("")
        for url in urls[:3]:
            sections.extend([f"### {url}", "", scrape_url(url), ""])
    else:
        sections.extend(["## Notes", "", "No external URLs in tweet text.", ""])

    body = "\n".join(sections) + "\n"
    tweet_clean, linked = extract_parts(body)
    summary = craft_summary(tweet_clean, linked)
    body = body + f"{DONE_HEADING}\n\n{summary}\n"

    out = RESEARCH / f"{tweet_id}-{slug(text)}.md"
    out.write_text(body)
    return out


def main() -> int:
    RESEARCH.mkdir(parents=True, exist_ok=True)
    state = load_state()
    processed = set(state.get("processed_ids") or [])

    items = fetch_bookmarks()
    new_items = [it for it in items if str(it.get("id")) not in processed]

    if not new_items:
        log("Bookmark research: no new bookmarks to process.")
        state["last_run"] = datetime.now(timezone.utc).isoformat()
        save_state(state)
        return 0

    saved: list[str] = []
    for item in new_items[:MAX_NEW]:
        tweet_id = str(item.get("id"))
        path = research_bookmark(item)
        processed.add(tweet_id)
        saved.append(f"- `{path.name}` — {(item.get('text') or '')[:80]}…")

    state["processed_ids"] = sorted(processed, reverse=True)[:5000]
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    save_state(state)

    log(f"Bookmark research: saved {len(saved)} new deep dive(s) under {RESEARCH}/")
    for line in saved:
        log(line)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log(f"Bookmark research error: {exc}")
        raise SystemExit(1) from exc
