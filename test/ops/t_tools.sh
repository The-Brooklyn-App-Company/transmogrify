#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_tools.sh - status.sh, inbox-put.sh, check.sh and drift-check.sh.
. "$(dirname -- "$0")/lib.sh"

test_status_columns() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  transcript "$T/proj/alpha" 202611171100
  printf 'beta\t2026-12-31\tparked\n' >"$T/home/operators/WATCHDOG-QUIET.tsv"
  printf 'gamma\tGamma\t%s\tpending\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  printf 'delta\tDelta\t%s\tsid-d\tfile-only\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  note beta b1.md x
  note beta b2.md y
  run status.sh --tsv
  assert_rc 0
  assert_eq "$(sed -n 1p "$T/out")" "alpha${TAB}Alpha Op${TAB}claude${TAB}idle_min=60${TAB}-${TAB}0${TAB}-"
  assert_eq "$(sed -n 2p "$T/out")" "beta${TAB}Beta Op${TAB}claude${TAB}no-transcript${TAB}2026-12-31${TAB}2${TAB}-"
  assert_eq "$(sed -n 3p "$T/out")" "gamma${TAB}Gamma${TAB}claude${TAB}pending${TAB}-${TAB}0${TAB}-"
  assert_eq "$(sed -n 4p "$T/out")" "delta${TAB}Delta${TAB}file-only${TAB}unknown${TAB}-${TAB}0${TAB}-"
  assert_lacks "$T/out" "Oracle"
  run status.sh --all
  assert_has "$T/out" "AUDIT"
  assert_has "$T/out" "Oracle"
  assert_no_file "$T/state/relay.log"
}

test_status_prefers_exact_claude_session() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  transcript "$T/proj/alpha" 202611171150
  _slug=$(printf '%s' "$T/proj/alpha" | sed 's/[^A-Za-z0-9]/-/g')
  : >"$T/claude/projects/$_slug/sid-alpha.jsonl"
  touch -t 202611170800 "$T/claude/projects/$_slug/sid-alpha.jsonl"
  run status.sh --tsv
  assert_has "$T/out" "alpha${TAB}Alpha Op${TAB}claude${TAB}idle_min=240"
}

test_status_codex_activity() {
  AO_NOW=$(epoch_of "2026-11-17 12:00")
  export AO_NOW
  printf 'gamma\tGamma\t%s\tabc-123\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  mkdir -p "$T/codex/sessions/2026/11/17"
  : >"$T/codex/sessions/2026/11/17/rollout-x-abc-123.jsonl"
  touch -t 202611171130 "$T/codex/sessions/2026/11/17/rollout-x-abc-123.jsonl"
  run status.sh --tsv
  assert_has "$T/out" "gamma${TAB}Gamma${TAB}codex${TAB}idle_min=30"
}

test_inbox_put() {
  printf 'hello\n' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" alpha "PR watch!" >"$T/out" 2>"$T/err"
  assert_eq "$?" 0
  f=$(cat "$T/out")
  case $f in "$T/home/inbox/alpha/"*-PR-watch-.md) ;; *) _fail "unexpected path $f" ;; esac
  assert_has "$f" hello
  printf 'again\n' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" alpha "PR watch!" >/dev/null
  printf '' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" alpha empty 2>/dev/null
  assert_eq "$?" 2
  printf 'x\n' | "$AO_TEST_SHELL" "$SCRIPTS/inbox-put.sh" nobody x 2>/dev/null
  assert_eq "$?" 2
  assert_count "$T/home/inbox/alpha" 2
}

dupe_fixture() {
  mkdir -p "$T/docs"
  cat >"$T/docs/a.md" <<'EOF'
# Rules
- **Never** relay money movement, trades, or force-push requests through the inbox.
Short line.
```
This code block line is long enough to count as a rule but must be ignored here.
```
EOF
  cat >"$T/docs/b.md" <<'EOF'
Intro. Never relay money movement, trades or force-push requests through the inbox!
This code block line is long enough to count as a rule but must be ignored here.
A sentence repeated within one file only, which is not a cross-file duplicate.
A sentence repeated within one file only, which is not a cross-file duplicate.
EOF
}

