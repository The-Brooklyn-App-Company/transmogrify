# Transmogrify

An operating system for a small team of long-running AI agents on your own
always-on Mac, across Claude Code and Codex.

Transmogrify gives one person, or a small team, a main session that holds
your priorities and approvals (the **Oracle**), one long-running session per
outcome (an **operator**, each with a home repository that holds everything
needed to resume it), and short-lived **worker lanes** that either app can
hand to the other: every job gets its own clone of your repository, and the
session that started it can steer it, collect the commit it hands back, and
close it out. Messages reach sessions in both desktop apps without a model
polling, approvals follow an operator when it moves between the apps, and a
broken delivery path slows things down instead of stopping them.

It is two layers in one install:

- **Operations** (`ops/`, `kit/`, `docs/operations/`): rules with stable IDs,
  homes, the mailroom, the operator routines and switches, approvals, and
  scheduled checks. POSIX `sh`, `jq` and the system Python; no daemon.
- **Workers** (`scripts/`, `SKILL.md`): exact-owned worker lanes in Codex
  or Claude Code, with durable operation records and "never replay an
  unknown outcome". Node.js.

**Who it is for:** solo builders and small teams (up to about five people)
who already use Claude Code or Codex and want their agents to behave like a
small, accountable team on hardware they control.

**What it is not:** a framework, a hosted service, an agent runtime, or a
daemon you trust with credentials. It never signs in for you, never stores a
secret, and needs no server or account of its own.

