# Maintaining Transmogrify

This repository is public. Read [README.md](README.md) and
[CONTRIBUTING.md](CONTRIBUTING.md) first (for the operations layer also
[docs/operations/README.md](docs/operations/README.md) and
[its contributing notes](docs/operations/contributing.md)); load other files
only when a task needs them.

- Two layers: operations (`ops/`, `kit/`, `docs/operations/`, `skills/`,
  `test/ops/`; POSIX sh) and workers (`scripts/`, `SKILL.md`, `docs/`,
  `test/`; Node.js). "Lane" means a worker lane only; moving an operator
  between apps is a switch (`ops/switch.sh`).
- Rules live only in `kit/KIT.md`, by stable ID; docs point to IDs; skills
  point to docs; [skills/README.md](skills/README.md) indexes every skill.
- Fictional examples only: no real people, companies, hosts, accounts,
  paths or incidents, and no AI attribution.
- Before every commit: the leak guard, `sh ops/check.sh leaks` (install it
  as the pre-commit hook with `sh ops/install.sh precommit`; the private
  denylist stays outside the repository).
- Before every pull request: `npm test`, `sh ops/check.sh kit`, `shellcheck`
  (the file list in `.github/workflows/ci.yml`) and `sh test/ops/run.sh`
  (sh and dash).
