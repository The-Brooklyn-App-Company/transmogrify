#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_switch.sh - operator switches as a scripted checklist, holds, the Oracle lock,
# and the nightly hygiene check.
. "$(dirname -- "$0")/lib.sh"
# with_tty (the human verbs settle and takeover).
. "$(dirname -- "$0")/lease_lib.sh"

# home_repo DIR  Make an operator home a git repository with one commit.
home_repo() {
  git -C "$1" init -q && git -C "$1" config user.email t@example.com && git -C "$1" config user.name T &&
    printf 'x\n' >"$1/NOTES.md" && git -C "$1" add NOTES.md && git -C "$1" commit -q -m init
}
commit_handoff() {
  printf '%s\n' "${1:-handoff}" >"$T/proj/alpha/HANDOFF.md"
  git -C "$T/proj/alpha" add HANDOFF.md && git -C "$T/proj/alpha" commit -q -m handoff
}
# alpha_notes SLUG  Number of notes named *SLUG.md in alpha's inbox, also
# under a collision name (*SLUG-2.md, ...).
alpha_notes() {
  _c=0
  for _f in "$T/home/inbox/alpha"/*"$1".md "$T/home/inbox/alpha"/*"$1"-[0-9]*.md; do [ -f "$_f" ] && _c=$((_c + 1)); done
  echo "$_c"
}
# switch_in_copies  Switch-in notes for alpha wherever a placed note can be:
# the inbox (collision names too), claimed by the relay (in flight) or
# archived in the sent folder. Counted by their text, whatever the name.
switch_in_copies() {
  _c=0
  for _f in "$T/home/inbox/alpha"/*.md "$T/home/inbox/alpha/.claimed"/*/*.md "$T/home/inbox/sent"/*.md; do
    [ -f "$_f" ] && grep -q '^Operator switch (the Oracle, by switch.sh; automated, not from the human): you are now the active side for alpha ' "$_f" &&
      _c=$((_c + 1))
  done
  echo "$_c"
}
# audit_state  The AUDIT column status.sh prints for alpha.
audit_state() {
  run status.sh --tsv
  awk -F'\t' '$1 == "alpha" { print $7 }' "$T/out"
}
claude_calls() { _c=$(grep -c '^== claude' "$FAKE_LOG" 2>/dev/null); echo "${_c:-0}"; }
# shown_cmd VERB  The last `lease.sh --home HOME VERB ...` command printed in
# $T/out, exactly as printed: the shell words after lease.sh (plain, or
# single-quoted with '\'' for a quote), up to the first text that is not
# one (run it with: eval "run $(shown_cmd acquire)").
shown_cmd() {
  awk -v verb="$1" -v q="'" '
    BEGIN { w = "^ (" q "[^" q "]*" q "(\\\\" q q "[^" q "]*" q ")*|[A-Za-z0-9._-]+)" }
    {
      line = $0
      while ((i = index(line, "lease.sh --home ")) > 0) {
        rest = substr(line, i + 8); cmd = "lease.sh"; n = 0
        while (match(rest, w)) {
          n++; word[n] = substr(rest, 2, RLENGTH - 1)
          cmd = cmd " " word[n]; rest = substr(rest, RLENGTH + 1)
        }
        if (n >= 3 && word[3] == verb) last = cmd
        line = substr(line, i + 16)
      }
    }
    END { if (last != "") print last }' "$T/out"
}
# argv_of CMD  Run CMD (a printed command line) with a recording lease.sh
# first on PATH, in the empty $T/canary, and print each argument it got as
# [ARG]. Nothing else runs: the shim only records.
argv_of() {
  mkdir -p "$T/shim" "$T/canary"
  printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' >"$T/shim/lease.sh"
  chmod +x "$T/shim/lease.sh"
  (cd "$T/canary" && PATH="$T/shim:$PATH" "$AO_TEST_SHELL" -c "$1")
}
# shq STRING  STRING as one single-quoted shell word (for expected text).
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# pause_date DIR  Put a `date` first on the fixture PATH that, in a process
# whose PAUSE_DIR is DIR, stops at its first `date -u` (ao_utc, called when
# an audit change is numbered: after the record is read, before it is
# written): it creates DIR/paused and waits for DIR/go. Every other call,
# and every other process, gets the real date at once.
pause_date() {
  _real=$(command -v date)
  mkdir -p "$1"
  cat >"$T/bin/date" <<EOF
#!/bin/sh
if [ -n "\${PAUSE_DIR:-}" ] && [ "\${1-}" = -u ] && [ ! -e "\$PAUSE_DIR/paused" ]; then
  : >"\$PAUSE_DIR/paused"
  n=0
  while [ ! -e "\$PAUSE_DIR/go" ] && [ "\$n" -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done
fi
exec "$_real" "\$@"
EOF
  chmod +x "$T/bin/date"
}
# wait_for FILE  Wait up to 5 s for FILE to exist.
wait_for() {
  _n=0
  while [ ! -e "$1" ] && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
  assert_file "$1"
}
# set_row CLIENT SESSION  Rewrite alpha's registry row (a hand edit).
set_row() {
  awk -F'\t' -v c="$1" -v s="$2" 'BEGIN { OFS = "\t" } $1 == "alpha" { $4 = s; $5 = c } { print }' \
    "$T/home/operators/REGISTRY.tsv" >"$T/reg" && mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
}
# last_note SLUG  Path of the last (glob-sorted) note named *SLUG.md in
# alpha's inbox, or the unmatched pattern when there is none.
last_note() {
  for _f in "$T/home/inbox/alpha"/*"$1".md; do :; done
  printf '%s\n' "$_f"
}
# fake_marks  Mark the four in-app steps. There is no app in the sandbox:
# the evidence is labelled as a fixture, not an app readback.
fake_marks() {
  for _s in labels pins-claude pins-codex models; do
    run switch.sh mark alpha "$_s" --evidence "FAKE fixture readback for $_s (no app in the test sandbox)"
    assert_rc 0
  done
}
# record_audit FROM TO  The incoming session commits a switch-in report for
# the pending registry change and records it with lease.sh audit-done (no
# lease in this home: the registry audit).
record_audit() {
  commit_report "$1" "$2"
  run lease.sh --home "$T/proj/alpha" audit-done --report "audits/switch-in-$_ch.md"
}
# commit_report FROM TO  Only the commit of record_audit; sets _ch.
commit_report() {
  _ch=$(sed -n 's/^change=//p' "$T/state/audit/alpha")
  _at=$(sed -n 's/^since=//p' "$T/state/audit/alpha")
  mkdir -p "$T/proj/alpha/audits"
  printf '# Switch-in audit: alpha, registry change %s at %s (%s -> %s)\n\nFixture report.\n' \
    "$_ch" "$_at" "$1" "$2" >"$T/proj/alpha/audits/switch-in-$_ch.md"
  git -C "$T/proj/alpha" add audits && git -C "$T/proj/alpha" commit -q -m "switch-in audit $_ch"
}
# lease_home  alpha's home with operator.conf and .operator/ git-ignored,
# for the lease tests.
lease_home() {
  home_repo "$T/proj/alpha"
  printf 'key=alpha\n' >"$T/proj/alpha/operator.conf"
  printf '.operator/\n' >"$T/proj/alpha/.gitignore"
  git -C "$T/proj/alpha" add -A && git -C "$T/proj/alpha" commit -q -m conf
}
# lease_acq PROVIDER SID  Acquire alpha's lease as "Alpha Op"; sets TOK, EP.
lease_acq() {
  run lease.sh --home "$T/proj/alpha" acquire --provider "$1" --session "Alpha Op" --session-id "$2"
  TOK=$(sed -n 's/^instance: //p' "$T/out")
  EP=$(sed -n 's/^epoch: //p' "$T/out")
}
# lease_handoff TOKEN EPOCH  The holder writes HANDOFF.md from the lease
# template (the header release checks) and commits it.
lease_handoff() {
  run lease.sh --home "$T/proj/alpha" note --instance "$1" --epoch "$2"
  cp "$T/out" "$T/proj/alpha/HANDOFF.md"
  git -C "$T/proj/alpha" add HANDOFF.md && git -C "$T/proj/alpha" commit -q -m "handoff epoch $2"
}
# lease_audit TOKEN EPOCH  The incoming holder commits a switch-in report
# with the header audit-brief prints and records it with audit-done.
lease_audit() {
  run lease.sh --home "$T/proj/alpha" audit-brief --instance "$1" --epoch "$2"
  mkdir -p "$T/proj/alpha/audits"
  { sed -n 1p "$T/out"; printf '\nFixture report.\n'; } >"$T/proj/alpha/audits/switch-in-epoch-$2.md"
  git -C "$T/proj/alpha" add audits && git -C "$T/proj/alpha" commit -q -m "switch-in audit epoch $2"
  run lease.sh --home "$T/proj/alpha" audit-done --instance "$1" --epoch "$2" --report "audits/switch-in-epoch-$2.md"
}
reg_row() { grep "^alpha$TAB" "$T/home/operators/REGISTRY.tsv"; }
notes_named() {
  _c=0
  for _f in "$T/home/inbox/oracle"/*"$1"*; do [ -f "$_f" ] && _c=$((_c + 1)); done
  echo "$_c"
}
st() { sed -n "s/^$1=//p" "$T/state/switch/alpha" | tail -n 1; }

test_switch_walks_every_step_and_closes_only_when_all_pass() {
  home_repo "$T/proj/alpha"
  printf 'key=alpha\n' >"$T/proj/alpha/operator.conf"
  run switch.sh switch alpha --to codex --session thread-new
  assert_rc 0
  assert_file "$T/state/switch/alpha"
  assert_has "$(ls "$T/home/inbox/alpha"/*switch-out.md)" "write a warm HANDOFF.md"
  # Nothing moves before the handoff.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  handoff"
  assert_has "$T/out" "WAIT  routing"
  assert_has "$T/home/operators/REGISTRY.tsv" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha"
  # The outgoing session commits its handoff: routing follows, with a note.
  sleep 1
  commit_handoff
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  handoff"
  assert_has "$T/out" "PASS  routing      registry updated: codex thread-new"
  assert_has "$T/home/operators/REGISTRY.tsv" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}thread-new${TAB}codex"
  # The move to the other family is recorded at once: the audit is pending.
  assert_has "$T/state/audit/alpha" "from=claude"
  assert_has "$T/state/audit/alpha" "change=1"
  tok=$(st token)
  assert_has "$(ls "$T/home/inbox/alpha"/*switch-in.md)" "switch.sh ack alpha $tok"
  assert_has "$T/out" "TODO  labels"
  assert_has "$T/out" "TODO  pins-claude  unpin the Claude session; move it to \"Inactive Operators\""
  assert_has "$T/out" "TODO  pins-codex   pin the Codex thread"
  assert_has "$T/out" "WAIT  switch-in"
  assert_has "$T/out" "WAIT  ack"
  # In-app steps are marked; a wrong token or the wrong thread is refused.
  run switch.sh mark alpha labels
  assert_rc 2
  for s in labels pins-claude pins-codex models; do run switch.sh mark alpha "$s" --evidence "readback ok"; assert_rc 0; done
  run switch.sh ack alpha wrong
  assert_rc 5
  CODEX_THREAD_ID=thread-other run switch.sh ack alpha "$tok"
  assert_rc 5
  CODEX_THREAD_ID=thread-new run switch.sh ack alpha "$tok"
  assert_rc 0
  assert_has "$T/out" "acknowledged from Codex thread thread-new"
  # The switch-in audit is still pending: not done yet.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  switch-in"
  assert_has "$T/out" "PASS  ack"
  # Recorded audit: every step passes and the switch closes.
  record_audit claude codex
  assert_rc 0
  run switch.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "switch of alpha complete."
  assert_no_file "$T/state/switch/alpha"
  assert_count "$T/state/switch/done" 1
  assert_has "$(ls "$T/home/inbox/oracle"/*switched.md)" "every step passed"
}

test_switch_refusals_cold_handoff_and_same_family() {
  run switch.sh switch oracle --to codex --session t
  assert_rc 5
  run switch.sh switch alpha --to other --session t
  assert_rc 2
  run switch.sh switch alpha --to claude --session sid-alpha
  assert_rc 5
  run switch.sh switch alpha --to claude --session sid-beta
  assert_rc 5
  assert_has "$T/err" "already leads 'beta'"
  run switch.sh switch alpha --to claude --session sid-new
  assert_rc 0
  run switch.sh switch alpha --to claude --session sid-newer
  assert_rc 5
  assert_has "$T/err" "is open since"
  # The outgoing session is gone: a cold handoff needs a reason.
  run switch.sh mark alpha handoff
  assert_rc 2
  run switch.sh mark alpha handoff --cold "session lost in a restart"
  assert_rc 0
  printf 'alpha\t2099-01-01\tbusy\n' >"$T/home/operators/WATCHDOG-QUIET.tsv"
  # An active hold stops delivery: routing does not pass, no switch-in note.
  run switch.sh hold alpha --owner ops --until 2099-01-01 --reason freeze
  run switch.sh verify alpha
  assert_has "$T/out" "TODO  routing      a hold by ops until 2099-01-01 stops delivery to alpha (K-07): switch.sh unhold alpha"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note while held"
  run switch.sh unhold alpha
  run switch.sh verify alpha
  assert_has "$T/out" "PASS  routing      registry: claude sid-new"
  assert_has "$T/out" "PASS  handoff      cold: session lost in a restart"
  assert_has "$T/out" "TODO  watchdog     a quiet-list entry silences alpha"
  assert_has "$T/out" "PASS  pins-codex   no Codex side"
  assert_has "$T/out" "PASS  switch-in    same model family"
  # A note to the Oracle that quotes the token is an ack too.
  tok=$(st token)
  printf 'got it %s\n' "$tok" | sh "$SCRIPTS/inbox-put.sh" oracle ack-note >/dev/null
  rm -f "$T/home/operators/WATCHDOG-QUIET.tsv"
  for s in labels pins-claude models; do run switch.sh mark alpha "$s" --evidence "gap: test"; done
  run switch.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "PASS  ack          token quoted in"
}

# One disposable operator, Claude -> Codex -> Claude, through the documented
# commands only. In-app evidence is a labelled fake. `switch.sh side` is what
# the parked-side guard in each home's AGENTS.md runs; the guard is advisory
# (the old session is told to park, nothing stops its process), so this test
# proves what side reports, not that the old session obeys it.
test_roundtrip_claude_codex_claude() {
  home_repo "$T/proj/alpha"
  printf 'key=alpha\n' >"$T/proj/alpha/operator.conf"
  git -C "$T/proj/alpha" add operator.conf && git -C "$T/proj/alpha" commit -q -m conf
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side before"

  # Leg 1: Claude -> Codex.
  run switch.sh switch alpha --to codex --session thread-a
  assert_rc 0
  assert_eq "$(alpha_notes switch-out)" 1 "one switch-out note"
  # No handoff yet: nothing is routed, no switch-in note, the old side stays active.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  routing      applied once the handoff passes"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note before the handoff"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side before the handoff"
  sleep 1
  commit_handoff "leg 1: claude to codex"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated: codex thread-a"
  tok1=$(st token)
  # Repeated verify: routing stays, and the incoming note is not sent again.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry: codex thread-a"
  assert_eq "$(alpha_notes switch-in)" 1 "one switch-in note after two verifies"
  assert_has "$(ls "$T/home/inbox/alpha"/*switch-in.md)" "switch.sh ack alpha $tok1"
  # The old Claude session looks itself up: the active side is now Codex.
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "codex thread-a Alpha Op" "side after routing"
  # The parked side cannot acknowledge for the incoming one.
  CLAUDECODE=1 run switch.sh ack alpha "$tok1"
  assert_rc 5
  assert_has "$T/err" "the incoming side is codex"
  fake_marks
  CODEX_THREAD_ID=thread-a run switch.sh ack alpha "$tok1"
  assert_rc 0
  # Interrupted here (ack and marks done, audit not): the switch stays open.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  switch-in"
  assert_file "$T/state/switch/alpha"
  assert_eq "$(notes_named switched)" 0 "no switched note while a step is left"
  run switch.sh check
  assert_has "$T/out" "open switch: alpha"
  record_audit claude codex
  assert_rc 0
  run switch.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "PASS  switch-in    audit recorded"
  assert_has "$T/out" "switch of alpha complete."
  assert_eq "$(notes_named switched)" 1 "switched note after leg 1"

  # Leg 2: Codex -> Claude, back to the parked Claude session.
  sleep 1
  run switch.sh switch alpha --to claude --session sid-alpha
  assert_rc 0
  tok2=$(st token)
  [ "$tok2" != "$tok1" ] || _fail "leg 2 reuses the leg 1 token"
  # The leg 1 handoff does not count for leg 2.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  handoff"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "codex thread-a Alpha Op" "side before the leg 2 handoff"
  sleep 1
  commit_handoff "leg 2: codex to claude"
  # Interrupted verify: the switch-in note cannot be written. Routing is
  # applied, the note is not marked sent, and nothing completes.
  chmod 500 "$T/home/inbox/alpha"
  run switch.sh verify alpha
  chmod 700 "$T/home/inbox/alpha"
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated: claude sid-alpha"
  assert_has "$T/out" "WAIT  ack          sent once routing passes"
  assert_eq "$(alpha_notes switch-in)" 1 "only the leg 1 switch-in note"
  # Retry: the note follows once, with this switch's token.
  run switch.sh verify alpha
  assert_rc 1
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(alpha_notes switch-in)" 2 "one switch-in note per leg"
  assert_has "$(last_note switch-in)" "switch.sh ack alpha $tok2"
  assert_lacks "$(last_note switch-in)" "$tok1"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side after leg 2 routing"
  # The leg 1 token and the now parked Codex thread are refused.
  run switch.sh ack alpha "$tok1"
  assert_rc 5
  CODEX_THREAD_ID=thread-a run switch.sh ack alpha "$tok2"
  assert_rc 5
  CLAUDECODE=1 run switch.sh ack alpha "$tok2"
  assert_rc 0
  assert_has "$T/out" "acknowledged from a Claude session"
  fake_marks
  # The leg 1 audit does not pass leg 2.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  switch-in    audit pending"
  # Without a lease, verify recorded the return move itself as the next
  # numbered change (the observation cross-review.sh runs every hour), once
  # despite the interrupted run and the retries; leg 1's completion stays.
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha")" 2 "return move is change 2"
  assert_has "$T/state/audit/alpha" "from=codex"
  assert_has "$T/state/audit/alpha" "to=claude"
  assert_has "$T/state/audit/alpha" "provider=claude"
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha.done")" 1 "leg 1 completion kept"
  record_audit codex claude
  assert_rc 0
  assert_has "$T/out" "switch-in audit recorded (registry, codex -> claude)"
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha.done")" 2 "leg 2 completion"
  run switch.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "switch of alpha complete."
  assert_has "$T/home/operators/REGISTRY.tsv" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha${TAB}claude"
  assert_count "$T/state/switch/done" 2
  assert_eq "$(notes_named switched)" 2 "switched note after leg 2"
  run switch.sh check
  assert_has "$T/out" "ok: alpha on claude (sid-alpha)"
  assert_lacks "$T/out" "open switch"
  # Registry-only routing initialized nothing in the home and left no lock.
  assert_no_file "$T/proj/alpha/.operator"
  assert_no_file "$T/proj/alpha/.operator.init"
}

# With the optional lease held by the outgoing side, verify must not report
# routing it did not apply: the lease overrides the registry row in the
# resolver, so `side` (the parked-side guard) and delivery still follow it.
# Regression: verify used to print "PASS routing registry updated" here
# while side stayed claude and no switch-in note was sent.
test_switch_with_a_held_lease_reports_only_the_route_side_reports() {
  lease_home
  lease_acq claude sid-alpha
  assert_rc 0
  run switch.sh switch alpha --to codex --session thread-a
  assert_rc 0
  assert_has "$T/out" "lease: held by claude (epoch 1)"
  # The switch-out note asks the holder to release the lease itself.
  assert_eq "$(alpha_notes switch-out)" 1 "one switch-out note"
  out_note=$(ls "$T/home/inbox/alpha"/*switch-out.md)
  assert_has "$out_note" "lease.sh --home '$T/proj/alpha' release --instance <your token> --epoch 1"
  assert_has "$out_note" "Nobody releases it for you"
  # The outgoing session commits HANDOFF.md but keeps the lease.
  sleep 1
  commit_handoff
  for _try in 1 2; do
    run switch.sh verify alpha
    assert_rc 1
    assert_has "$T/out" "PASS  handoff"
    assert_has "$T/out" "TODO  routing      the lease is held by claude \`Alpha Op\` (session sid-alpha, epoch 1), not the incoming codex thread-a"
    assert_has "$T/out" "lease.sh --home '$T/proj/alpha' release --instance <its token> --epoch 1"
    assert_has "$T/out" "lease.sh --home '$T/proj/alpha' acquire --provider 'codex' --session 'Alpha Op' --session-id 'thread-a'"
    assert_lacks "$T/out" "PASS  routing"
    assert_has "$T/out" "WAIT  switch-in    checked once routing passes"
    assert_has "$T/out" "WAIT  ack          sent once routing passes"
    # Nothing moved: the registry row, the resolved side, no switch-in note.
    assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged"
    run switch.sh side alpha
    assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side stays with the lease holder"
    assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note while the outgoing side holds the lease"
  done
  # switch.sh did not touch the lease.
  assert_eq "$(lget state "$T/proj/alpha")" held "lease still held"
  assert_eq "$(lget provider "$T/proj/alpha")" claude "lease still claude"
}

# Claude -> Codex -> Claude with the optional lease, through the existing
# release, acquire and audit-done commands. The holder releases, the
# incoming session acquires; switch.sh only reports. In-app evidence is a
# labelled fake.
test_lease_roundtrip_claude_codex_claude() {
  lease_home
  lease_acq claude sid-alpha
  tok1=$TOK
  assert_eq "$EP" 1 "first epoch"

  # Leg 1: Claude -> Codex.
  run switch.sh switch alpha --to codex --session thread-a
  assert_rc 0
  sleep 1
  lease_handoff "$tok1" 1
  # An effect whose process died is unresolved: release refuses.
  run lease.sh --home "$T/proj/alpha" dispatch-run --instance "$tok1" --epoch 1 --what "fixture effect" -- false
  assert_rc 1
  mk=$(sed -n 's/^lease.sh: marker: //p' "$T/err")
  assert_file "$T/proj/alpha/.operator/markers/$mk"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "TODO  routing      1 dispatch marker(s) open"
  assert_has "$T/out" "a human settles it (lease.sh settle)"
  assert_lacks "$T/out" "PASS  routing"
  run lease.sh --home "$T/proj/alpha" release --instance "$tok1" --epoch 1
  assert_rc 5
  assert_has "$T/err" "a dispatch marker is open"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note while release is refused"
  # The human settles it; the holder releases (a retry is idempotent).
  with_tty "settle $mk not-landed" lease.sh --home "$T/proj/alpha" settle --marker "$mk" --outcome not-landed
  assert_eq "$rc" 0 "settle rc"
  run lease.sh --home "$T/proj/alpha" release --instance "$tok1" --epoch 1
  assert_rc 0
  run lease.sh --home "$T/proj/alpha" release --instance "$tok1" --epoch 1
  assert_rc 0
  assert_has "$T/out" "(already)"
  # Released, not yet acquired: still no route and no phantom note.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "TODO  routing      the lease is released (epoch 1 ended): nothing routes until the incoming session acquires it: lease.sh --home '$T/proj/alpha' acquire --provider 'codex' --session 'Alpha Op' --session-id 'thread-a'"
  assert_lacks "$T/out" "PASS  routing"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note while released"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged while released"
  # The incoming session acquires: routing passes, the note follows once.
  lease_acq codex thread-a
  assert_rc 0
  tok2=$TOK
  assert_eq "$EP" 2 "leg 1 epoch"
  assert_has "$T/out" "REQUIRED FIRST STEP: switch-in audit"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated; lease held by codex \`Alpha Op\` (epoch 2): thread-a"
  assert_has "$T/out" "WAIT  switch-in    audit pending"
  assert_has "$T/out" "audit-done --instance <its token> --epoch 2"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      lease held by codex \`Alpha Op\` (epoch 2): thread-a"
  assert_eq "$(alpha_notes switch-in)" 1 "one switch-in note after two verifies"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}thread-a${TAB}codex" "registry follows the lease"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "codex thread-a Alpha Op" "side after leg 1"
  st1=$(st token)
  CODEX_THREAD_ID=thread-a run switch.sh ack alpha "$st1"
  assert_rc 0
  fake_marks
  lease_audit "$tok2" 2
  assert_rc 0
  assert_has "$T/out" "switch-in audit recorded (lease, claude -> codex)"
  run switch.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "PASS  switch-in    audit recorded"
  assert_has "$T/out" "switch of alpha complete."
  # The lease audits its own move: no registry change was recorded too.
  assert_no_file "$T/state/audit/alpha"

  # Leg 2: Codex -> Claude. The leg 1 audit (done) does not pass leg 2.
  sleep 1
  run switch.sh switch alpha --to claude --session sid-alpha
  assert_rc 0
  assert_has "$(last_note switch-out)" "release --instance <your token> --epoch 2"
  sleep 1
  lease_handoff "$tok2" 2
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "TODO  routing      the lease is held by codex \`Alpha Op\` (session thread-a, epoch 2), not the incoming claude sid-alpha"
  assert_has "$T/out" "WAIT  switch-in    checked once routing passes"
  assert_lacks "$T/out" "PASS  switch-in"
  assert_eq "$(alpha_notes switch-in)" 1 "no leg 2 note while codex holds the lease"
  run lease.sh --home "$T/proj/alpha" release --instance "$tok2" --epoch 2
  assert_rc 0
  lease_acq claude sid-alpha
  assert_rc 0
  tok3=$TOK
  assert_eq "$EP" 3 "leg 2 epoch"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated; lease held by claude \`Alpha Op\` (epoch 3): sid-alpha"
  assert_has "$T/out" "WAIT  switch-in    audit pending"
  run switch.sh verify alpha
  assert_eq "$(alpha_notes switch-in)" 2 "one switch-in note per leg"
  st2=$(st token)
  assert_has "$(last_note switch-in)" "switch.sh ack alpha $st2"
  CLAUDECODE=1 run switch.sh ack alpha "$st2"
  assert_rc 0
  fake_marks
  lease_audit "$tok3" 3
  assert_rc 0
  assert_has "$T/out" "switch-in audit recorded (lease, codex -> claude)"
  run switch.sh verify alpha
  assert_rc 0
  assert_has "$T/out" "switch of alpha complete."
  assert_count "$T/state/switch/done" 2
  assert_eq "$(notes_named switched)" 2 "switched note per leg"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha${TAB}claude" "registry after leg 2"
  run switch.sh check
  assert_has "$T/out" "ok: alpha on claude (sid-alpha)"
  assert_lacks "$T/out" "open switch"
  assert_no_file "$T/state/audit/alpha"
}

# A lease that names no holder routes nothing: an unreadable lease, or one
# a takeover assigned to the incoming session that has not acquired it.
# Either used to pass routing on the registry write alone.
test_switch_with_an_invalid_or_assigned_lease_does_not_route() {
  lease_home
  lease_acq claude sid-alpha
  run switch.sh switch alpha --to codex --session thread-a
  assert_rc 0
  sleep 1
  commit_handoff
  # Invalid (fixture: an unreadable lease, set aside and put back).
  _l=$T/proj/alpha/.operator/lease
  cp "$_l" "$T/lease.keep"
  printf 'not a lease\n' >"$_l"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "TODO  routing      the lease $T/proj/alpha/.operator/lease cannot be trusted"
  assert_lacks "$T/out" "PASS  routing"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged (invalid)"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note (invalid)"
  cp "$T/lease.keep" "$_l"
  # Assigned by a human takeover to the incoming session, not acquired yet.
  with_tty "takeover alpha 1" lease.sh --home "$T/proj/alpha" takeover --expect-epoch 1 --holder-stopped --provider codex --session Alpha-codex --session-id thread-a
  assert_eq "$rc" 0 "takeover rc"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "TODO  routing      a takeover assigned the lease to codex \`Alpha-codex\` (epoch 2), which has not acquired it"
  # The command shown carries the assigned session id: the assigned name
  # differs from the registry's, so without it nothing would name thread-a.
  assert_has "$T/out" "nothing routes until that session runs lease.sh --home '$T/proj/alpha' acquire --provider 'codex' --session 'Alpha-codex' --session-id 'thread-a'; if it is not the incoming codex thread-a"
  assert_lacks "$T/out" "PASS  routing"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged (assigned)"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note (assigned)"
  # That session runs the command exactly as shown: now it routes.
  acq_cmd=$(shown_cmd acquire)
  assert_eq "$acq_cmd" "lease.sh --home '$T/proj/alpha' acquire --provider 'codex' --session 'Alpha-codex' --session-id 'thread-a'" "displayed acquire"
  eval "run $acq_cmd"
  assert_rc 0
  assert_eq "$(lget session_id "$T/proj/alpha")" thread-a "the lease names the assigned session"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated; lease held by codex \`Alpha-codex\` (epoch 2): thread-a"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}thread-a${TAB}codex" "registry follows the lease"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "codex thread-a Alpha-codex" "side after the displayed acquire"
  assert_eq "$(alpha_notes switch-in)" 1 "switch-in note once acquired"
}

# A lease acquired without --session-id names no session; the resolver then
# takes the registry's session for a row of the same client and name. A
# switch to another session of the same client must not rewrite that row:
# the rewrite alone would make the lease resolve to the incoming session
# while whoever acquired it (here the outgoing one) still holds it.
test_held_lease_without_a_session_id_is_not_rebound_by_a_registry_write() {
  lease_home
  run lease.sh --home "$T/proj/alpha" acquire --provider claude --session "Alpha Op"
  assert_rc 0
  tok1=$(sed -n 's/^instance: //p' "$T/out")
  assert_eq "$(lget session_id "$T/proj/alpha")" - "no session id in the lease"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side falls back to the registry's session"
  run switch.sh switch alpha --to claude --session sid-new
  assert_rc 0
  assert_has "$T/out" "lease: held by claude (epoch 1)"
  sleep 1
  commit_handoff
  for _try in 1 2; do
    run switch.sh verify alpha
    assert_rc 1
    assert_has "$T/out" "PASS  handoff"
    assert_has "$T/out" "TODO  routing      the lease is held by claude \`Alpha Op\` (epoch 1) without a session id, so it is not known to be the incoming claude sid-new, and verify never binds it to a session by a registry write"
    assert_has "$T/out" "(lease.sh --home '$T/proj/alpha' acquire --provider 'claude' --session 'Alpha Op' --session-id 'sid-new')"
    assert_lacks "$T/out" "PASS  routing"
    assert_has "$T/out" "WAIT  ack          sent once routing passes"
    assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged"
    run switch.sh side alpha
    assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side unchanged"
    assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note"
  done
  # switch.sh did not touch the lease.
  assert_eq "$(lget state "$T/proj/alpha")" held "lease still held"
  assert_eq "$(lget epoch "$T/proj/alpha")" 1 "same epoch"
  assert_eq "$(lget session_id "$T/proj/alpha")" - "lease still names no session"
  # The holder releases it after its warm note; the incoming session runs
  # the acquire exactly as verify showed it: now routing passes.
  lease_handoff "$tok1" 1
  run lease.sh --home "$T/proj/alpha" release --instance "$tok1" --epoch 1
  assert_rc 0
  run switch.sh verify alpha
  assert_rc 1
  acq_cmd=$(shown_cmd acquire)
  assert_eq "$acq_cmd" "lease.sh --home '$T/proj/alpha' acquire --provider 'claude' --session 'Alpha Op' --session-id 'sid-new'" "displayed acquire"
  eval "run $acq_cmd"
  assert_rc 0
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated; lease held by claude \`Alpha Op\` (epoch 2): sid-new"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-new${TAB}claude" "registry follows the lease"
  assert_eq "$(alpha_notes switch-in)" 1 "one switch-in note"
}

# switch.sh verify (registry lock) and cross-review.sh (its own lock) both
# update alpha's audit record; the record lock serializes them. Fixture:
# cross-review.sh is stopped inside its update, after reading the record
# and before writing it (a fake date on PATH), while verify routes the
# return move.
test_audit_record_updates_by_verify_and_cross_review_are_serialized() {
  home_repo "$T/proj/alpha"
  profile_set cross_review off
  # Cross-review last saw claude; the row has since moved to codex (a hand
  # edit), not yet observed.
  mkdir -p "$T/state/audit"
  printf 'provider=claude\nfrom=\nto=\nchange=\nsince=\n' >"$T/state/audit/alpha"
  set_row codex thread-a
  run switch.sh switch alpha --to claude --session sid-alpha
  assert_rc 0
  sleep 1
  commit_handoff
  pause_date "$T/pause"
  # cross-review.sh numbers the move to codex and stops before writing it.
  PAUSE_DIR=$T/pause "$AO_TEST_SHELL" "$SCRIPTS/cross-review.sh" </dev/null >"$T/cr.out" 2>"$T/cr.err" &
  cr_pid=$!
  wait_for "$T/pause/paused"
  # verify routes the return move meanwhile; it waits for the record.
  "$AO_TEST_SHELL" "$SCRIPTS/switch.sh" verify alpha </dev/null >"$T/v.out" 2>"$T/v.err" &
  v_pid=$!
  _n=0
  while kill -0 "$v_pid" 2>/dev/null && [ "$_n" -lt 20 ]; do sleep 0.1; _n=$((_n + 1)); done
  kill -0 "$v_pid" 2>/dev/null || _fail "verify did not wait while cross-review.sh was updating the record"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}thread-a${TAB}codex" "no routing write before the record is read"
  : >"$T/pause/go"
  wait "$cr_pid"
  cr_rc=$?
  wait "$v_pid"
  v_rc=$?
  assert_eq "$cr_rc" 0 "cross-review rc ($(cat "$T/cr.err"))"
  assert_eq "$v_rc" 1 "verify rc ($(cat "$T/v.err"))"
  assert_has "$T/v.out" "PASS  routing      registry updated: claude sid-alpha"
  # Both moves are numbered, in order; the delayed write did not roll the
  # return move back.
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha")" 2 "return move is change 2"
  assert_has "$T/state/audit/alpha" "from=codex"
  assert_has "$T/state/audit/alpha" "to=claude"
  assert_has "$T/state/audit/alpha" "provider=claude"
  # A writer that resolved the row before it got the record resolves it
  # again under the lock (fixture: the kit's lock, held from outside, and a
  # hand edit of the row while cross-review.sh waits for it).
  rm -f "$T/state/audit/oracle"
  hold_lock audit-alpha
  "$AO_TEST_SHELL" "$SCRIPTS/cross-review.sh" </dev/null >"$T/cr.out" 2>"$T/cr.err" &
  cr_pid=$!
  wait_for "$T/state/audit/oracle"
  sleep 1
  set_row codex thread-a
  release_lock
  wait "$cr_pid"
  assert_eq "$?" 0 "cross-review rc ($(cat "$T/cr.err"))"
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha")" 3 "the row as it is now: change 3"
  assert_has "$T/state/audit/alpha" "from=claude"
  assert_has "$T/state/audit/alpha" "to=codex"
  assert_has "$T/state/audit/alpha" "provider=codex"
}

# lease.sh audit-done records a registry audit under the same record lock,
# and only while the change it checked is still the pending one. Fixture:
# audit-done is stopped after its checks (a fake date on PATH) while the
# operator moves back and cross-review.sh numbers that move.
test_registry_audit_completion_holds_the_record_lock() {
  home_repo "$T/proj/alpha"
  printf 'key=alpha\n' >"$T/proj/alpha/operator.conf"
  profile_set cross_review off
  run cross-review.sh
  assert_rc 0
  set_row codex thread-a
  run cross-review.sh
  assert_rc 0
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha")" 1 "move to codex is change 1"
  commit_report claude codex
  pause_date "$T/pause"
  PAUSE_DIR=$T/pause "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/proj/alpha" audit-done --report audits/switch-in-1.md \
    </dev/null >"$T/ad.out" 2>"$T/ad.err" &
  ad_pid=$!
  wait_for "$T/pause/paused"
  set_row claude sid-alpha
  run cross-review.sh
  assert_rc 0
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha")" 2 "move back is change 2"
  : >"$T/pause/go"
  wait "$ad_pid"
  assert_eq "$?" 5 "audit-done rc ($(cat "$T/ad.err"))"
  assert_has "$T/ad.err" "the registry switch-in audit changed while audit-done ran"
  assert_no_file "$T/state/audit/alpha.done"
  assert_eq "$(audit_state)" pending "change 2 still pending"
  # Change 2's own report is recorded, after waiting for a writer that
  # holds the record (fixture: the kit's lock, held from outside).
  commit_report codex claude
  hold_lock audit-alpha
  "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/proj/alpha" audit-done --report audits/switch-in-2.md \
    </dev/null >"$T/ad.out" 2>"$T/ad.err" &
  ad_pid=$!
  sleep 1
  kill -0 "$ad_pid" 2>/dev/null || _fail "audit-done did not wait for the record lock"
  assert_no_file "$T/state/audit/alpha.done"
  release_lock
  wait "$ad_pid"
  assert_eq "$?" 0 "audit-done rc ($(cat "$T/ad.err"))"
  assert_has "$T/ad.out" "switch-in audit recorded (registry, codex -> claude)"
  assert_eq "$(sed -n 's/^change=//p' "$T/state/audit/alpha.done")" 2 "change 2 recorded"
  assert_eq "$(audit_state)" "done" "audit done"
}

# A verify that dies after placing the switch-in note, before recording it,
# must not place a second one on a retry, wherever the relay has taken the
# first: claimed (in flight) or archived. The clock is pinned, so a second
# note would take a collision name (*-switch-in-2.md).
test_switch_in_note_is_placed_once_across_an_interruption_after_publication() {
  home_repo "$T/proj/alpha"
  AO_NOW=$(date +%s)
  export AO_NOW
  run switch.sh switch alpha --to claude --session sid-new
  assert_rc 0
  tok=$(st token)
  # A note that quotes the token, even under a switch-in name, is not it.
  printf 'Reminder: run switch.sh ack alpha %s\n' "$tok" >"$T/home/inbox/alpha/00000000T000000-switch-in.md"
  sleep 1
  commit_handoff
  # Interrupted after publication (fixture: the switch record's folder is
  # read-only, so recording note_sent fails).
  chmod 500 "$T/state/switch"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated: claude sid-new"
  assert_has "$T/err" "cannot write $T/state/switch/alpha"
  assert_eq "$(switch_in_copies)" 1 "placed once"
  assert_eq "$(st note_sent)" "" "not recorded"
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(switch_in_copies)" 1 "no second note on a retry"
  assert_eq "$(alpha_notes switch-in)" 2 "the decoy and the one note, no collision name"
  # In flight: a relay claimed it and stopped (fixture: a claim folder).
  mkdir -p "$T/home/inbox/alpha/.claimed/c.fixture"
  for _f in "$T/home/inbox/alpha"/*-switch-in.md; do
    grep -q 'you are now the active side' "$_f" && mv "$_f" "$T/home/inbox/alpha/.claimed/c.fixture/"
  done
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(switch_in_copies)" 1 "no second note while it is in flight"
  # The relay archives and delivers it.
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_eq "$(claude_calls)" 1 "one delivery"
  assert_eq "$(switch_in_copies)" 1 "archived, not copied"
  for sent_note in "$T/home/inbox/sent"/*-alpha-*-switch-in.md; do :; done
  assert_has "$sent_note" "switch.sh ack alpha $tok"
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(switch_in_copies)" 1 "no second note once archived"
  # The record is writable again: the note is recorded, not placed again.
  chmod 700 "$T/state/switch"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "WAIT  ack          the incoming session has not acknowledged the switch-in note"
  [ -n "$(st note_sent)" ] || _fail "note_sent not recorded"
  assert_eq "$(switch_in_copies)" 1 "still one switch-in note"
  FAKE_MODE=sent run relay.sh
  assert_eq "$(claude_calls)" 1 "still one delivery"
  assert_no_file "$T/home/inbox/alpha/.claimed"
}

# run_with NAME=VALUE SCRIPT ARG...  As run, with NAME set for this run only.
run_with() {
  _e=$1 _s=$2
  shift 2
  env "$_e" "$AO_TEST_SHELL" "$SCRIPTS/$_s" "$@" </dev/null >"$T/out" 2>"$T/err"
  rc=$?
}
# real_copies inbox|claimed|sent  alpha's switch-in notes (by their text) in
# one place.
real_copies() {
  case $1 in
    inbox) set -- "$T/home/inbox/alpha"/*.md ;;
    claimed) set -- "$T/home/inbox/alpha/.claimed"/*.md "$T/home/inbox/alpha/.claimed"/*/*.md ;;
    sent) set -- "$T/home/inbox/sent"/*.md ;;
  esac
  _c=0
  for _f in "$@"; do [ -f "$_f" ] && grep -q 'you are now the active side for alpha' "$_f" && _c=$((_c + 1)); done
  echo "$_c"
}
# relay_steps  Put a `cmp` first on the fixture PATH that, when verify is
# about to compare alpha's switch-in note (its folder already listed), first
# moves it on as the relay does. RELAY_STEPS, in verify's environment, names
# the steps: claim (inbox to a fresh .claimed/c.* folder, by rename),
# archive (claimed to the sent folder: link, then unlink) or link (the link
# only: a relay stopped between the two). Then it compares, really.
relay_steps() {
  _real=$(command -v cmp)
  cat >"$T/bin/cmp" <<EOF
#!/bin/sh
for f in "\$@"; do :; done
in="$T/home/inbox/alpha" sent="$T/home/inbox/sent"
if [ -n "\${RELAY_STEPS:-}" ] && grep -q 'you are now the active side for alpha' "\$f" 2>/dev/null; then
  case \${f#"\$in/"} in
    */*) ;;
    *) case " \$RELAY_STEPS " in *" claim "*)
      mkdir -p "\$in/.claimed" && d=\$(mktemp -d "\$in/.claimed/c.XXXXXX") && mv "\$f" "\$d/" ;;
    esac ;;
  esac
  case \$f in "\$in/.claimed/c."*/*)
    mkdir -p "\$sent"
    case " \$RELAY_STEPS " in
      *" archive "*) ln "\$f" "\$sent/20990101T000000-alpha-\${f##*/}" && rm -f "\$f" && rmdir "\${f%/*}" ;;
      *" link "*) ln "\$f" "\$sent/20990101T000000-alpha-\${f##*/}" 2>/dev/null ;;
    esac ;;
  esac
