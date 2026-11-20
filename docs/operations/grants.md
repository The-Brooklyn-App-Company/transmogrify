# Grants: approvals that follow an operator

An operator that moves between Claude Code and Codex keeps the same standing
approvals. The owner's grants live in one client-neutral file in the Oracle
home; [`ops/grants.sh`](../../ops/grants.sh) renders them into each client's
own approval layer and checks that both sides match. Approvals still go
through the Oracle ([K-08](../../kit/KIT.md)); rendering never creates or
widens a grant.

## The grants file

`operators/GRANTS.md` in the Oracle home (profile key `grants_file`); start
from [the template](../../ops/templates/oracle/GRANTS.md). It has three
marked blocks:

- **Known Codex baselines** (`<!-- baselines:begin -->`): one table row per
  Codex reviewer policy a person has read: CLI version, policy SHA-256,
  bytes, when it was verified.
- **Codex preamble** (`<!-- preamble:begin -->`): the text rendered once
  per home before the grant clauses; `{key}`, `{name}` and `{home}` come
  from the registry.
- **Grants** (`<!-- grants:begin -->`): one `### grant: <id>` section each:

| Line | Meaning |
| --- | --- |
| `- title:` | The name; the Claude entry starts with it |
| `- actors:` | `oracle`, `operators` (every non-Oracle registry key) or registry keys, comma-separated |
| `- codex:` | `yes`, or `no (reason)` for a grant that has no Codex form |
| `- expires:` | `YYYY-MM-DD` or `never`; an expired grant stops rendering |
| `- words:` | `date \| provenance \| the owner's verbatim words`; one or more. Each quote must appear verbatim in the Claude text |
| `Allowed:`, `Limits:`, `Does NOT cover:` | Bullet lists for the Codex reviewer (required with `codex: yes`). `[only: key,...]` limits a bullet to those actors; `@include <id>` repeats that grant's Does-NOT-cover list, except bullets marked `[no-include]` |
| `Claude:` | A `~~~text` fence holding the one-line `autoMode.allow` entry, as the owner approved it |

The Codex clauses restate the Claude text for the Codex reviewer and may
only be narrower where Codex lacks a Claude mechanism (a Claude session id
is not a Codex identity). A worked, fictional example is
[the test fixture](../../test/ops/fixtures/GRANTS.example.md).

## Rendering

- **Claude Code:** `grants.sh render-claude` writes one `autoMode.allow`
  entry per live grant into the settings file (profile key
  `grants_claude_settings`; default `settings.json` in `CLAUDE_CONFIG_DIR`
  or `~/.claude`), the Claude text plus a ` [grant:<id>]` tag. Only tagged
  entries change; an untagged entry byte-identical to a grant's text gains
  its tag; an edited untagged copy is refused for a person to reconcile.
  Every other key and entry stays byte for byte, a backup is written first,
  and `--prune` removes tagged entries no longer in the file.
- **Codex:** `grants.sh render-codex --all` writes a managed root
  `[auto_review]` table into each home's own `.codex/config.toml` (never
  the user config, whose `[projects]` tables take only `trust_level`):
  `policy` is the bundled default reviewer policy verbatim, then the
  preamble and the clauses of the grants that name that actor. A local
  policy replaces the default rather than adding to it (observed in the
  Codex 0.169.1 source, 2026-11-19), so the baseline is kept whole. The
  baseline is `model_messages.auto_review.policy` of the `codex-auto-review`
  row in `codex debug models --bundled`; rendering refuses unless its hash
  is a known baseline, and refuses when the cached catalog carries a
  different policy. An unmanaged `auto_review` setting, a symlinked
  `.codex` or a path into the Codex user folder is refused. After writing,
  `codex app-server` `config/read` must show the rendered policy coming
  from that home's `.codex` layer; otherwise, or when the render is
  interrupted, the previous file is restored. Markers, keys and tables count
  only outside TOML strings, and the text outside the managed block must
  survive byte for byte.

## Three states

`grants.sh check` reports each side:

| State | Claude | Codex |
| --- | --- | --- |
| rendered | the tagged entries match the file | the home's managed block decodes to the current rendering |
| resolved | the settings parse | `config/read` shows that policy from the home's own `.codex`, the layer is trusted, no managed layer sets `auto_review`, and `configRequirements/read` answers with no managed requirement a person has not checked (profile key `grants_managed_requirements_ok`) |
| accepted | a fresh session passed a harmless probe, recorded with `grants.sh accept` | the same, per home |

A file check alone does not prove what a live reviewer loaded: Codex
resolves configuration when a session starts, and a managed policy wins
over a local one. Accepted is recorded per policy hash, so any change makes
the probe pending again.

## Where it runs

- **Switch refusal:** `lane.sh switch` and `lane.sh verify` call
  `grants.sh check --gate KEY CLIENT` and refuse to route an operator to a
  side that is not rendered and resolved.
- **Nightly hygiene** reports `grants.sh check --findings`.
- **First run:** `bootstrap.sh` lists the grants check among the steps.

Read commands (`validate`, `check`, the gate) and dry runs create nothing.
The renderers write only these two files, only when run, and only after a
person adds a baseline they have read. Approval configuration changes are
the owner's call; nothing in the kit runs a renderer on a schedule.
