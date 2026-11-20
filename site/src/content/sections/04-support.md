---
order: 4
anchor: support
label: Support
number: '04'
title: Support matrix
module: matrix
tables:
  - caption: What works in each app
    head: ['', 'Claude Code', 'Codex']
    rows:
      - ['Run the Oracle or an operator', 'Yes', 'Yes']
      - ['Spawn worker lanes in the other app', 'Yes (measured, 2026-09-09)', 'Yes (measured, 2026-09-09)']
      - ['Workers live in the desktop app', 'Yes, Claude app and iPhone (2026-09-09)', 'Only on a verified ChatGPT app build; none passes yet']
      - ['Mail delivered to a named session', 'Proven live (2026-11-17)', 'One live round trip (2026-11-18)']
      - ['Mail without a model polling, with fallbacks', 'Built; tested against fakes, live run pending', 'Built; tested against fakes, live run pending']
      - ['Switch an operator to the other app', 'Built; tested against fakes, live run pending', 'Built; tested against fakes, live run pending']
      - ['Approvals written into its settings, on your yes', 'Built; tested against fixtures, not yet on a real config', 'Built; tested against a fake CLI, not yet on a real config']
  - caption: Platforms
    head: ['Platform', 'Status']
    rows:
      - ['macOS', 'Supported']
      - ['Linux', 'Codex worker lanes supported (CI); Claude worker lanes need an Apple Silicon Mac; operations layer best effort (CI only)']
      - ['Windows', 'Not supported']
      - ['Antigravity', 'On the roadmap']
---

Much of the operations layer is proven against the test suite's fakes, not
yet on a fresh machine; each piece's highest proven stage, with dates, is in
the README.