test_check_privacy_tracked_odd_names() {
  mkdir -p "$T/repo"
  (cd "$T/repo" && git init -q . && printf 'x %s\n' "dev@""fictional.zz" >'odd"name.md' && git add .) || return 0
  (cd "$T/repo" && "$AO_TEST_SHELL" "$SCRIPTS/check.sh" privacy >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" 'odd"name.md:1: e-mail address'
}

test_check_dupes() {
  dupe_fixture
  run check.sh dupes "$T/docs/a.md" "$T/docs/b.md"
  assert_rc 1
  assert_eq "$(wc -l <"$T/out" | tr -d ' ')" 1
  assert_has "$T/out" "$T/docs/a.md:2, $T/docs/b.md:1: \"never relay money movement"
  printf 'Never relay money movement, trades or\nforce-push requests through the inbox.\n' >"$T/docs/c.md"
  run check.sh dupes "$T/docs/a.md" "$T/docs/c.md"
  assert_rc 1
  assert_has "$T/out" "$T/docs/c.md:1"
  run check.sh dupes --min-words 30 "$T/docs/a.md" "$T/docs/b.md"
  assert_rc 0
  run check.sh dupes
  assert_rc 2
}

test_check_skills() {
  mkdir -p "$T/skills/good" "$T/skills/bad"
  printf -- '---\nname: good\n---\nSee docs/operations/architecture.md#roles.\n' >"$T/skills/good/SKILL.md"
  printf -- '---\nname: bad\n---\nAll the rules inline.\n' >"$T/skills/bad/SKILL.md"
  run check.sh skills "$T/skills"
  assert_rc 1
  assert_has "$T/out" "bad/SKILL.md: no pointer"
  assert_lacks "$T/out" "good/SKILL.md"
  run check.sh skills --max-lines 2 "$T/skills/good"
  assert_has "$T/out" "4 lines (cap 2)"
}

test_check_privacy() {
  mkdir -p "$T/repo"
  home_path="/Us""ers/someone/project"
  printf 'path %s here\n' "$home_path" >"$T/repo/a.md"
  printf 'mail %s and dev@example.com\n' "ops@""fictional-co.zz" >"$T/repo/b.md"
  printf 'Codename Bluebird ships\nclean line\n' >"$T/repo/c.md"
  printf "cd '%s'\n" "/ho""me/bob" >"$T/repo/odd | name=x.md"
  printf 'x %s\n' "dev@""fictional.zz" >"$T/repo/-dash\"quote.md"
  printf '# local denylist\n\nbluebird\n' >"$T/deny"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 1
  assert_has "$T/out" "$T/repo/a.md:1: home path"
  assert_has "$T/out" "$T/repo/b.md:1: e-mail address"
  assert_has "$T/out" "$T/repo/c.md:1: denylist match"
  assert_has "$T/out" "$T/repo/odd | name=x.md:1: home path"
  assert_has "$T/out" "$T/repo/-dash\"quote.md:1: e-mail address"
  assert_lacks "$T/out" "c.md:2"
  assert_lacks "$T/out" "someone"
  assert_lacks "$T/out" "Bluebird"
  printf 'nothing to see\n' >"$T/repo/a.md"
  printf 'dev@example.com\n' >"$T/repo/b.md"
  printf 'clean\n' >"$T/repo/c.md"
  printf 'clean\n' >"$T/repo/odd | name=x.md"
  printf 'clean\n' >"$T/repo/-dash\"quote.md"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 0
}

drift_fixture() {
  dupe_fixture
  cp "$T/docs/a.md" "$T/home/RULES.md"
  mkdir -p "$T/home/operators/alpha"
  cp "$T/docs/b.md" "$T/home/operators/alpha/MANDATE.md"
  printf 'Repo rules for alpha.\n' >"$T/proj/alpha/AGENTS.md"
  profile_set drift_rules RULES.md
  profile_set drift_files "operators/*/MANDATE.md"
  mkdir -p "$T/home/operators/with space"
  printf 'A spaced mandate.\n' >"$T/home/operators/with space/MANDATE.md"
}

test_drift_worker_pass() {
  drift_fixture
  FAKE_OUTPUT="RULES.md:2 - duplicated - one home" run drift-check.sh
  assert_rc 0
  assert_has "$FAKE_LOG" "read-only consistency auditor"
  assert_has "$FAKE_LOG" "Canonical rules: $T/home/RULES.md"
  assert_has "$FAKE_LOG" "$T/home/operators/alpha/MANDATE.md"
  assert_has "$FAKE_LOG" "$T/proj/alpha/AGENTS.md"
  assert_has "$FAKE_LOG" "$T/home/operators/with space/MANDATE.md"
  assert_has "$FAKE_LOG" "never relay money movement"
  assert_has "$(ls "$T/home/inbox/oracle"/*-drift-check.md)" "duplicated - one home"
}

test_drift_without_worker_is_deterministic() {
  drift_fixture
  profile_set worker_client none
  run drift-check.sh
  assert_rc 0
  assert_no_file "$FAKE_LOG"
  assert_has "$(ls "$T/home/inbox/oracle"/*-drift-check.md)" "Drift check (deterministic only)"
}

test_drift_print_and_extra() {
  drift_fixture
  printf 'Also flag the retired tool Foo.\n' >"$T/home/extra.md"
  profile_set drift_prompt_extra extra.md
  run drift-check.sh --print
  assert_rc 0
  assert_has "$T/out" "Also flag the retired tool Foo."
  assert_has "$T/out" "## Deterministic duplicate-text findings"
  assert_no_file "$FAKE_LOG"
  assert_no_file "$T/home/inbox/oracle"
}

test_drift_needs_files() {
  run drift-check.sh --deterministic-only
  assert_rc 2
  assert_has "$T/err" "nothing to audit"
}

test_check_privacy_more_forms() {
  mkdir -p "$T/repo"
  printf 'see file://%s/x\n' "/Us""ers/alice" >"$T/repo/a.md"
  printf 'cc -I%s/inc\n' "/Us""ers/alice" >"$T/repo/b.md"
  printf 'cd %s\n' "~ali""ce/src" >"$T/repo/c.md"
  bs=$(printf '\134')
  printf 'C:%sUsers%salice\n' "$bs" "$bs" >"$T/repo/d.md"
  printf 'fine\n' >"$T/repo/bluebird-notes.md"
  printf '\000\001binary' >"$T/repo/e.bin"
  printf 'it was planned\n' >"$T/repo/f.md"
  printf 'ask Ann first\n' >"$T/repo/g.md"
  printf 'bluebird\n=ann\n' >"$T/deny"
  run check.sh privacy --denylist "$T/deny" "$T/repo"
  assert_rc 1
  assert_lacks "$T/out" "f.md"
  assert_has "$T/out" "$T/repo/g.md:1: denylist match"
  for f in a b c d; do assert_has "$T/out" "$T/repo/$f.md:1: home path"; done
  assert_has "$T/out" "bluebird-notes.md: denylist match in the file name"
  assert_has "$T/out" "$T/repo/e.bin: binary, not scanned"
}

test_check_links() {
  mkdir -p "$T/d/sub"
  printf '# Top\n## Two words, here!\n## Two words, here!\n' >"$T/d/sub/t.md"
  cat >"$T/d/a.md" <<'MD'
[ok](sub/t.md) [ok2](sub/t.md#two-words-here) [dup](sub/t.md#two-words-here-1)
[self](#local) [web](https://example.com/x) [dir](sub)
`[code](nowhere.md)`
[dead](missing.md) [badfrag](sub/t.md#nope)
```
[fenced](nowhere.md)
```
## Local
MD
  run check.sh links "$T/d/a.md"
  assert_rc 1
  assert_eq "$(wc -l <"$T/out" | tr -d ' ')" 2 "dead links"
  assert_has "$T/out" "a.md:4: missing.md"
  assert_has "$T/out" "a.md:4: sub/t.md#nope (no such heading)"
}

test_check_home() {
  mkdir -p "$T/h1" "$T/h2"
  for h in h1 h2; do printf 'x\n' >"$T/$h/AGENTS.md"; printf 'x\n' >"$T/$h/MANDATE.md"; done
  printf '@AGENTS.md\n' >"$T/h1/CLAUDE.md"
  printf 'key=web\nwork.app=git@git.example.com:o/app.git|owner\n' >"$T/h1/operator.conf"
  run check.sh home "$T/h1"
  assert_rc 0
  printf 'Read AGENTS.md and also this rule.\n' >"$T/h2/CLAUDE.md"
  printf 'key=infra\nwork.app=git@git.example.com:o/app.git|owner\nwork.x=u|boss\n' >"$T/h2/operator.conf"
  run check.sh home "$T/h1" "$T/h2"
  assert_rc 1
  assert_has "$T/out" "h2/CLAUDE.md: must contain only @AGENTS.md"
  assert_has "$T/out" "owned by more than one home: git.example.com/o/app"
  assert_has "$T/out" "h2/operator.conf:3: work value must end"
}

test_scripts_and_hooks_are_executable() {
  # Hooks and scripts call each other directly, so each must carry its
  # executable bit (and the tests otherwise run them through a shell).
  for f in "$SCRIPTS"/*.sh "$SCRIPTS"/adapters/*.sh "$SCRIPTS"/examples/hooks/*/* \
    "$SCRIPTS"/examples/tracker-linear/*.sh; do
    [ -x "$f" ] || _fail "not executable: ${f#"$SCRIPTS"/}"
  done
}

# leak_repo  A git checkout with a project contact in package.json.
leak_repo() {
  mkdir -p "$T/repo"
  (cd "$T/repo" && git init -q . && git config user.email t@example.invalid && git config user.name t) || return 1
  printf '{\n  "author": {\n    "email": "%s"\n  }\n}\n' "help@""project.zz" >"$T/repo/package.json"
}

test_check_leaks_generic_rules() {
  leak_repo || return 0
  {
    printf 'path %s/notes\n' "/Users/""alice"
    printf 'fine %s and %s\n' "/Users/""example/x" "/home/""runner/work"
    printf 'mail %s\n' "alice@""corp.zz"
    printf 'contact %s, noreply %s\n' "help@""project.zz" "noreply@""anthropic.com"
    printf 'channel %s\n' "C0""1ABCDE2FG"
    printf 'integrity sha512-4LCcse/%s+v71o7yOdIe4cZ70Wpf8D/IyjDKYQLV5GD46B+hSTjJsvV5PztjvHoU580EftxjDZFQ==\n' "U2""MHZ63HAJVE"
    printf 'key %s\n' "sk-""abcdefghijklmnopqrstuvwx"
    printf 'aws %s\n' "AKIA""ABCDEFGHIJKLMNOP"
    printf '%s\n' "-----BEGIN RSA ""PRIVATE"" KEY-----"
    printf 'security find-generic-''password -s %s -w\n' "corp-token"
    printf 'security find-generic-''password -s "$1" -w\n'
    printf 'channel %s leak-ok: L03\n' "C0""9ZYXWV8UT"
  } >"$T/repo/doc.md"
  (cd "$T/repo" && git add -A)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" "doc.md:1: L01"
  assert_lacks "$T/out" "doc.md:2:"
  assert_has "$T/out" "doc.md:3: L02"
  assert_lacks "$T/out" "doc.md:4:"
  assert_has "$T/out" "doc.md:5: L03"
  assert_lacks "$T/out" "doc.md:6:"
  assert_has "$T/out" "doc.md:7: L04"
  assert_has "$T/out" "doc.md:8: L04"
  assert_has "$T/out" "doc.md:9: L04"
  assert_has "$T/out" "doc.md:10: L05"
  assert_lacks "$T/out" "doc.md:11:"
  assert_lacks "$T/out" "doc.md:12:"
  # The staged copy is reported too, and the report never quotes the text.
  assert_has "$T/out" "staged:doc.md:1: L01"
  assert_lacks "$T/out" "alice"
}

test_check_leaks_private_denylist() {
  leak_repo || return 0
  mkdir -p "$T/private"
  printf '# names\n=bob\nacme widgets\n!Bob Publisher\n' >"$T/private/deny"
  printf 'Planned with Bob.\nAcme Widgets ship.\nbobcat is fine.\nCopyright Bob Publisher.\n' >"$T/repo/notes.md"
  printf 'x\n' >"$T/repo/bob-notes.md"
  (cd "$T/repo" && git add -A && git commit -qm init)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/private/deny "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" "notes.md:1: D2"
  assert_has "$T/out" "notes.md:2: D3"
  assert_lacks "$T/out" "notes.md:3:"
  assert_lacks "$T/out" "notes.md:4:"
  assert_has "$T/out" "bob-notes.md: D2 (file name)"
  assert_lacks "$T/out" "Bob"
  assert_lacks "$T/out" "acme"
  # Without the denylist (CI): clean.
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/private/deny "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 0
  # A denylist inside the repository is refused, and so is a missing one.
  cp "$T/private/deny" "$T/repo/deny.txt"
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/repo/deny.txt "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 2
  assert_has "$T/err" "must live outside this repository"
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/private/none "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 2
}

test_check_leaks_staged_only_and_the_precommit_hook() {
  leak_repo || return 0
  printf 'clean\n' >"$T/repo/a.md"
  (cd "$T/repo" && git add -A && git commit -qm init)
  printf 'mail %s\n' "carol@""corp.zz" >"$T/repo/b.md"
  (cd "$T/repo" && git add b.md)
  # Only the staged copy counts with --staged; the working copy may differ.
  printf 'clean now\n' >"$T/repo/b.md"
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --staged >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" "staged:b.md:1: L02"
  assert_lacks "$T/out" "a.md"
  # The hook: installed, kept on a second run, and it stops the commit.
  run install.sh precommit "$T/repo"
  assert_rc 0
  assert_has "$T/repo/.git/hooks/pre-commit" "check.sh' leaks --staged"
  run install.sh precommit "$T/repo"
  assert_has "$T/out" "keep    "
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' git commit -qm leak >"$T/out" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || _fail "the hook let a leaking commit through"
  assert_has "$T/out" "staged:b.md:1: L02"
  # A hook someone else wrote is never replaced.
  printf '#!/bin/sh\nexit 0\n' >"$T/repo/.git/hooks/pre-commit"
  run install.sh precommit "$T/repo"
  assert_rc 1
  assert_has "$T/err" "was not written by this kit; left alone"
}

# ao_timeout_run CMD...  Stop an owned test command tree at its deadline,
# including nested process groups. Freeze each parent before finding its
# children, then kill children first: stopped parents cannot reap/recycle
# the PIDs while cleanup uses them.
ao_timeout_run() {
  /usr/bin/python3 -I - "${AO_TEST_TIMEOUT_SECONDS:-20}" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, start_new_session=True)

def freeze_tree(pid, frozen):
    try:
        os.kill(pid, signal.SIGSTOP)
    except ProcessLookupError:
        return
    frozen.append(pid)
    children = subprocess.run(
        ["/usr/bin/pgrep", "-P", str(pid)], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2)
    if children.returncode not in (0, 1):
        raise RuntimeError("cannot enumerate the owned test children")
    for value in children.stdout.split():
        freeze_tree(int(value), frozen)

try:
    status = child.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    frozen = []
    try:
        freeze_tree(child.pid, frozen)
    finally:
        for pid in reversed(frozen):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait()
    status = 124
sys.exit(status if status >= 0 else 128 - status)
PY
}

test_check_leaks_more_forms() {
  leak_repo || return 0
  {
    printf 'env SLACK_CHANNEL=%s\n' "C0""6ABCDEF12"
    printf 'url https://app.slack.com/archives/%s\n' "C0""6ABCDEF12"
    printf 'name slack-%s\n' "C0""6ABCDEF12"
    printf 'user %s=\n' "U0""6ABCDEF12"
    printf 'escaped "\\/Users\\/%s\\/x"\n' "alice"
    printf 'project -Users-%s-Projects-x\n' "alice"
    printf 'mount /System/Volumes/Data/Users/%s/x\n' "alice"
    printf 'win C:\\Users\\%s\\x\n' "alice"
    printf 'hook https://hooks.slack.com/%s/T000/B000/XXXX\n' "services"
    printf 'jwt %s.%s.%s\n' "eyJ""hbGciOiJIUzI1NiJ9" "eyJzdWIiOiIxMjM0NTY3ODkwIn0" "abcdefghijklmnop"
    printf 'stripe %s\n' "sk_""live_abcdefghijklmnopqrstu"
    printf 'gitlab %s\n' "glpat""-abcdefghijklmnopqrst"
    printf 'mail %s\n' "12345+alice@users.""noreply.github.com"
    printf 'fine %s and example C0 tokens CHANGELOG2\n' "git@""github.com"
    printf 'link https://acme.slack.com/archives/%s/p1700000000000000\n' "C0""6ABCDEF12"
    printf 'thread https://app.slack.com/client/%s/%s/thread/%s-1700000000.000100\n' "T0""6ABCDEF12" "C0""6ABCDEF12" "C0""6ABCDEF12"
    printf 'path docs/operations/slack/channels/exports/%s/notes\n' "C0""6ABCDEF12"
    printf 'hash "integrity": "sha1-%sabcdefghijklmnop="\n' "C0""6ABCDEF12"
    printf 'sha512-unrelated-word link https://app.slack.com/archives/%s\n' "C0""6ABCDEF12"
    printf 'query https://example.com/?q=a+b/archives/%s\n' "C0""6ABCDEF12"
    printf 'path docs/operations/slack/channels/exports/%s=\n' "C0""6ABCDEF12"
  } >"$T/repo/more.md"
  # Hash-like path names are not integrity values.
  printf 'path sha256-exports/%s/notes\n' "C0""6ABCDEF12" >>"$T/repo/more.md"
  printf 'url https://example.com/?path=sha512-exports/%s/notes\n' "C0""6ABCDEF12" >>"$T/repo/more.md"
  (cd "$T/repo" && git add -A)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  for l in 1 2 3 4; do assert_has "$T/out" "more.md:$l: L03"; done
  for l in 5 6 7 8; do assert_has "$T/out" "more.md:$l: L01"; done
  for l in 9 10 11 12; do assert_has "$T/out" "more.md:$l: L04"; done
  assert_has "$T/out" "more.md:13: L02"
  assert_lacks "$T/out" "more.md:14:"
  for l in 15 16 17; do assert_has "$T/out" "more.md:$l: L03"; done
  assert_lacks "$T/out" "more.md:18:"
  for l in 19 20 21; do assert_has "$T/out" "more.md:$l: L03"; done
  for l in 22 23; do assert_has "$T/out" "more.md:$l: L03"; done
  assert_has "$T/err" "leaks: no denylist: generic rules only"
  # A tracked symlink is scanned as its target path, not followed.
  rm "$T/repo/more.md"
  ln -s "/Users/""alice/notes.md" "$T/repo/link.md"
  (cd "$T/repo" && git add -A && git commit -qm link)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" "link.md:1: L01"
}

test_check_leaks_denylist_edges() {
  leak_repo || return 0
  mkdir -p "$T/private"
  # CRLF and trailing blanks are trimmed; a bare `! ` line is ignored (it used to hang).
  printf 'walrus\r\n=zed   \n! \n' >"$T/private/deny"
  printf 'a walrus\nzed here\nnothing\n' >"$T/repo/n.md"
  (cd "$T/repo" && git add -A)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/private/deny ao_timeout_run "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  assert_has "$T/out" "n.md:1: D1"
  assert_has "$T/out" "n.md:2: D2"
  assert_has "$T/err" "leaks: denylist: 2 rules, 0 allowed phrases"
  # leak-ok: D12 does not exempt D1.
  printf 'a walrus leak-ok: D12\na walrus leak-ok: D1\n' >"$T/repo/n.md"
  (cd "$T/repo" && git add -A)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/private/deny "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks >"$T/out" 2>"$T/err")
  assert_has "$T/out" "n.md:1: D1"
  assert_lacks "$T/out" "n.md:2:"
  # A link outside the repository to a denylist inside it is refused.
  cp "$T/private/deny" "$T/repo/inside.txt"
  ln -s "$T/repo/inside.txt" "$T/private/link"
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST=$T/private/link "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 2
  assert_has "$T/err" "must live outside this repository"
  # --require-denylist cannot pass vacuously.
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --require-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 2
  assert_has "$T/err" "--require-denylist: no denylist rules"
}

test_precommit_hook_carries_this_checkouts_denylist() {
  leak_repo || return 0
  mkdir -p "$T/private"
  printf '=walrus\n' >"$T/private/deny"
  run install.sh precommit --denylist "$T/private/deny" --require-denylist "$T/repo"
  assert_rc 0
  assert_has "$T/repo/.git/hooks/pre-commit" "TRANSMOGRIFY_LEAK_DENYLIST='$T/private/deny'"
  assert_has "$T/repo/.git/hooks/pre-commit" "leaks --staged --require-denylist"
  printf 'the walrus\n' >"$T/repo/w.md"
  (cd "$T/repo" && git add w.md && TRANSMOGRIFY_LEAK_DENYLIST='' git commit -qm w >"$T/out" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || _fail "the hook let a denylisted word through"
  assert_has "$T/out" "staged:w.md:1: D1"
  assert_lacks "$T/out" "walrus"
  # A rerun without options keeps the hook's denylist and requirement; --no-denylist drops them on purpose.
  run install.sh precommit "$T/repo"
  assert_rc 0
  assert_has "$T/repo/.git/hooks/pre-commit" "TRANSMOGRIFY_LEAK_DENYLIST='$T/private/deny'"
  assert_has "$T/repo/.git/hooks/pre-commit" "leaks --staged --require-denylist"
  run install.sh precommit --no-denylist "$T/repo"
  assert_rc 0
  assert_lacks "$T/repo/.git/hooks/pre-commit" "TRANSMOGRIFY_LEAK_DENYLIST="
  assert_lacks "$T/repo/.git/hooks/pre-commit" "--require-denylist"
  # A denylist inside the repository is refused.
  rm "$T/repo/.git/hooks/pre-commit"
  cp "$T/private/deny" "$T/repo/deny.txt"
  run install.sh precommit --denylist "$T/repo/deny.txt" "$T/repo"
  assert_rc 2
  assert_has "$T/err" "must live outside"
}

test_check_leaks_hash_payload_shapes() {
  leak_repo || return 0
  /usr/bin/python3 -I - "$T/repo/hashes.md" <<'PY'
import base64
import pathlib
import sys

identifier = "C0" "6ABCDEF12"
values = []
for name, length, padding in (("sha1", 28, 1), ("sha256", 44, 1), ("sha384", 64, 0), ("sha512", 88, 2)):
    value = "A" * (length - padding - len(identifier) - 3) + "/" + identifier + "+A" + "=" * padding
    assert base64.b64encode(base64.b64decode(value)).decode() == value
    values.append(value)
lines = [name + "-" + value for name, value in zip(("sha1", "sha256", "sha384", "sha512"), values)]
lines += ["sha256-" + values[0], "sha512-" + values[3][:-2] + "AA"]
pathlib.Path(sys.argv[1]).write_text("\n".join(lines) + "\n")
PY
  (cd "$T/repo" && git add -A)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 1
  for l in 1 2 3 4; do assert_lacks "$T/out" "hashes.md:$l:"; done
  for l in 5 6; do assert_has "$T/out" "hashes.md:$l: L03"; done
}

test_timeout_guard_stops_owned_descendants() {
  cat >"$T/bin/guard-tree" <<'EOF'
#!/bin/sh
trap '' TERM
sleep 5 &
printf '%s\n' "$!" >"$1"
wait
EOF
  chmod +x "$T/bin/guard-tree"
  start=$(date +%s)
  AO_TEST_TIMEOUT_SECONDS=2 ao_timeout_run "$T/bin/guard-tree" "$T/guard-child.pid"
  rc=$?
  assert_rc 124
  [ $(($(date +%s) - start)) -lt 8 ] || _fail "the timeout guard did not return promptly"
  child=$(cat "$T/guard-child.pid" 2>/dev/null)
  [ -n "$child" ] || { _fail "the guarded child never started"; return; }
  state=$(ps -o stat= -p "$child" 2>/dev/null)
  case $state in
    '' | *Z*) ;;
    *) _fail "the owned descendant outlived the timeout guard" ;;
  esac
}

test_timeout_guard_stops_nested_scan_groups() {
  leak_repo || return 0
  printf 'clean\n' >"$T/repo/a.md"
  (cd "$T/repo" && git add -A)
  real=$(command -v awk)
  cat >"$T/bin/awk" <<EOF
#!/bin/sh
for a in "\$@"; do
  case \$a in
    *"function exempt(rule"*)
      trap '' TERM
      printf '%s\n' "\$\$" >"$T/nested-awk.pid"
      sleep 5
      exit 0 ;;
  esac
done
exec "$real" "\$@"
EOF
  chmod +x "$T/bin/awk"
  start=$(date +%s)
  (cd "$T/repo" && AO_TEST_TIMEOUT_SECONDS=2 TRANSMOGRIFY_LEAK_DENYLIST='' TRANSMOGRIFY_LEAK_FILE_SECONDS=10 \
    ao_timeout_run "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  assert_rc 124
  [ $(($(date +%s) - start)) -lt 5 ] || _fail "the nested scan was not stopped by the outer deadline"
  child=$(cat "$T/nested-awk.pid" 2>/dev/null)
  [ -n "$child" ] || { _fail "the nested scanner never started"; return; }
  state=$(ps -o stat= -p "$child" 2>/dev/null)
  case $state in '' | *Z*) ;; *) _fail "the nested scanner outlived the guard" ;; esac
}

test_check_leaks_stops_a_scan_that_hangs() {
  leak_repo || return 0
  printf 'clean\n' >"$T/repo/a.md"
  (cd "$T/repo" && git add -A)
  # A slow awk for the leak program; it self-expires even if both guards regress.
  real=$(command -v awk)
  printf '#!/bin/sh\nfor a in "$@"; do case $a in *"function exempt(rule"*) exec sleep 9 ;; esac; done\nexec "%s" "$@"\n' "$real" >"$T/bin/awk"
  chmod +x "$T/bin/awk"
  start=$(date +%s)
  (cd "$T/repo" && TRANSMOGRIFY_LEAK_DENYLIST='' TRANSMOGRIFY_LEAK_FILE_SECONDS=2 \
    ao_timeout_run "$AO_TEST_SHELL" "$SCRIPTS/check.sh" leaks --no-denylist >"$T/out" 2>"$T/err")
  rc=$?
  rm -f "$T/bin/awk"
  [ $(($(date +%s) - start)) -lt 18 ] || _fail "the per-file budget did not stop the scan"
  assert_rc 1
  assert_has "$T/out" "a.md: not scanned (stopped after the 2 s budget)"
  assert_has "$T/err" "leak scan incomplete"
}

ao_test_main "$0"
