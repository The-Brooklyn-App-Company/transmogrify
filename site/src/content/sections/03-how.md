---
order: 3
anchor: how
label: How it works
number: '03'
title: How it works
lede: >-
  You talk to the Oracle. It coordinates operators in Claude Code and Codex,
  each of which can hand jobs to workers in either app.
module: system
diagram:
  caption: >-
    Same-app messages go straight across with the app's own tool. Everything
    else is a note, rung through the receiving app's Mailroom.
  description: >-
    You talk to the Oracle. The Oracle coordinates operators in Claude Code and
    Codex, each of which can hand jobs to workers in either app. Your approvals
    are written into both apps' settings. Messages travel as notes through an
    inbox and a relay to a Mailroom session in each app, and fall back to
    slower paths when a faster one fails.
---

macOS for the operations layer; Linux is best effort for its shell scripts.
Workers need Node.js 20 or newer; Claude jobs need an Apple Silicon Mac. The
local Codex server accepts connections from any program running there.
