---
name: dreamer
description: >-
  Pattern-noticer that turns research signals, recurring bookmarks, failed
  runs, and operator pressure into candidate idea contracts. Use when Jordan
  asks to dream, brainstorm what to build next, mine bookmarks/research for
  build ideas, run Auto-think / idea-intake, or shape signals into reviewable
  candidates — never to approve or implement those ideas.
version: 1.0.0
author: Jordan
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [dreamer, ideas, auto-think, research, bookmarks, ideation]
    category: productivity
    related_skills: []
---

# Dreamer — Idea Intake

Dreamer notices heat. It does **not** approve, plan builds, or implement.

A signal is not a task. A candidate is not approval. A repeated idea is not automatically worth building.

## When to Use

- Jordan says dream / dreamer / what should we build / mine research for ideas
- After bookmark digests or research deep-dives, shape what keeps returning
- System pressure: failed cron, QA gaps, repeated friction, operator asks
- Turn vague curiosity into a reviewable **idea contract** for Main/Jordan

Do **not** use this skill to code, open PRs, mutate config/cron, or self-approve.

## Inputs (this runtime)

Read before inventing:

| Source | Path / tool |
|--------|-------------|
| Bookmark research | `/srv/hermes/.hermes/research/*.md` |
| Research state | `/srv/hermes/.hermes/research/state.json` |
| Existing ideas | `/srv/hermes/.hermes/ideas/*.md` |
| Persona / mission | `/srv/hermes/.hermes/SOUL.md`, `AGENTS.md` if present |
| Past sessions | `session_search` for recurring themes |
| Memory | `memory` / mempalace if available — durable prefs only |

Jordan's interest lens: AI agents, local inference hardware, security/isolation, markets/space, physics demos, engineering curiosities.

Do **not** re-fetch Twitter/Composio via `terminal` — cron owns that. Prefer existing research files.

## Procedure

### 1. MINE

Scan recent research (newest first, cap ~15 files unless asked for deeper), plus session/memory hits. Extract candidates:

- Recurring theme across ≥2 bookmarks or sessions
- Pain / friction Jordan or the agent hit more than once
- Capability gap (missing skill, brittle workflow, unsafe shortcut)
- Surprising implication worth a small, bounded experiment

Reject immediately:

- One-off news with no repeat signal
- Secrets, tokens, `.env`, credentials
- Task progress / SHA / PR state
- Speculative hype with no local evidence
- Ideas that require mutating protected infra without Jordan

### 2. SCORE

Keep only candidates that score high on most of:

- **Recurrence** — showed up more than once, or hits a stated interest hard
- **Leverage** — teaches or compounds (skill, digest, tool, isolation win)
- **Fit** — runnable in this VM/host model (rootless Docker, UFW, local Gemma)
- **Evidence** — cite research filenames or session facts
- **Safety** — no silent privilege, no host-disk secrets, no LAN reach

Drop weak scores; prefer 1–5 strong candidates over a long list.

### 3. SHAPE → idea contract

For each kept candidate, write a contract using the template:

`skill_view("dreamer", "templates/idea-contract.md")`

Required fields: title, who benefits, why now, evidence, non-goals, suggested home, how to verify, risk notes.

Save under:

```text
/srv/hermes/.hermes/ideas/YYYY-MM-DD-<slug>.md
```

Create `/srv/hermes/.hermes/ideas/` if missing (`mkdir -p`). Do not overwrite an existing file — append a suffix (`-2`, …).

### 4. DEDUPE

Before writing, list `/srv/hermes/.hermes/ideas/` and skip near-duplicates. Prefer strengthening an existing contract over a twin.

### 5. HANDOFF (stop here)

Present a short operator summary:

- Candidates written (paths)
- Skipped / weak signals (one line each)
- Recommended next step: **Jordan or Main reviews** — Dreamer does not approve

Never start implementation from this skill. If Jordan says "build the top one", that is a **new** turn outside Dreamer (planner/coder), after explicit approval.

## Output Style

- Concise Slack-friendly summary first (≤25 lines unless asked)
- Contracts on disk are the durable artifact
- Cite evidence as filenames, not pasted walls of research

## Guardrails

- Dreamer **cannot** approve its own candidates
- Dreamer **cannot** edit `config.yaml`, `.env`, systemd, cron, UFW, or host repo
- Dreamer **cannot** run Composio/Twitter fetch from Docker `terminal`
- Prefer propose-a-skill over propose-a-daemon
- Prefer local/read-only experiments over new network egress

## Pitfalls

- Inventing ideas with no research file behind them → re-mine or mark confidence low
- Turning every bookmark into a project → enforce recurrence/leverage scoring
- Writing contracts that are really build plans → strip to intake fields only
- Empty research dir → say so; offer a light dream from session_search/memory only

## Verification

- [ ] At least one idea file exists under `/srv/hermes/.hermes/ideas/` (or explicit "nothing durable")
- [ ] Each contract has evidence + non-goals + verify
- [ ] Summary does not claim approval or start a build
- [ ] No secrets written into idea files

## References

- Signal taxonomy: `skill_view("dreamer", "references/signals.md")`
- Contract template: `skill_view("dreamer", "templates/idea-contract.md")`
