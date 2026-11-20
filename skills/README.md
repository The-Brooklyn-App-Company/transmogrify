# Skill index

Every skill Transmogrify ships, in one place. Each one is a short procedure
that points to the guide holding the detail; none restates a rule
([kit/KIT.md](../kit/KIT.md) holds those).

| Skill | Layer | Load it when | File |
| --- | --- | --- | --- |
| `transmogrify` | Workers | Coordinating worker lanes in Codex or Claude Code: spawn, steer, harvest, retire, reconcile | [SKILL.md](../SKILL.md) |
| `operator-setup` | Operations | Setting up an Oracle home or a new operator, or re-checking a setup | [operator-setup](operator-setup/SKILL.md) |
| `review-handoff` | Operations | Preparing a delegation packet, implementing from one, reviewing at an exact commit, or triaging cross-review findings | [review-handoff](review-handoff/SKILL.md) |
| `release-closeout` | Operations | Declaring activation needs in a pull request, promoting a release, following it until it settles | [release-closeout](release-closeout/SKILL.md) |
| `return-to-desk` | Operations | The human comes back after time away and wants one catch-up | [return-to-desk](return-to-desk/SKILL.md) |
| `model-bakeoff` | Operations | Choosing or changing the model for a role or a recurring job | [model-bakeoff](model-bakeoff/SKILL.md) |

## How they are installed

`./install.sh` (or the start prompt) copies the whole package into each
app's skill folder as `transmogrify`, so the `transmogrify` skill is listed
at once. The operations skills sit inside that copy under `skills/`; link
them into an app's skill folder with:

```sh
sh "$SKILL_ROOT/ops/install.sh" --dry-run skills --target ~/.claude/skills
sh "$SKILL_ROOT/ops/install.sh" skills --target ~/.claude/skills
sh "$SKILL_ROOT/ops/install.sh" skills --target ~/.agents/skills
```

It links, never copies, and never replaces a folder it did not create. Each
operations skill finds the package as two levels above its own real path.

## Adding a skill

One folder per skill, `skills/<name>/SKILL.md`, with `name` and
`description` front matter, ten steps or fewer, and links to the guide that
holds the detail. Add a row here. `sh ops/check.sh kit` checks the skills' links.