fi
exec "$_real" "\$@"
EOF
  chmod +x "$T/bin/cmp"
}
# placed_switch_in  Open a switch of alpha (pinned clock), beside a decoy
# that quotes the token under a switch-in name, and run a verify that places
# the switch-in note but cannot record it (the switch record's folder is
# read-only), so every later verify looks the note up again. Sets tok.
placed_switch_in() {
  home_repo "$T/proj/alpha"
  AO_NOW=$(date +%s)
  export AO_NOW
  run switch.sh switch alpha --to claude --session sid-new
  assert_rc 0
  tok=$(st token)
  printf 'Reminder: run switch.sh ack alpha %s\n' "$tok" >"$T/home/inbox/alpha/00000000T000000-switch-in.md"
  sleep 1
  commit_handoff
  chmod 500 "$T/state/switch"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/err" "cannot write $T/state/switch/alpha"
  assert_eq "$(real_copies inbox)" 1 "placed once"
  relay_steps
}
# decoy_kept  The decoy is still there once, byte for byte, wherever the
# relay took it.
decoy_kept() {
  _c=0
  for _f in "$T/home/inbox/alpha"/*.md "$T/home/inbox/alpha/.claimed"/*/*.md "$T/home/inbox/sent"/*.md; do
    [ -f "$_f" ] && [ "$(cat "$_f")" = "Reminder: run switch.sh ack alpha $tok" ] && _c=$((_c + 1))
  done
  assert_eq "$_c" 1 "the decoy, once and unchanged"
}

# The relay moves the note between verify's listing of a folder and its
# comparison: each folder is listed only after the one before was compared,
# so the note is found where it went, never placed again.
test_switch_in_lookup_follows_the_note_the_relay_moves_mid_lookup() {
  placed_switch_in
  run_with RELAY_STEPS=claim switch.sh verify alpha
  assert_rc 1
  assert_eq "$(real_copies inbox)" 0 "not placed again (claimed during the lookup)"
  assert_eq "$(real_copies claimed)" 1 "claimed"
  # The relay cannot publish the archive copy (the sent folder is
  # read-only): the claimed copy stays, and is found.
  mkdir -p "$T/home/inbox/sent"
  chmod 500 "$T/home/inbox/sent"
  FAKE_MODE=sent run relay.sh
  chmod 700 "$T/home/inbox/sent"
  assert_rc 1
  assert_eq "$(claude_calls)" 0 "nothing delivered"
  assert_eq "$(real_copies claimed)" 1 "left claimed"
  assert_eq "$(real_copies sent)" 0 "not archived"
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(real_copies inbox)" 0 "not placed again (left claimed)"
  run_with RELAY_STEPS=archive switch.sh verify alpha
  assert_rc 1
  assert_eq "$(real_copies inbox)" 0 "not placed again (archived during the lookup)"
  assert_eq "$(real_copies claimed)" 0 "no claimed copy left"
  assert_eq "$(real_copies sent)" 1 "archived"
  decoy_kept
  # The record is writable again: recorded, not placed.
  chmod 700 "$T/state/switch"
  run switch.sh verify alpha
  assert_rc 1
  [ -n "$(st note_sent)" ] || _fail "note_sent not recorded"
  assert_eq "$(real_copies inbox)" 0 "still not placed again"
}

test_switch_in_lookup_follows_one_note_through_claim_and_archive() {
  placed_switch_in
  run_with RELAY_STEPS='claim archive' switch.sh verify alpha
  assert_rc 1
  assert_eq "$(real_copies inbox)" 0 "not placed again"
  assert_eq "$(real_copies claimed)" 0 "moved on"
  assert_eq "$(real_copies sent)" 1 "found archived"
  decoy_kept
  chmod 700 "$T/state/switch"
}

# A relay stopped between the archive link and the claimed copy's removal
# leaves the note in both places; its next run archives it again (the relay
# is at least once). Verify places none of those copies again.
test_switch_in_lookup_across_a_relay_stopped_between_link_and_unlink() {
  placed_switch_in
  run_with RELAY_STEPS='claim link' switch.sh verify alpha
  assert_rc 1
  assert_eq "$(real_copies inbox)" 0 "not placed again"
  assert_eq "$(real_copies claimed)" 1 "still claimed"
  assert_eq "$(real_copies sent)" 1 "and linked into the archive"
  FAKE_MODE=sent run relay.sh
  assert_rc 0
  assert_eq "$(claude_calls)" 1 "one delivery"
  assert_eq "$(real_copies claimed)" 0 "claimed copy archived"
  assert_eq "$(real_copies sent)" 2 "archived twice by the relay"
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(real_copies inbox)" 0 "not placed again (archived)"
  decoy_kept
  chmod 700 "$T/state/switch"
  run switch.sh verify alpha
  assert_rc 1
  [ -n "$(st note_sent)" ] || _fail "note_sent not recorded"
  assert_eq "$(real_copies inbox)" 0 "recorded, not placed"
}

# pause_mv  Put an `mv` first on the fixture PATH that, in a process whose
# PAUSE_DIR is set, stops before its first move onto a file named PAUSE_ON
# (verify's registry write or acquire's lease write: each after its
# decision, inside its locks): it creates PAUSE_DIR/paused and waits for
# PAUSE_DIR/go. Every other move, and every other process, runs at once.
pause_mv() {
  _real=$(command -v mv)
  cat >"$T/bin/mv" <<EOF
#!/bin/sh
for last in "\$@"; do :; done
if [ -n "\${PAUSE_DIR:-}" ] && [ "\${last##*/}" = "\${PAUSE_ON:-}" ] && [ ! -e "\$PAUSE_DIR/paused" ]; then
  : >"\$PAUSE_DIR/paused"
  n=0
  while [ ! -e "\$PAUSE_DIR/go" ] && [ "\$n" -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done
fi
exec "$_real" "\$@"
EOF
  chmod +x "$T/bin/mv"
}
# mark_waits  Put a `sleep` first on the fixture PATH that, in a process
# whose WAIT_MARK is set, creates that file first. The lock loops sleep only
# after finding a lock taken: the file proves that the process waited.
mark_waits() {
  _real=$(command -v sleep)
  cat >"$T/bin/sleep" <<EOF
#!/bin/sh
[ -z "\${WAIT_MARK:-}" ] || : >"\$WAIT_MARK"
exec "$_real" "\$@"
EOF
  chmod +x "$T/bin/sleep"
}
# race_home [init]  alpha's home without a lease (with init: lease.sh init
# made .operator/) and an open same-client switch, claude sid-alpha ->
# claude sid-new, whose handoff is committed: the next verify writes the
# route.
race_home() {
  lease_home
  if [ -n "${1-}" ]; then
    run lease.sh --home "$T/proj/alpha" init
    assert_rc 0
  fi
  run switch.sh switch alpha --to claude --session sid-new
  assert_rc 0
  sleep 1
  commit_handoff
  pause_mv
  mark_waits
  mkdir -p "$T/pause"
}
# race_acquire_first [init]  A first acquire with no profile and no session
# id (by the operator's name only) is admitted first and stopped before its
# lease write. verify waits for the home mutex, then finds the lease, and
# never binds it to the incoming session by its registry write.
race_acquire_first() {
  race_home "${1-}"
  PAUSE_DIR=$T/pause PAUSE_ON=lease AO_PROFILE=$T/no-profile "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/proj/alpha" \
    acquire --provider claude --session "Alpha Op" </dev/null >"$T/a.out" 2>"$T/a.err" &
  a_pid=$!
  wait_for "$T/pause/paused"
  assert_eq "$(cat "$T/proj/alpha/.operator.init/pid" 2>/dev/null)" "$a_pid" "acquire holds the home mutex"
  assert_no_file "$T/proj/alpha/.operator/lease"
  WAIT_MARK=$T/v.waited "$AO_TEST_SHELL" "$SCRIPTS/switch.sh" verify alpha </dev/null >"$T/v.out" 2>"$T/v.err" &
  v_pid=$!
  wait_for "$T/v.waited"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "no routing write while acquire holds the home"
  : >"$T/pause/go"
  wait "$a_pid"
  assert_eq "$?" 0 "acquire rc ($(cat "$T/a.err"))"
  wait "$v_pid"
  assert_eq "$?" 1 "verify rc ($(cat "$T/v.err"))"
  assert_eq "$(lget session_id "$T/proj/alpha")" - "the lease names no session"
  assert_has "$T/v.out" "TODO  routing      the lease is held by claude \`Alpha Op\` (epoch 1) without a session id"
  assert_lacks "$T/v.out" "PASS  routing"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side stays with the registry's session"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note"
  assert_no_file "$T/proj/alpha/.operator.init"
}
# race_verify_first [init]  verify is admitted first and stopped before its
# registry write, holding the home mutex (and the lease lock when
# .operator/ exists). The outgoing session's first acquire, by its exact
# session id and with no profile, waits before it creates anything; its
# lease, written after, keeps that session.
race_verify_first() {
  race_home "${1-}"
  PAUSE_DIR=$T/pause PAUSE_ON=REGISTRY.tsv "$AO_TEST_SHELL" "$SCRIPTS/switch.sh" verify alpha </dev/null >"$T/v.out" 2>"$T/v.err" &
  v_pid=$!
  wait_for "$T/pause/paused"
  assert_eq "$(cat "$T/proj/alpha/.operator.init/pid" 2>/dev/null)" "$v_pid" "verify holds the home mutex"
  if [ -n "${1-}" ]; then
    assert_eq "$(cat "$T/proj/alpha/.operator/lease.lock/pid" 2>/dev/null)" "$v_pid" "verify holds the lease lock"
  else
    assert_no_file "$T/proj/alpha/.operator"
  fi
  WAIT_MARK=$T/a.waited AO_PROFILE=$T/no-profile "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/proj/alpha" \
    acquire --provider claude --session "Alpha Op" --session-id sid-alpha </dev/null >"$T/a.out" 2>"$T/a.err" &
  a_pid=$!
  wait_for "$T/a.waited"
  assert_no_file "$T/proj/alpha/.operator/lease"
  [ -n "${1-}" ] || assert_no_file "$T/proj/alpha/.operator"
  : >"$T/pause/go"
  wait "$v_pid"
  assert_eq "$?" 1 "verify rc ($(cat "$T/v.err"))"
  wait "$a_pid"
  assert_eq "$?" 0 "acquire rc ($(cat "$T/a.err"))"
  assert_has "$T/v.out" "PASS  routing      registry updated: claude sid-new"
  assert_eq "$(lget session_id "$T/proj/alpha")" sid-alpha "the lease keeps its exact session"
  run switch.sh side alpha
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side follows the lease"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "TODO  routing      the lease is held by claude \`Alpha Op\` (session sid-alpha, epoch 1), not the incoming claude sid-new"
  assert_no_file "$T/proj/alpha/.operator.init"
}
test_first_acquire_admitted_before_verify_without_operator_dir() { race_acquire_first; }
test_first_acquire_admitted_before_verify_with_operator_dir() { race_acquire_first init; }
test_verify_admitted_before_first_acquire_without_operator_dir() { race_verify_first; }
test_verify_admitted_before_first_acquire_with_operator_dir() { race_verify_first init; }

# A home mutex that stays (here: left by a crashed process a minute ago) is
# never broken: acquire, init and verify fail closed and keep it.
test_a_home_mutex_left_by_a_crash_fails_closed_and_is_kept() {
  lease_home
  run switch.sh switch alpha --to claude --session sid-new
  assert_rc 0
  sleep 1
  commit_handoff
  _m=$T/proj/alpha/.operator.init
  mkdir "$_m" && echo 999999 >"$_m/pid"
  touch -t "$(date -r $(($(date +%s) - 60)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(($(date +%s) - 60)) +%Y%m%d%H%M.%S)" "$_m"
  run_with AO_PROFILE="$T/no-profile" lease.sh --home "$T/proj/alpha" acquire --provider claude --session "Alpha Op" --session-id sid-new
  assert_rc 3
  assert_has "$T/err" "home mutex $_m is older than"
  assert_no_file "$T/proj/alpha/.operator"
  run lease.sh --home "$T/proj/alpha" init
  assert_rc 3
  assert_no_file "$T/proj/alpha/.operator"
  run switch.sh verify alpha
  assert_rc 3
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged"
  assert_eq "$(cat "$_m/pid")" 999999 "the mutex is kept"
  # A human removes it: verify routes, and initializes nothing.
  rm -r "$_m"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated: claude sid-new"
  assert_no_file "$T/proj/alpha/.operator"
  assert_no_file "$_m"
}

# Every command verify prints for the lease runs as shown: each value is one
# word, whatever quotes, spaces or shell syntax a home or name holds. Run
# against a recording lease.sh, then the real one.
test_printed_lease_commands_run_as_shown() {
  mkdir -p "$T/canary"
  cd "$T/canary" || return
  H="$T/proj/crew's desk; \$(touch pwned) alpha"
  mkdir -p "$H"
  home_repo "$H"
  printf 'key=alpha\n' >"$H/operator.conf"
  printf '.operator/\n' >"$H/.gitignore"
  git -C "$H" add -A && git -C "$H" commit -q -m conf
  awk -F'\t' -v d="$H" 'BEGIN { OFS = "\t" } $1 == "alpha" { $3 = d } { print }' \
    "$T/home/operators/REGISTRY.tsv" >"$T/reg" && mv "$T/reg" "$T/home/operators/REGISTRY.tsv"
  run lease.sh --home "$H" acquire --provider claude --session "Alpha Op" --session-id sid-alpha
  assert_rc 0
  tok1=$(sed -n 's/^instance: //p' "$T/out")
  run switch.sh switch alpha --to codex --session thread-a --name "Builder's Desk"
  assert_rc 0
  assert_has "$(ls "$T/home/inbox/alpha"/*switch-out.md)" "lease.sh --home $(shq "$H") release --instance <your token> --epoch 1"
  sleep 1
  printf 'handoff\n' >"$H/HANDOFF.md"
  git -C "$H" add HANDOFF.md && git -C "$H" commit -q -m handoff
  want=$(printf '[%s]\n' --home "$H" acquire --provider codex --session "Builder's Desk" --session-id thread-a)
  # Held by the outgoing session.
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "release --instance <its token> --epoch 1"
  assert_eq "$(argv_of "$(shown_cmd acquire)")" "$want" "held: acquire argv"
  # Released.
  run lease.sh --home "$H" note --instance "$tok1" --epoch 1
  cp "$T/out" "$H/HANDOFF.md"
  git -C "$H" add HANDOFF.md && git -C "$H" commit -q -m "handoff epoch 1"
  run lease.sh --home "$H" release --instance "$tok1" --epoch 1
  assert_rc 0
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "the lease is released (epoch 1 ended)"
  acq=$(shown_cmd acquire)
  assert_eq "$(argv_of "$acq")" "$want" "released: acquire argv"
  # Assigned by a takeover that recorded no session id (fixture: the lease
  # as takeover writes it): the id is asked for in words, not shown as a
  # value to run.
  cp "$H/.operator/lease" "$T/lease.released"
  sed -e 's/^state=.*/state=assigned/' -e 's/^instance=.*/instance=-/' -e 's/^provider=.*/provider=codex/' \
    -e "s/^session=.*/session=Builder's Desk/" -e 's/^session_id=.*/session_id=-/' "$T/lease.released" >"$H/.operator/lease"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "--session $(shq "Builder's Desk"), adding --session-id with its own session id (the takeover recorded none)"
  assert_eq "$(argv_of "$(shown_cmd acquire)")" "$(printf '[%s]\n' --home "$H" acquire --provider codex --session "Builder's Desk")" "assigned without an id: acquire argv"
  assert_eq "$(argv_of "$(shown_cmd status)")" "$(printf '[%s]\n' --home "$H" status)" "status argv"
  sed 's/^session_id=.*/session_id=thread-a/' "$H/.operator/lease" >"$T/lease.assigned" && cp "$T/lease.assigned" "$H/.operator/lease"
  run switch.sh verify alpha
  assert_rc 1
  assert_eq "$(argv_of "$(shown_cmd acquire)")" "$want" "assigned: acquire argv"
  # The incoming session runs the released state's acquire as shown, with
  # the real lease.sh: routing passes, to that exact session.
  cp "$T/lease.released" "$H/.operator/lease"
  eval "run $acq"
  assert_rc 0
  assert_eq "$(lget session "$H")" "Builder's Desk" "lease session name"
  assert_eq "$(lget session_id "$H")" thread-a "lease session id"
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated; lease held by codex \`Builder's Desk\` (epoch 2): thread-a"
  assert_eq "$(reg_row)" "alpha${TAB}Builder's Desk${TAB}$H${TAB}thread-a${TAB}codex" "registry row"
  # Nothing in a home or name ran as shell syntax.
  assert_eq "$(ls -A "$T/canary")" "" "canary folder stays empty"
}

test_side_check_holds_and_the_oracle_lock() {
  run switch.sh side alpha
  assert_rc 0
  assert_eq "$(cat "$T/out")" "claude sid-alpha Alpha Op" "side"
  run switch.sh check
  assert_rc 1
  assert_has "$T/out" "ok: alpha on claude (sid-alpha)"
  assert_has "$T/out" "no Oracle lock"
  run switch.sh oracle-lock take claude --session sid-oracle
  assert_rc 0
  assert_has "$T/home/operators/ORACLE-LOCK" "holder=claude"
  run switch.sh check
  assert_rc 0
  assert_has "$T/out" "oracle: claude (sid-oracle)"
  # A hold names its owner, expiry and reason, and stops the relay for the operator.
  run switch.sh hold alpha --until 2099-01-01 --reason x
  assert_rc 2
  run switch.sh hold alpha --owner ops --until 2099-01-01
  assert_rc 2
  run switch.sh hold alpha --owner ops --until 2000-01-01 --reason x
  assert_rc 2
  run switch.sh hold alpha --owner ops --until 2099-01-01 --reason "deploy freeze"
  assert_rc 0
  run switch.sh check
  assert_has "$T/out" "hold: alpha by ops until 2099-01-01 (deploy freeze)"
  note alpha a.md x
  FAKE_MODE=sent run relay.sh
  assert_no_file "$FAKE_LOG"
  assert_count "$T/home/inbox/alpha" 1
  # Expired: not obeyed, and reported.
  printf 'owner=ops\nuntil=2000-01-01\nreason=x\n' >"$T/state/holds/alpha"
  FAKE_MODE=sent run relay.sh
  assert_has "$FAKE_LOG" 'to "Alpha Op"'
  run switch.sh check
  assert_rc 1
  assert_has "$T/out" "hold not honoured"
  run hygiene.sh
  assert_rc 1
  assert_has "$T/out" "holds: alpha is expired or lacks an owner, expiry or reason"
  run switch.sh unhold alpha
  assert_rc 0
  assert_no_file "$T/state/holds/alpha"
}

test_mailroom_pause_is_a_hold_with_an_owner() {
  profile_set relay_bridge on
  run switch.sh hold mailroom --owner ops --until 2099-01-01 --reason maintenance
  assert_rc 0
  run mailroom.sh supervise
  assert_rc 0
  assert_has "$T/err" "paused by"
  printf 'until=2099-01-01\n' >"$T/state/mailroom-pause"
  run mailroom.sh supervise
  assert_lacks "$T/err" "paused by"
}

test_hygiene_diffs_grants_against_permission_rules() {
  home_repo "$T/proj/alpha"
  mkdir -p "$T/proj/alpha/.claude"
  cat >"$T/proj/alpha/MANDATE.md" <<'EOF'
# Mandate: Alpha

## Standing grants

| Date | Grant, in the human's words | Scope | Expires |
| --- | --- | --- | --- |
| 2026-11-01 | "run the tests" | `Bash(make test:*)` | - |
| 2026-11-01 | "deploy staging" | `Bash(make deploy:*)` | - |
| 2020-01-01 | "old" | none | 2020-02-01 |

## Reports to
EOF
  printf '{"permissions":{"allow":["Bash(make test:*)","Bash(rm:*)"]}}\n' >"$T/proj/alpha/.claude/settings.local.json"
  git -C "$T/proj/alpha" add -A && git -C "$T/proj/alpha" commit -q -m mandate
  run hygiene.sh
  assert_rc 1
  assert_has "$T/out" 'permission rule `Bash(rm:*)` has no standing grant'
  assert_has "$T/out" 'standing grant `Bash(make deploy:*)` is not in the Claude permission rules'
  assert_lacks "$T/out" 'Bash(make test:*)'
  assert_has "$T/out" "a standing grant is past its expiry"
  printf 'dirty\n' >"$T/proj/alpha/scratch.txt"
  run hygiene.sh --note
  assert_has "$T/out" "uncommitted or untracked path(s)"
  assert_eq "$(notes_named hygiene)" 1 "one note"
}

test_lane_sh_is_a_deprecated_alias_of_switch_sh() {
  run lane.sh check
  rc_alias=$rc
  assert_has "$T/err" "lane.sh is deprecated"
  run switch.sh check
  assert_eq "$rc_alias" "$rc" "same exit code as switch.sh"
}

ao_test_main "$0"