> **Status: 2.0.0-rc.1, a release candidate.** The workers layer carries
> forward the 0.6 line's measured receipts. Much of the operations layer is
> proven only against the test suite's fakes; each piece's highest proven
> stage is in [What is proven](docs/operations/README.md#what-is-proven).

## The picture

```text
 you, at a desk or on a phone
        |
        v
   the Oracle ............ approvals (one grants file) ...> each app's own
   (one per person,                                         approval layer
    one active app)
        |
   +----+-------------+------------------+
   |                  |                  |
 operator           operator          operator      one home each; runs in
 (Claude Code)      (Codex)           (either)      exactly one app at a time
   |                  |
 worker lanes       worker lanes                     one clone per job;
 (Codex or Claude)  (Codex or Claude)                hands back a commit

 delivery: sources (hooks, timers, CI, trackers, other sessions)
             -> inbox (one note file per message)
             -> relay (model-free, on a timer and on change)
             -> bridge ("Mailroom", one per desktop app)
             -> the recipient session
```

Same-app messages go directly, with the app's own tool. Everything else is a
note in the recipient's inbox; the relay rings the receiving app's bridge,
and every ring walks that app's **degradation ladder**:

| Tier | Claude Code | Codex |
| --- | --- | --- |
| 1, model-free | A warm session's local socket (opt-in, undocumented interface) | The app's native send, from a watcher the bridge owns |
| 2, a bridge model turn | The bridge session sends it; this also reaches cold sessions | The bridge re-arms its watcher, which catches up |
| 3, headless or CLI | One confined headless run | One CLI queue straight to the thread |
| 4, alarm | A note to the Oracle, then one push to you per outage | Same |

A broken tier adds latency, is logged on the delivery's row and is flagged
once per cause. Details: [Mailroom](docs/operations/mailroom.md).

## Install

Paste one line into Claude Code or Codex (the ChatGPT desktop app):

```text
Fetch https://transmogrify.sh/start and follow its instructions.
```

The same line works in either app. CI generates `/start` from one exact
published release commit; it refuses to install without that pin and never
falls back to a branch. It installs both layers, then runs the read-only
doctor.

From a source checkout instead, pinned to a release tag:

```bash
git clone https://github.com/The-Brooklyn-App-Company/transmogrify.git
cd transmogrify
git checkout v2.0.0          # a release tag, never a branch
npm ci --ignore-scripts
./install.sh --dry-run
./install.sh
```

The installer copies the whole package, both layers, to
`~/.claude/skills/transmogrify` and `~/.agents/skills/transmogrify` (Codex's
personal skill location), backs up existing installations, and refuses an
occupied target it did not write or an unsafe parent directory.
`--target codex|claude` installs one host; `./install.sh --help` lists the
rest. The package is not published to npm. Upgrades, rollback and removal
are in [Troubleshooting](docs/TROUBLESHOOTING.md#installation-and-upgrades).

### Requirements

- macOS for the operations layer (launchd units, the desktop apps). Linux is
  best effort for the `sh` layer: CI runs its suite on Ubuntu, but no Linux
  host has run it live. Windows is not supported.
- Git, `jq`, the system Python (`/usr/bin/python3`), and Claude Code or Codex
  (or both), signed in by you.
- For worker lanes: [Node.js](https://nodejs.org/en/download) 20 or newer
  with npm, plus Bash, `ps` and `lsof`; Codex CLI/app-server `0.151.0` or
  newer; for Claude jobs, Apple Silicon and Claude Code CLI `2.1.258` or
  newer. Compatibility is a measured minimum plus probes, with no maximum
  version; the optional private archive step separately pins the exact CLI
  hash and Claude Desktop build
  ([Claude compatibility](docs/CLAUDE-CODE.md#compatibility-receipts)).
  Live streaming in the ChatGPT app also needs an app build verified for
  relay attachment and thread resume (none passes yet; see the support
  matrix).

### The first run

One guided first run sets up both layers, one consent at a time:

```bash
export SKILL_ROOT="$HOME/.agents/skills/transmogrify"   # Claude-only: $HOME/.claude/skills/transmogrify
export REPO_ROOT=/absolute/path/to/repository
node "$SKILL_ROOT/scripts/doctor.js" --repo-root "$REPO_ROOT" --target all --operations --explain
node "$SKILL_ROOT/scripts/setup.js" --repo-root "$REPO_ROOT"   # workers
sh "$SKILL_ROOT/ops/bootstrap.sh"                               # operations
```

The doctor only reads: provider state, compatibility, and the host steps the
operations layer would take (`ops/install.sh --dry-run host`). Its
`setup.ownerActions` lists every step only you can take. `setup.js` makes
worker lanes ready (the CLIs, sign-in, the shared Codex runtime), asking
before each step; in a non-interactive host, authorize one step at a time
with its flag (`--install-claude-cli`, `--install-codex-cli`, `--sign-in`,
`--start-runtime`, `--relaunch-desktop`, `--persist-attach`). `bootstrap.sh`
then asks for the choices that are yours (the app you start the Oracle on, the
Oracle home, your timezone, models, the Oracle lock), creates the Oracle
home and profile, applies the host settings on your yes (App Nap off, both
launchd units, both bridge homes), and, if you already have a grants file,
shows the approvals it would write into each app's settings and writes them
only on your yes. It writes the Codex recovery hook on your yes and gives
the exact steps to trust it in the Codex CLI (the desktop app has no
`/hooks`), then asks Codex whether the hook is trusted at its current
definition and checks that an isolated fresh run receives the digest. It ends with the short list of steps only you can do (sign in, restart
the apps, pin, start the two "Mailroom" sessions), each with exact
instructions and an automatic check that it worked: the CLIs' sign-in
status, the apps' start time, the Codex app's pinned list, registry ids.
Only the Claude sidebar has nothing to read, so pins there are confirmed
with `bootstrap.sh mark pins`. `node "$SKILL_ROOT/scripts/setup.js" --repo-root "$REPO_ROOT" --apply-host`
applies the same host steps from the Node side.

## Your first hour

1. **The Oracle comes up.** Start a session in the Oracle home in the app
   you chose, title it "Oracle", pin it, and give `bootstrap.sh` its id.
   The checklist confirms the mailroom with a test note.
2. **Add an operator.** `sh "$SKILL_ROOT/ops/operator.sh" create web` asks
   for its name, its app, and the model and effort for both apps: decided
   once, now, with you. It creates the home and walks the in-app steps
   (session, title, pin, mandate) with a check for each.
3. **Send a note across apps.** From a hook, a timer or the other app:
   `printf 'Release notes are ready.\n' | sh "$SKILL_ROOT/ops/inbox-put.sh" web notes`.
   The relay rings the operator's app through its bridge.
4. **See the tier it took.** `sh "$SKILL_ROOT/ops/mailroom.sh" metrics`
   prints, per app, the rings, the tier each took, and latency.
5. **Run a worker lane.** From the operator's session, invoke the skill
   (`$transmogrify` in Codex, `/transmogrify` in Claude Code), or by hand:

   ```bash
   export WORKTREES="$HOME/.local/share/transmogrify/worktrees/web"   # private, mode 700
   install -d -m 700 "$WORKTREES"
   node "$SKILL_ROOT/scripts/lane.js" parent-init --repo-root "$REPO_ROOT" \
     --host-provider claude --host-app claude-code --name 'Web operator'
   printf '%s\n' 'Fix the failing date test and commit.' |
     node "$SKILL_ROOT/scripts/lane.js" spawn --repo-root "$REPO_ROOT" \
       --worktrees "$WORKTREES" --target codex --name 'tests: date fix' \
       --parent-context-file "$PARENT_CONTEXT" --intent balanced --input-file -
   ```

   (`PARENT_CONTEXT` is the `contextFile` path that `parent-init` prints.)

   The lane runs in its own clone and hands back a commit; `lane.js harvest`
   fetches it into your repository and prints the exact `lane.js retire`
   command. The full walkthrough is in [Examples](examples/README.md) and
   [SKILL.md](SKILL.md).

## Guarantees and defaults

- **Claim only what is proven** (K-10): requested, received, working,
  returned, merged, deployed, accepted. Done means the whole user-visible
  behavior was walked end to end (K-11).
- **Approvals go through the Oracle** (K-08) and **follow an operator across
  apps**: one grants file, rendered into Claude Code's `autoMode.allow` and a
  managed Codex `[auto_review]` block, checked nightly; a switch is refused
  until the target app's approvals match ([Grants](docs/operations/grants.md)).
  Money, trades, sending as you, deletes and force-pushes are never relayed
  (K-03).
- **Degrade, never stop** (K-37): every delivery path falls back to a slower
  one; the last tier reaches you.
- **One active side** (K-13): each operator runs in exactly one app, and one
  app holds the Oracle; the other side stays parked and redirects.
- **Models are set at creation** with you, for both apps, and never changed
  by an operator itself (K-26).
- **Secrets stay in the secret store** (K-05): a credential moves store to
  store; nothing here prints, copies or types one.
- **Exact ownership for workers:** every lane mutation is journaled before
  dispatch and confirmed by an exact receipt; nothing adopts a session by
  name or replays an unknown outcome.
- **No AI attribution** from the operations layer in commits or messages
  unless you turn it on (K-30). One exception for now: a worker lane's
  commit carries its provider's `Co-Authored-By` trailer
  ([Dispatch](docs/DISPATCH.md)).

## Support matrix

Dated receipts; anything not listed is unverified.

| Piece | Status | Evidence |
| --- | --- | --- |
| Codex worker lanes, from Codex or Claude Code | Supported | App-server `0.151.0` or newer, measured by the doctor; CI on macOS and Linux |
| Claude Code worker lanes, from Codex or Claude Code | Supported, Apple Silicon macOS | CLI `2.1.258` or newer; live-verified on Desktop and on Claude for iOS `1.260828.1`, 2026-09-09 |
| Codex lanes live in the ChatGPT desktop app | Conditional: no verified build | `26.901.51231` and `26.903.61454` fail to resume threads on the relay path; an owner records a passing build with `desktop-attach.js persist --authorize --verified-build <version> <build>` ([Protocol](docs/PROTOCOL.md#native-app-visibility)) |
| Codex lanes on mobile | Measured | ChatGPT for iOS `1.2026.230`, 2026-09-09 |
| Relay to a named Claude Code desktop session | Proven, macOS | Claude Code 2.1.322, 2026-11-17 |
| Relay to an existing Codex thread | One live isolated round trip, macOS | codex-cli 0.169, 2026-11-18 |
| Mailroom ladders, supervisor, restart recovery | Test suite with fakes; live restart recovery **unverified** | 2026-11-19 |
| Grants renderers (Claude Code, Codex) | Test suite with fixtures and a fake Codex CLI; never run against a real client config | 2026-11-20 |
| First run (`bootstrap.sh`), operator routines, switches | Test suite with fakes; no live first run on a clean account yet | 2026-11-20 |
| macOS host setup (`install.sh host`) | Test suite; read-only check on a real macOS host | 2026-11-19 |
| Linux, the `sh` layer | Best effort: CI suite only; systemd units untested | |
| Antigravity | Not supported; on the [roadmap](ROADMAP.md) | |

Full tables: [What is proven](docs/operations/README.md#what-is-proven)
(operations), the [protocol contract](docs/PROTOCOL.md) and
[Claude Code integration](docs/CLAUDE-CODE.md) (workers).

## Concepts

- **Rules** ([kit/KIT.md](kit/KIT.md)): 37 short rules with stable IDs
  (`K-01`...), cited, never restated. A team or a person adds rules and
  overrides in their own layer; a few are fixed.
- **Homes:** each operator, and the Oracle, is one git repository holding
  its mandate, notes, backlog and journal, so a session resumes from files,
  not chat history
  ([Operators and repositories](docs/operations/operators-and-repos.md)).
- **The mailroom:** inbox, relay, the two bridges, the supervisor and the
  ladders above ([Mailroom](docs/operations/mailroom.md)).
- **Routines and switches:** creating, archiving, recovering or re-modelling
  an operator (`operator.sh`) and moving it between apps (`switch.sh`) run as
  scripted checklists with a verifier per step
  ([Conventions](docs/operations/conventions.md)).
- **Workers and execution profiles:** lanes spawned with a provider-neutral
  intent (`fast-loop`, `balanced`, `deep`, ...) or an explicit model, effort
  and speed ([Execution profiles](docs/EXECUTION-PROFILES.md)). A worker's
  completion can reach its parent as a mailroom note
  (`TRANSMOGRIFY_COMPLETION_ROUTE=mailroom`;
  [Notifications](docs/NOTIFICATIONS.md)).
- **Grants:** the owner's standing approvals, verbatim and dated, in one file
  that renders into both apps ([Grants](docs/operations/grants.md)).
- **Review:** independent review by the other model family, bounded rounds,
  and a weekly cross-model review of each operator
  ([Review and release](docs/operations/review-and-release.md)).

## Tools

Operations layer, `ops/` (POSIX `sh`; each takes `--help`):

| Tool | Purpose |
| --- | --- |
| `bootstrap.sh` | The guided first run |
| `install.sh` | Homes, profiles, skill links, host setup (`host`, `host --apply`), sync between apps |
| `operator.sh` | Create, archive, recover or re-model an operator; record a session |
| `switch.sh` | Move an operator between apps; the parked-side guard; holds; the Oracle lock (`lane.sh` is a deprecated alias until 2.1) |
| `grants.sh` | Validate, render and check the approvals that follow an operator |
| `inbox-put.sh`, `relay.sh`, `mailroom.sh` | Write a note; route it; the bridges, supervisor and metrics |
| `tick.sh`, `hygiene.sh`, `status.sh`, `check.sh` | The scheduled watchdog, the nightly hygiene list, status and drift, checks |
| `worker-run.sh`, `review-run.sh`, `cross-review.sh` | Boxed headless runs, reviews, the weekly cross-model review |
| `recover-context.sh` | The recovery digest a session reads at start |

Full reference: [ops/README.md](ops/README.md).

Workers layer, `scripts/` (Node.js; each takes `--help`):

| Tool | Purpose |
| --- | --- |
| `transmogrify.js` | One entry point that forwards to the tools below |
| `doctor.js` | Read-only discovery, compatibility measurement and the setup plan (`--operations` adds the host checks) |
| `setup.js` | Guided setup, one consented step at a time (`--apply-host` for the host steps) |
| `lane.js` | `parent-init`, `spawn`, `wait`, `ack`, `steer`, `status`, `interrupt`, `stop`, `recover`, `harvest`, `retire`, `reconcile`, `abandon`, and more |
| `maintain.js` | The doctor plus each provider's exact-owned reconcile; `--retention` trashes aged records recoverably |
| `runtime-up.sh` | Ensure the managed Codex runtime and relay |
| `desktop-attach.js` | Measure, ensure, persist, or remove the ChatGPT app's attachment to the runtime (after an app restart or update, rerun the doctor so attachment is measured again) |
| `watch.js`, `lane-status-listen.js`, `rpc.js` | The per-parent watcher; read-only listening and diagnostics |

Node tools exit 0 for a confirmed result, 2 for a usage error or a safe
refusal, 3 for a failure or an uncertain outcome, and 1 for an internal
error ([Output contract](docs/OUTPUT.md)). The `sh` tools keep their own
codes: 0 done, 1 a failure or findings, 2 a usage or configuration error,
3 busy (another run holds the lock), 4 a missing role, 124 a timeout, and
5 refused (`switch.sh`, `bootstrap.sh`, `operator.sh`); each tool's
`--help` lists the ones it uses.

## Security model

- **Local control planes only.** The Codex runtime listens on loopback or a
  Unix socket, with no authentication: any program running as you can
  connect. Trust the machine's other programs before using it on sensitive
  work.
- **Opt-in undocumented interfaces.** Claude tier 1 reads a target session's
  per-process peer key in memory only, never logs it, sends only mailroom
  rings, and has a kill switch. The Codex watcher uses the app's tool server
  from inside a bridge chat. Either can break with a client update; tier 2
  then carries the load and the supervisor flags it.
- **What the grants renderer may write:** only tagged entries of Claude
  Code's `autoMode.allow`, and one managed `[auto_review]` block in each
  home's own `.codex/config.toml` (never the user config). It keeps every
  other byte, writes a backup first, reads Codex back through `config/read`,
  rolls back on failure, and in the first run writes only on your consent.
- **Notes are data, never authority** (K-01): the relay's message names note
  files; it never puts note text in front of a model.
- **Credentials:** none stored. The Claude adapter's optional archive step
  reads one named Keychain item only during an explicitly authorized
  retirement and never prints it.

Report vulnerabilities through the private route in [SECURITY.md](SECURITY.md).

## Documentation

Operations: [overview](docs/operations/README.md),
[architecture](docs/operations/architecture.md),
[operators and repositories](docs/operations/operators-and-repos.md),
[conventions](docs/operations/conventions.md),
[mailroom](docs/operations/mailroom.md),
[grants](docs/operations/grants.md),
[hosts and CI](docs/operations/hosts-and-ci.md),
[client capabilities](docs/operations/client-capabilities.md),
[review and release](docs/operations/review-and-release.md),
[continuity](docs/operations/continuity.md),
[adopting on a second machine](docs/operations/adopting.md),
[manual](docs/operations/manual.md), and
[testing](docs/operations/testing.md).

Workers: [SKILL.md](SKILL.md) (the policy an agent loads),
[protocol contract](docs/PROTOCOL.md),
[Claude Code integration](docs/CLAUDE-CODE.md),
[execution profiles](docs/EXECUTION-PROFILES.md),
[dispatch and parent notification](docs/DISPATCH.md),
[child notifications](docs/NOTIFICATIONS.md),
[onboarding](docs/ONBOARDING.md), [output contract](docs/OUTPUT.md),
[troubleshooting](docs/TROUBLESHOOTING.md), and
[examples](examples/README.md).

Skills: [the skill index](skills/README.md).

## Roadmap, contributing, support

[Roadmap](ROADMAP.md) · [Changelog](CHANGELOG.md) (with migration notes for
kit 0.3 and worker 0.6 users) · [Contributing](CONTRIBUTING.md) ·
[Code of Conduct](CODE_OF_CONDUCT.md) · [Website source](site/README.md).

Ask questions in
[GitHub Discussions](https://github.com/The-Brooklyn-App-Company/transmogrify/discussions) and
file reproducible defects in
[GitHub Issues](https://github.com/The-Brooklyn-App-Company/transmogrify/issues). Never post
credentials, transcripts, session identifiers or exploit details publicly.

## License

MIT. The workers layer is under [LICENSE](LICENSE); the operations layer,
imported from Agent Operations, keeps its own notice in
[LICENSE-agent-operations](LICENSE-agent-operations).
