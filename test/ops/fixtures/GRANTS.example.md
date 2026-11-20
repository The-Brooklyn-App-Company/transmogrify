# Standing grants (fictional example)

The owner's standing grants, one source for both clients. `ops/grants.sh`
renders them; never edit a rendered copy by hand.

## Known Codex baselines

<!-- baselines:begin -->
| cli | policy sha256 | bytes | verified |
|---|---|---|---|
| 9.9.9-test | f5f98f09e5996039cf6cb3671f5370513f8c3ea63c5c148ecbc50ffff03aad82 | 88 | 2026-01-01 (read by the owner) |
<!-- baselines:end -->

## Codex preamble

<!-- preamble:begin -->
~~~text
## Standing grants from the owner (rendered by ops/grants.sh; do not edit here)

Scope. These clauses recognize only standing grants the owner has already given, for the session of this home: `{key}` ("{name}"), working in {home}. They create no other authority. Every rule above still applies.
~~~
<!-- preamble:end -->

## Grants

<!-- grants:begin -->

### grant: own-merges
- title: Own Reviewed Merges
- actors: operators
- codex: yes
- expires: never
- words: 2026-01-02 | JOURNAL.md "2026-01-02 merges" | Merge your own reviewed pull requests once checks are green, and tell me after.

Allowed:
- Normal merges of the operator's own pull requests in its own repositories once checks pass and the required reviewers approve.
- [only: beta] Merging the release branch into main once the owner has said yes to that release.

Limits:
- One pull request at a time, each at its reviewed head.

Does NOT cover:
- Force-push or history rewrite.
- Production deploys.
- [no-include] Repositories the operator does not own.

Claude:
~~~text
Own Reviewed Merges (the owner, 2026-01-02, verbatim: "Merge your own reviewed pull requests once checks are green, and tell me after."): operator sessions listed in the registry may merge their own pull requests in their own repositories once checks pass and the required reviewers approve, each at its reviewed head. Does NOT cover: force-push or history rewrite, production deploys, or repositories the operator does not own.
~~~

### grant: cheap-calls
- title: Paid Calls Under One Dollar
- actors: oracle, operators
- codex: yes
- expires: 2099-12-31
- words: 2026-01-03 | JOURNAL.md "2026-01-03 spend" | You can run paid calls under a dollar each without asking, as long as you report them.

Allowed:
- Paid model or API calls with a hard cap under one dollar per run, reported in the next brief.

Does NOT cover:
- One dollar or more per run.
- @include own-merges

Claude:
~~~text
Paid Calls Under One Dollar (the owner, 2026-01-03, verbatim: "You can run paid calls under a dollar each without asking, as long as you report them."): the Oracle and operator sessions in the registry may run paid model or API calls with a hard cap under one dollar per run, reported in the next brief. Does NOT cover: one dollar or more per run.
~~~

### grant: notes-only
- title: Oracle Notes
- actors: oracle
- codex: no (the Oracle's notes are a Claude-side habit in this example)
- expires: never
- words: 2026-01-04 | JOURNAL.md "2026-01-04 notes" | Keep your own notes tidy without asking.

Claude:
~~~text
Oracle Notes (the owner, 2026-01-04, verbatim: "Keep your own notes tidy without asking."): the Oracle session may edit and commit its own NOTES.md without asking.
~~~

<!-- grants:end -->
