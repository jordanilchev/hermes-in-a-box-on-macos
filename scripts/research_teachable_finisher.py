#!/usr/bin/env python3
"""Fill Teachable summary (stub) sections in ~/.hermes/research/*.md.

Deterministic, no LLM — extracts the tweet claim + linked titles into one
portable paragraph Jordan could teach someone else. Newest stubs first.

Usage (on VM as hermes):
  python3 research_teachable_finisher.py              # finish 10 newest
  python3 research_teachable_finisher.py --limit 25
  python3 research_teachable_finisher.py --dry-run
  python3 research_teachable_finisher.py --file path.md
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERMES = Path("/srv/hermes/.hermes")
RESEARCH = HERMES / "research"

STUB_HEADING = "## Teachable summary (stub)"
DONE_HEADING = "## Teachable summary"
STUB_BODY = (
    "Automated pass — review and add a one-paragraph takeaway "
    "Jordan could teach someone else."
)
MAX_WORDS = 120
URL_RE = re.compile(r"https?://[^\s<>\"']+")
TWEET_RE = re.compile(
    r"## Tweet\s*\n+(.*?)(?=\n## |\Z)", re.S | re.I
)
LINKED_RE = re.compile(
    r"### (https?://[^\s]+)\s*\n+(.*?)(?=\n### |\n## |\Z)", re.S | re.I
)
TITLE_RE = re.compile(r"^Title:\s*(.+)$", re.M)


def log(msg: str) -> None:
    print(msg, flush=True)


def clean_text(text: str) -> str:
    text = URL_RE.sub("", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"^[\W_]+|[\W_]+$", "", text)
    return text


def word_clip(text: str, max_words: int = MAX_WORDS) -> str:
    words = text.split()
    if len(words) <= max_words:
        return text
    return " ".join(words[:max_words]).rstrip(",;:") + "…"


def first_sentence(text: str, max_chars: int = 220) -> str:
    text = re.sub(r"\s+", " ", (text or "").strip())
    if not text:
        return ""
    for sep in (". ", "! ", "? "):
        if sep in text[: max_chars + 40]:
            cut = text.find(sep) + 1
            return text[:cut].strip()
    return text[:max_chars].rstrip() + ("…" if len(text) > max_chars else "")


def extract_parts(md: str) -> tuple[str, list[tuple[str, str]]]:
    tweet_m = TWEET_RE.search(md)
    tweet = clean_text(tweet_m.group(1) if tweet_m else "")

    linked: list[tuple[str, str]] = []
    for m in LINKED_RE.finditer(md):
        block = m.group(2).strip()
        if block.startswith("(fetch failed") or block.startswith("(non-html"):
            continue
        title_m = TITLE_RE.search(block)
        title = clean_text(title_m.group(1) if title_m else "")
        # Drop noisy X chrome titles
        if title.lower().startswith(("x.com", "twitter")) or " on X:" in title:
            title = ""
        body = block
        if title_m:
            body = block[title_m.end() :].strip()
        excerpt = first_sentence(clean_text(body), 180)
        if title or excerpt:
            linked.append((title, excerpt))
    return tweet, linked


def craft_summary(tweet: str, linked: list[tuple[str, str]]) -> str:
    """One portable teachable paragraph from tweet + optional linked titles."""
    claim = tweet or (linked[0][0] if linked else "")
    if not claim:
        return (
            "Sparse bookmark — not enough tweet or linked-page text to form a "
            "teachable takeaway yet. Re-open the source or wait for a richer scrape."
        )

    parts: list[str] = []
    # Prefer ending the claim as a complete sentence.
    claim_sent = claim if claim[-1:] in ".!?" else claim.rstrip(".") + "."
    parts.append(claim_sent)

    if linked:
        title, excerpt = linked[0]
        if title and excerpt and excerpt.lower() not in title.lower():
            parts.append(
                f'The linked write-up (“{title}”) adds: {excerpt.rstrip(".")}.'
            )
        elif title:
            parts.append(f'Primary linked source: “{title}”.')
        elif excerpt:
            parts.append(f"Linked page excerpt: {excerpt.rstrip('.')}.")

    # Teaching gloss — transferable question, not a restatement of the tweet.
    parts.append(
        "Teach someone: separate the headline claim from the conditions that "
        "make it true (setup, stack, and what was held constant)."
    )

    return word_clip(" ".join(parts))


def is_stub(md: str) -> bool:
    return STUB_HEADING in md and STUB_BODY in md


def apply_summary(md: str, summary: str) -> str:
    pattern = re.compile(
        rf"{re.escape(STUB_HEADING)}\s*\n+{re.escape(STUB_BODY)}\s*",
        re.M,
    )
    replacement = f"{DONE_HEADING}\n\n{summary}\n\n"
    new_md, n = pattern.subn(replacement, md, count=1)
    if n != 1:
        raise ValueError("stub block not found or already finished")
    return new_md


def finish_file(path: Path, dry_run: bool = False) -> str | None:
    md = path.read_text(encoding="utf-8", errors="replace")
    if not is_stub(md):
        return None
    tweet, linked = extract_parts(md)
    summary = craft_summary(tweet, linked)
    if dry_run:
        return summary
    path.write_text(apply_summary(md, summary), encoding="utf-8")
    return summary


def stub_paths(research: Path) -> list[Path]:
    files = sorted(
        (p for p in research.glob("*.md") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return [p for p in files if is_stub(p.read_text(encoding="utf-8", errors="replace"))]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--research-dir",
        type=Path,
        default=RESEARCH,
        help="research markdown directory",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=10,
        help="max stubs to finish (newest first; default 10)",
    )
    parser.add_argument(
        "--file",
        type=Path,
        action="append",
        default=[],
        help="specific file(s); repeatable",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print summaries without writing",
    )
    args = parser.parse_args(argv)

    research: Path = args.research_dir
    if args.file:
        targets = [p if p.is_absolute() else research / p for p in args.file]
    else:
        if not research.is_dir():
            log(f"error: research dir missing: {research}")
            return 1
        targets = stub_paths(research)[: max(0, args.limit)]

    if not targets:
        log("Teachable finisher: no stubs to process.")
        return 0

    done = 0
    for path in targets:
        if not path.is_file():
            log(f"skip missing: {path}")
            continue
        try:
            summary = finish_file(path, dry_run=args.dry_run)
        except ValueError as exc:
            log(f"skip {path.name}: {exc}")
            continue
        if summary is None:
            log(f"skip {path.name}: not a stub")
            continue
        action = "would finish" if args.dry_run else "finished"
        log(f"{action}: {path.name}")
        log(f"  → {summary[:160]}{'…' if len(summary) > 160 else ''}")
        done += 1

    log(f"Teachable finisher: {done} file(s) {'previewed' if args.dry_run else 'updated'}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
