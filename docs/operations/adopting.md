# Adopting Transmogrify on a second machine

For a second person who joins someone already running Transmogrify: a
teammate who will run their **own** Oracle on their **own** always-on Mac,
with both Claude Code and Codex (the "both clients" profile). The first
adopter is called the maintainer here; the second, you. The examples are
fictional: the team `acme`, the people `alex` (maintainer) and `sam` (you).

## What is shared, and what never is

Two people's instances meet only on the git host, the tracker and the team
repository ([K-18](../../kit/KIT.md)). Nothing else crosses.

| Shared (through the team repository) | Yours alone, never copied from the maintainer |
| --- | --- |
| The release tag both of you are pinned to (`kit:` in `TEAM.md`) | Your machine, its profile and its launchd units |
| `TEAM.md`: team parameters, team rules (`T-nn`), the review bar | Your Oracle home, operator homes, registry and session ids |
| `PROJECTS.tsv`: which repositories exist and who owns each | Your grants file, written from **your** words ([grants](grants.md)) |
| Pull requests and reviews on the git host | Your sign-ins, secrets and Keychain items ([K-05](../../kit/KIT.md)) |

Do not clone or copy the maintainer's homes, registry, grants or profile
to save time: they name another person's sessions, approvals and paths, and
the checks will flag them as drift at best. Start fresh.

## Before you start

- A Mac that stays on and signed in (the operations layer is macOS first;
  Linux is best effort for the `sh` layer only).
- Git, `jq`, the system Python, and Node.js 20 or newer.
- Claude Code and Codex installed, each signed in **by you**, on your own
  accounts. Transmogrify never signs in for anyone.
- Read access to the team repository, and the release tag it pins.

## 1. Install the pinned release

Paste the start prompt into Claude Code or Codex:

```text
Fetch https://transmogrify.sh/start and follow its instructions.
```

Or from source, at the tag `TEAM.md` names (here `v2.0.0`):

```sh
git clone https://github.com/The-Brooklyn-App-Company/transmogrify.git ~/src/transmogrify
cd ~/src/transmogrify && git checkout v2.0.0
npm ci --ignore-scripts && ./install.sh --dry-run && ./install.sh
```

Use the same tag as the maintainer. A different version is allowed only
through a pin-bump pull request to the team repository
([architecture](architecture.md#teams)).

## 2. Run the first run with the "both clients" profile

```sh
export SKILL_ROOT="$HOME/.agents/skills/transmogrify"
export REPO_ROOT=/absolute/path/to/a/repository/you/work/in
node "$SKILL_ROOT/scripts/doctor.js" --repo-root "$REPO_ROOT" --target all --operations --explain
node "$SKILL_ROOT/scripts/setup.js" --repo-root "$REPO_ROOT"   # worker lanes, one consent at a time
sh "$SKILL_ROOT/ops/bootstrap.sh" --example both
```

`--example both` starts your profile from `ops/profiles/both.profile`: an
Oracle that can run on either app, a bridge ("Mailroom") in each, and a
toehold for every home in the other app. `bootstrap.sh` asks for your
choices: the app you start the Oracle on, your Oracle home (a new private
repository, for example `~/ops/oracle`), your timezone, the models for each
role, and the Oracle lock. Choose models with your own judgment and your
own subscriptions; there is no need to match the maintainer's.

It then applies the host settings on your yes and ends with the in-app
steps: sign in, start and pin your Oracle, start the two Mailroom sessions,
register the recovery hook. Do each one and re-run `bootstrap.sh` until
the checklist is clear; the last check is a test note delivered to your
Oracle ([first run](hosts-and-ci.md#first-run)).

## 3. Join the team layer

1. Clone the team repository next to your Oracle home.
2. Record its path on the `team:` line of your Oracle home's
   `KIT.local.md` (`ops/install.sh oracle <home> --team <dir>` writes it
   when it creates a home). The team's parameters and rules bind you
   through `TEAM.md`, and only through it.
3. Add yourself where `TEAM.md` and `PROJECTS.tsv` say, by pull request;
   the maintainer reviews it.

A team rule marked `required` cannot be overridden in your personal layer;
a `default` one can, with `override T-nn: <reason>` in your `KIT.local.md`.

## 4. Your first operator

```sh
sh "$SKILL_ROOT/ops/operator.sh" create api --owns git@git.example.com:acme/api.git
```

Pick an outcome you own in `PROJECTS.tsv`. Work in repositories someone
else owns happens as a contributor: your own worktree, `<operator>/<topic>`
branches, never their default branch or primary checkout
([K-16](../../kit/KIT.md)).

## 5. Your grants

Standing approvals are personal. Write your grants file from your own
words ([template](../../ops/templates/oracle/GRANTS.md), [grants](grants.md));
never copy the maintainer's. `bootstrap.sh` shows what it would write into
each app's settings and writes only on your yes. Until you have grants,
every approval comes to your Oracle as an ask.

## 6. Check that it is done

Done means the whole thing works end to end ([K-11](../../kit/KIT.md)):

- [ ] `bootstrap.sh status` lists nothing left.
- [ ] `sh "$SKILL_ROOT/ops/check.sh" host` and `sh "$SKILL_ROOT/ops/status.sh"` are clean.
- [ ] A note written with `ops/inbox-put.sh` to your operator arrives in
      its app, and `ops/mailroom.sh metrics` shows the tier it took.
- [ ] A note to your operator in the *other* app arrives through that
      app's Mailroom.
- [ ] A worker lane from your operator hands back a commit
      ([examples](../../examples/README.md)).
- [ ] Your first pull request to a team repository was reviewed by the
      other model family ([review and release](review-and-release.md)).

## Upgrading later

Upgrade only to a release tag, after the team repository's pin moves: check
out the new tag, re-run `./install.sh`, then `bootstrap.sh` and
`ops/install.sh sync` for any new files. Read the changelog's migration
notes first ([CHANGELOG](../../CHANGELOG.md)).
