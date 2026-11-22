---
name: research-teachable
description: >-
  Fill or refresh deterministic Teachable summary paragraphs on bookmark
  research notes under ~/.hermes/research/. Use when Jordan asks to finish
  teachable stubs, backfill research takeaways, or improve digest signal —
  never to re-fetch Twitter/Composio.
version: 1.0.0
author: Jordan
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [research, bookmarks, teachable, digest, no-agent]
    category: productivity
    related_skills: [dreamer, cron-script-first]
---

# Research Teachable Finisher

Turn stub (or missing) teachable summaries into one portable paragraph per
research note. **Script-first, no LLM.** Cron can call the same script.

## When to Use

- Jordan says finish teachables / backfill research summaries / improve digests
- After Dreamer notes stub heat in `research/*.md`
- New bookmarks should already leave finished summaries via `bookmark_research_loop.py`

Do **not** re-fetch bookmarks or run Composio from Docker `terminal`.

## Script

```bash
# On VM as hermes (or via host cron helper):
python3 /srv/hermes/.hermes/scripts/research_teachable_finisher.py
python3 /srv/hermes/.hermes/scripts/research_teachable_finisher.py --limit 25
python3 /srv/hermes/.hermes/scripts/research_teachable_finisher.py --dry-run
python3 /srv/hermes/.hermes/scripts/research_teachable_finisher.py --file SOME.md
```

Host wrapper:

```bash
./scripts/hermes-bookmark-research-cron.sh finish          # 10 newest stubs
./scripts/hermes-bookmark-research-cron.sh finish 25
./scripts/hermes-bookmark-research-cron.sh finish --dry-run
```

## Procedure

1. Prefer existing files in `/srv/hermes/.hermes/research/`.
2. Run finisher newest-first with a small `--limit` (default 10).
3. Spot-check 2–3 outputs: heading is `## Teachable summary` (not stub), ≤~120 words.
4. For full backfill, repeat in batches — do not one-shot all ~177 without asking.

## Output shape

- Heading: `## Teachable summary`
- Body: tweet claim + optional linked title/excerpt + “Teach someone: …” gloss
- No secrets, no raw HTML dumps

## Pitfalls

- Inventing takeaways beyond tweet/linked text → script stays extractive; thin notes stay honest about sparsity
- Re-scraping X from chat → cron owns fetch
- LLM rewrite “for quality” → only if Jordan explicitly asks; default is deterministic

## Verification

- [ ] `rg -l 'Teachable summary \(stub\)' /srv/hermes/.hermes/research/*.md | wc -l` drops after a run
- [ ] Newest finished files have real paragraphs, not the Automated-pass stub line
- [ ] New bookmark loop saves omit the stub heading entirely
