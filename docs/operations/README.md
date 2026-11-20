# Agent Operations

An operating kit for running coding agents across several repositories
from your own always-on machine: rules with stable IDs, short docs,
templates, thin skills, and POSIX sh scripts run by the OS scheduler. It
works with Claude Code and Codex in any seat. It is not a framework, a
daemon or an agent runtime.

Part of Transmogrify 2.0 (kit 0.3.1 imported). [Changelog](../../CHANGELOG.md).

## Who it is for

A person, or a team of up to about five, who already use coding agents and
want them to behave like a small, accountable team:

- one persistent main session per person, the **Oracle**, that holds
  priorities, approvals and follow-through;
- one persistent **operator** per outcome, each with a home repository that
  holds everything needed to resume it;
- cheap disposable **workers** for polling, and an independent
  **reviewer** from another model family;
- a free scheduled **tick** that notices stalls and delivers notes, so no
  expensive session ever polls.

## Three layers

| Layer | Holds |
| --- | --- |
| **Kit** (this repository, public) | [The rules](../../kit/KIT.md) (`K-01`...), [docs](./), [templates](../../ops/templates/), [scripts](../../ops/), [skills](../../skills/). No one's choices or identities |
| **Team** (private repository) | The kit pin, `TEAM.md`, `PROJECTS.tsv`, team adapters ([templates](../../ops/templates/team/)) |
| **Personal** (private) | The Oracle home, operator homes, the machine's profile |

Overlays hold deltas only: a parameter, an added rule, or
`override K-nn: reason`. A few rules are fixed. See
[architecture](architecture.md).

## Defaults worth knowing

- **Claim only what is proven** ([K-10](../../kit/KIT.md)): requested, received,
  working, returned, merged, deployed, accepted.
- **Approvals go through the Oracle** ([K-08](../../kit/KIT.md)); money, trades,
  sending as you, deletes and force-pushes are never relayed
  ([K-03](../../kit/KIT.md)).
- **Cross-model accountability, on by default** ([K-22](../../kit/KIT.md)):
  every week the other model family reviews each operator's last seven
  days (commits, notes, mandate, leftovers), and an operator that moves to
  the other family gets a switch-in audit by the incoming family, which its
  session triages and records before new work. Findings go to the
  operator; a digest goes to the Oracle.
- **Mail is a notification, never authority.** The relay tells a session
  where its new notes are; it never puts note text in front of a model.
- **Mailroom, experimental:** the relay routes, an in-app bridge per
  desktop app (both titled "Mailroom") delivers, and a model-free
  supervisor keeps both armed through app restarts and reboots. **Graceful
  degradation is built in** ([K-37](../../kit/KIT.md)): every delivery walks a
  ladder (model-free, a bridge model turn, headless or CLI queue, an alarm
  and then a push to you), so a broken tier only adds latency, logged per
  delivery and flagged once per cause ([mailroom](mailroom.md)).
