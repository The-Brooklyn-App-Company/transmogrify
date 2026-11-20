# Client permission patterns

Placeholders for the human to adapt and apply in each client's own
settings. Agents do not apply these. The kit writes a client's settings
only in the first run and only on the human's yes: the grants and the
Codex recovery hook.

## Claude Code

Applied in the client's settings for this home (for example a local
settings file next to the project). Fill in the paths and commands.

```json
{
  "permissions": {
    "allow": ["Bash(git status:*)", "Bash(git diff:*)", "Bash(<kit-dir>/ops/status.sh:*)"],
    "ask": ["Bash(git push:*)"],
    "deny": ["Bash(git push --force:*)", "Read(<secrets-dir>/**)"]
  }
}
```

### Compaction recovery hook

Claude Code cuts SessionStart hook output over about 10 KB to a short
preview, so the kit's hook prints a capped digest (under 8 KB) that orders
the session to read the full files first. Register it for this home:

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "compact|resume",
        "hooks": [{ "type": "command", "command": "<kit-dir>/ops/recover-context.sh" }] }
    ]
  }
}
```

On Codex, `bootstrap.sh` writes the hook for you, on your yes, into
`~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`; Codex reads hooks from
there or from `[hooks]` in `config.toml`, never both):

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup|resume|compact|fork",
        "hooks": [{ "type": "command", "command": "<kit-dir>/ops/recover-context.sh",
                    "statusMessage": "Loading recovery digest", "timeout": 10 }] }
    ]
  }
}
```

Then trust it once in the interactive Codex CLI (the desktop app has no
`/hooks`): run `codex -C <oracle-home>`, type `/hooks`, choose SessionStart,
Trust, and `/exit`. `bootstrap.sh` reads the trust record Codex writes in
`config.toml` and checks with one read-only run that the digest arrives. The
digest stays under about 2,000 tokens. Re-trust after any edit to the file.

### Mailroom home

The Claude Mailroom (the kit's `docs/operations/mailroom.md`) needs `Bash(<kit-dir>/ops/mailroom.sh:*)` (or `Bash(sh <kit-dir>/ops/mailroom.sh:*)`)
in its allow list and nothing else beyond `SendMessage`.

## Codex

Applied in the Codex configuration for this home: sandbox level and
approval policy, for example `sandbox_mode = "workspace-write"` with
`approval_policy = "on-request"`, and every tool server that can act on the
outside world disabled unless this operator's mandate needs it.

## What a pattern allows, and never allows

| Allows | Never allows |
| --- | --- |
| Reading and editing this home and its work repositories | Anything on the never-relayed list (K-03) |
| Running the kit's read-only scripts and the repositories' tests | Reading secrets or printing credentials (K-05) |
| Committing and pushing to this operator's own branches | Force-pushing, or pushing to a branch it does not own (K-16) |
| | Changing its own permission settings |
