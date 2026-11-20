# Site content for Transmogrify 2.0

The copy the 2.0 site renders (`src/content/sections/`). Source of truth
for every claim is the root [README](../README.md); when they disagree, the
README wins and both this file and the sections are updated. Repository
links point to `The-Brooklyn-App-Company/transmogrify`, the 2.0 home.

## Hero

Kept from the current site.

- **Eyebrow:** For Claude Code and Codex
- **Headline:** Fable and Astra, working as a team.
- **Lede:** Transmogrify lets you seamlessly hand off work between the
  Claude and ChatGPT apps.
- **Primary action:** the start prompt (below), with a Copy button.
- **Secondary links:** How it works · Docs · Source

## Install, in one paste

**Label:** Start prompt · paste into Claude Code or Codex

```text
Fetch https://transmogrify.sh/start and follow its instructions.
```

**Under the prompt:** The same line works in either app. It installs one
exact, published release (pinned to its commit, never a branch) with both
layers, checks your machine without changing anything, and names the next
step. The guided first run then sets things up one yes at a time.

**Secondary, for people who prefer a terminal:**

```bash
git clone https://github.com/The-Brooklyn-App-Company/transmogrify.git && cd transmogrify
git checkout v2.0.0 && npm ci --ignore-scripts && ./install.sh
```

## What it is (section 01)

**Title:** A small, accountable team of agents

**Lede:** One main session that holds your priorities and approvals, one
long-running session per outcome, and short-lived workers either app can
hand to the other, all on your own always-on Mac.

**Body:**

- **The Oracle.** Your main session: priorities, approvals, follow-through.
  One per person, active in one app at a time.
- **Operators.** One long-running session per outcome, each with a home
  repository that holds everything needed to pick it back up. Each runs in
  Claude Code or Codex, and moves between them by a checked switch.
- **Workers.** Short jobs in either app, one clone each, that hand back a
  commit. The session that started one can steer it, collect it and close
  it out.
- **Approvals that follow.** Your standing approvals live in one file and
  are written into each app's own approval settings, only after you say
  yes. An operator cannot switch apps until the other side matches.
- **Mail that never stops.** Messages reach sessions in both apps without a
  model polling. When a path breaks, delivery slows down instead of
  stopping, and you hear about it once.
- **Nothing hosted.** No server, account or telemetry of its own; your
  Claude and ChatGPT accounts work as they already do.

**Who it is for:** solo builders and small teams who already use Claude
Code or Codex. **What it is not:** a framework, a hosted service, or a
daemon you trust with credentials.

## Your first hour (section 02)

1. **Paste the start prompt.** It installs the pinned release and checks
   your machine without changing anything.
2. **Run the first run.** It asks for your choices (the app for your
   Oracle, its home, your timezone, models) and sets up the rest on your
   yes, then lists the few clicks only you can do.
3. **Start your Oracle.** One session, titled "Oracle", pinned. A test
   note proves mail reaches it.
4. **Add an operator.** Name it, pick its app, choose its models once.
5. **Send it a note from the other app.** Watch which delivery path it
   took.
6. **Hand a worker a task.** It runs in its own clone and hands back a
   commit you can fetch, review and merge.

## How it works (section 03): diagram description

One diagram, top to bottom, in the site's existing diagram style:

1. **You**, at a desk or on a phone, at the top.
2. **The Oracle** below you. To its right, a dotted arrow labelled
   "approvals (one file)" fans out to two small boxes, "Claude Code
   settings" and "Codex settings".
3. **Three operators** below the Oracle, side by side: one marked Claude
   Code, one Codex, one "either". A small "switch" arrow between the first
   two shows an operator moving apps.
4. **Worker lanes** under two of the operators: small stacked cards, each
   labelled "own clone", each with an arrow back up labelled "commit".
5. **Delivery strip** along the bottom, left to right: "hooks, timers, CI,
   other sessions" → "inbox" → "relay" → two bridges labelled "Mailroom
   (Claude)" and "Mailroom (Codex)" → arrows up to the sessions.
6. **The ladder**, as a small inset beside the strip: four steps going
   down, "model-free" → "bridge turn" → "headless or CLI" → "alarm to
   you", captioned "a broken step adds latency, never stops delivery".

**Caption:** Same-app messages go straight across with the app's own tool.
Everything else is a note, rung through the receiving app's Mailroom.

**Plain-text alternative (for screen readers):** You talk to the Oracle.
The Oracle coordinates operators in Claude Code and Codex, each of which
can hand jobs to workers in either app. Your approvals are written into
both apps' settings. Messages travel as notes through an inbox and a relay
to a Mailroom session in each app, and fall back to slower paths when a
faster one fails.

**Requirements line (keep):** macOS for the operations layer; Linux is
best effort for its shell scripts. Workers need Node.js 20 or newer;
Claude jobs need an Apple Silicon Mac. The local Codex server accepts
connections from any program running there.

## Support matrix (section 04)

| | Claude Code | Codex |
| --- | --- | --- |
| Run the Oracle or an operator | Yes | Yes |
| Spawn worker lanes in the other app | Yes (measured, 2026-09-09) | Yes (measured, 2026-09-09) |
| Workers live in the desktop app | Yes, Claude app and iPhone (2026-09-09) | Only on a verified ChatGPT app build; none passes yet |
| Mail delivered to a named session | Proven live (2026-11-17) | One live round trip (2026-11-18) |
| Mail without a model polling, with fallbacks | Built; tested against fakes, live run pending | Built; tested against fakes, live run pending |
| Switch an operator to the other app | Built; tested against fakes, live run pending | Built; tested against fakes, live run pending |
| Approvals written into its settings, on your yes | Built; tested against fixtures, not yet on a real config | Built; tested against a fake CLI, not yet on a real config |

| Platform | Status |
| --- | --- |
| macOS | Supported |
| Linux | Codex worker lanes supported (CI); Claude worker lanes need an Apple Silicon Mac; operations layer best effort (CI only) |
| Windows | Not supported |
| Antigravity | On the roadmap |

**Footnote:** Much of the operations layer is proven against the test
suite's fakes, not yet on a fresh machine; each piece's highest proven
stage, with dates, is in the README.

## Docs (section 05): six cards

| Card | Text | Link |
| --- | --- | --- |
| README | Install, first hour, guarantees, support | `README.md` |
| Operations overview | Rules, homes, the mailroom, what is proven | `docs/operations/README.md` |
| Mailroom | How mail reaches both apps and degrades | `docs/operations/mailroom.md` |
| Grants | Approvals that follow an operator | `docs/operations/grants.md` |
| Worker lanes | The skill an agent loads | `SKILL.md` |
| Troubleshooting | Setup failures, upgrades, cleanup | `docs/TROUBLESHOOTING.md` |

Each card links to `https://github.com/The-Brooklyn-App-Company/transmogrify/blob/main/<path>`.

## Footer

Changelog · Roadmap · Security · Terms · Privacy · Source. Tagline (kept):
"Open-source agent orchestration for Claude and ChatGPT."