- **Turnkey host:** `install.sh host --apply` sets App Nap, folders, both
  launchd units and both bridge homes, then lists the few in-app steps a
  person must do ([hosts](hosts-and-ci.md#always-on-host)).
- **One active side** ([K-13](../../kit/KIT.md)): one client runs each operator,
  one client holds the Oracle (a lock file); `lane.sh switch` moves an
  operator by a scripted checklist with a verifier, and `operator.sh`
  creates, archives, recovers and changes the model of one the same way
  ([conventions](conventions.md#operator-routines)).
- **Models are decided once**: an operator's model and effort, for both
  clients, are chosen with you at creation; it never changes its own
  ([client capabilities](client-capabilities.md#models)).
- **Codex relay queues by default** for Codex rows with actual thread IDs.
  Set `relay_codex=off` for passive pickup. One live isolated round trip was
  observed on an existing macOS account/machine (versions and limits below);
  resume is not guaranteed. `doorbell_codex=queue` is a separate opt-in,
  still fakes only; live unrun.
- **No AI attribution** in commits or messages unless you turn it on.

## Quick start

Prerequisites: macOS (Linux is untested), git, `jq`, and Claude Code
and/or Codex signed in.

```sh
git clone <kit-url> ~/src/agent-operations
cd ~/src/agent-operations && git checkout <reviewed-release-tag>
ops/bootstrap.sh                                # guided first run, then a checklist
ops/operator.sh create web                      # first operator; models decided now
```

`bootstrap.sh` explains each step, asks only for your choices (client,
Oracle home, timezone, models, the Oracle lock) and does the rest; it ends
with the few in-app steps a person must do, each with its check
([first run](hosts-and-ci.md#first-run)). The same by hand:

```sh
ops/install.sh --dry-run oracle ~/ops/oracle    # lists every file
ops/install.sh oracle ~/ops/oracle              # creates and commits
$EDITOR ~/.config/agent-operations/profile          # replace every CHANGE-ME
ops/install.sh operator web --owns git@git.example.com:me/app.git
ops/check.sh home ~/ops/oracle ~/ops/web && ops/status.sh
ops/install.sh host --apply                     # App Nap, units, bridges; then in-app steps
```

Then start and name a session in each home, and apply each home's
`settings/` pattern in your client yourself. The full walkthrough is
[install and bootstrap](operators-and-repos.md#install-and-bootstrap);
a worked example is [two operators](../../ops/examples/two-operators/README.md).

Start-to-finish setup: [docs/operations/manual.md](manual.md).

## Reading order

1. [kit/KIT.md](../../kit/KIT.md): the rules, about ten minutes.
2. [docs/operations/architecture.md](architecture.md): roles, layers, moving
   parts, teams, upgrading from 0.1.x.
3. [docs/operations/operators-and-repos.md](operators-and-repos.md): homes,
   shared repositories, install, backup.
4. As needed: [profiles and integrations](profiles-and-integrations.md),
   [review and release](review-and-release.md),
   [hosts and CI](hosts-and-ci.md),
   [conventions](conventions.md) (two apps, one active side),
   [mailroom](mailroom.md),
   [grants](grants.md) (approvals that follow an operator),
   [continuity](continuity.md), and the
   [scripts reference](../../ops/README.md).

## What is proven

Highest stage reached for each piece, with the client, version and date.
"Fakes" means the test suite's stand-in CLIs: no network, no model.

| Piece | Status | Evidence |
| --- | --- | --- |
| Test suite | Passes under bash's `sh` and dash, macOS | `test/ops/run.sh`, 2026-11-19 |
| `tick.sh --dry-run`, `status.sh` against a real registry | Proven, macOS | 2026-11-17 |
| Relay to a named Claude Code desktop session | Proven, macOS, Claude Code 2.1.322 | Pointer delivered and confirmed from the event stream, 2026-11-17; recorded stream in `test/ops/fixtures/` |
| `worker-run.sh` on Codex (`NOTHING`, a note, a failure note) | Proven, codex-cli 0.169 | 2026-11-17 |
| `review-run.sh` on Codex | Proven, codex-cli 0.169 | Toy diff, 2026-11-17 |
| Claude `--restricted` delivery run with only `ListAgents`, `SendMessage` | Proven, Claude Code 2.1.322 | 2026-11-17 |
| `worker-run.sh` and `review-run.sh` on Claude | Fakes only | |
| `cross-review.sh` | Switch-in report by a real Codex reviewer, sandboxed; weekly review: fakes only | codex-cli 0.169.0-alpha.11, 2026-11-17 |
| `install.sh` | Fresh isolated HOME with real client binaries for version checks, Oracle + embedded operator install/home checks, and real macOS worktree helper passed; no sign-in | Claude Code 2.1.322, codex-cli 0.169.0-alpha.11.1, 2026-11-18; not a separate clean machine/account |
| `install.sh sync`, `status.sh --drift` | Fakes only (test suite); not yet run against a real two-client setup | |
| launchd units (tick, relay) | Rendered by `install.sh`; loading them is your step | |
| `install.sh host`, `check.sh host` | Test suite with a fake `defaults`; `check.sh host` read-only on a real macOS host | 2026-11-19 |
| `recover-context.sh` digest under 8 KB, current-state block, Codex sources | Test suite; Claude Code hook registration used; Codex hook registration **unverified** | 2026-11-19; the 10 KB hook-output limit it works around was observed, not documented |
| `bootstrap.sh`, `operator.sh` (create, archive, model, session, recover) | Test suite with fakes; no live first run on a clean account yet | 2026-11-19 |
| **Experimental:** mailroom (ladders, tier telemetry, supervisor, fingerprint and canaries, both tier-1 watchers, unknown-send reconciliation, thread recovery), `lane.sh`, `hygiene.sh`, `install.sh host --apply` | Test suite with fakes; the pattern ran in one private deployment, not this code; live restart recovery and Claude tier 1 against a real client **unverified** | [Mailroom](mailroom.md#what-is-proven), 2026-11-19 |
| systemd units, Linux hosts | **Untested** | |
| Codex relay delivery | Live isolated kit relay → existing native app thread → recipient acknowledgement, macOS; negative cases use fakes | codex-cli 0.169.0-alpha.11.1, 2026-11-18; queue/resume warning observed before a later recipient turn; not a fresh account/machine |
| **Experimental:** lease, standby redirect, forward, cold takeover, asks ledger ([handoff](handoff.md)) | Test suite; sandboxed end-to-end with both real CLIs, headless, `file-only` registry (validation table in [handoff](handoff.md#per-client-validation)) | Claude Code 2.1.322, codex-cli 0.169.0-alpha.11, 2026-11-17. **Not yet** the live test on a real operator ([docs/operations/testing.md](testing.md)) |
| **Experimental:** switch-in audit gate (`audit=pending` until `lease.sh audit-done` records the committed report) | Lease path end-to-end in the sandbox above, report by a real reviewer; registry path: fakes only | 2026-11-17 |
| **Experimental:** human takeover, `settle`, `unlock` on a terminal | Driven through a pseudo-terminal (`script(1)`) only; a human at a real terminal and the clients' interactive permission prompts are **unverified** | |
| **Experimental:** Claude doorbell | Fakes only; live unrun | See [handoff](handoff.md); ordinary Claude relay proof does not verify the doorbell |
| **Experimental:** Codex doorbell | Fakes only; live unrun | Separate `doorbell_codex=queue` opt-in, default `off`; see [handoff](handoff.md) |
| **New in 2.0:** `grants.sh` (grants file, Claude and Codex renderers, three-state check, switch gate) | Test suite with a fixture settings file and a fake Codex CLI only; never run against a real client config. The Codex mechanism (`[auto_review].policy` replaces the default; `config/read` readback) is from Codex 0.169.1 source and docs, not a live probe | 2026-11-20 |
| `ops/examples/tracker-linear` | **Untested** sketch | |

## Repository layout

```
kit/KIT.md         the rules, stable IDs
docs/operations/   the operations guides (this folder)
ops/               install, tick, relay, mailroom, worker-run, review-run,
                   cross-review, status, inbox-put, check, drift-check,
                   recover-context, grants, lib/, units/
ops/templates/     home/, oracle/, team/, packets/
ops/profiles/      claude-only, codex-only, both, custom
ops/adapters/      CONTRACT.md, none.sh, git-gh.sh
ops/examples/      two-operators/, tracker-linear/, security-auto-ship.md, hooks/
skills/            operator-setup, review-handoff, release-closeout,
                   return-to-desk, model-bakeoff
test/ops/          sh test suite with fake agent CLIs
```

## Contributing and license

See [CONTRIBUTING.md](contributing.md). [MIT](../../LICENSE-agent-operations). Client products and
linked sources keep their own terms.
