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
# alpha_notes SLUG  Number of notes named *SLUG.md in alpha's inbox.
alpha_notes() {
  _c=0
  for _f in "$T/home/inbox/alpha"/*"$1".md; do [ -f "$_f" ] && _c=$((_c + 1)); done
  echo "$_c"
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
  _ch=$(sed -n 's/^change=//p' "$T/state/audit/alpha")
  _at=$(sed -n 's/^since=//p' "$T/state/audit/alpha")
  mkdir -p "$T/proj/alpha/audits"
  printf '# Switch-in audit: alpha, registry change %s at %s (%s -> %s)\n\nFixture report.\n' \
    "$_ch" "$_at" "$1" "$2" >"$T/proj/alpha/audits/switch-in-$_ch.md"
  git -C "$T/proj/alpha" add audits && git -C "$T/proj/alpha" commit -q -m "switch-in audit $_ch"
  run lease.sh --home "$T/proj/alpha" audit-done --report "audits/switch-in-$_ch.md"
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
  assert_has "$out_note" "lease.sh --home $T/proj/alpha release --instance <your token> --epoch 1"
  assert_has "$out_note" "Nobody releases it for you"
  # The outgoing session commits HANDOFF.md but keeps the lease.
  sleep 1
  commit_handoff
  for _try in 1 2; do
    run switch.sh verify alpha
    assert_rc 1
    assert_has "$T/out" "PASS  handoff"
    assert_has "$T/out" "TODO  routing      the lease is held by claude \`Alpha Op\` (session sid-alpha, epoch 1), not the incoming codex thread-a"
    assert_has "$T/out" "lease.sh --home $T/proj/alpha release --instance <its token> --epoch 1"
    assert_has "$T/out" "lease.sh --home $T/proj/alpha acquire --provider codex --session 'Alpha Op' --session-id thread-a"
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
  assert_has "$T/out" "TODO  routing      the lease is released (epoch 1 ended): nothing routes until the incoming session acquires it: lease.sh --home $T/proj/alpha acquire --provider codex --session 'Alpha Op' --session-id thread-a"
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
  assert_lacks "$T/out" "PASS  routing"
  assert_eq "$(reg_row)" "alpha${TAB}Alpha Op${TAB}$T/proj/alpha${TAB}sid-alpha" "registry row unchanged (assigned)"
  assert_eq "$(alpha_notes switch-in)" 0 "no switch-in note (assigned)"
  # That session acquires: now it routes.
  run lease.sh --home "$T/proj/alpha" acquire --provider codex --session Alpha-codex --session-id thread-a
  assert_rc 0
  run switch.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "PASS  routing      registry updated; lease held by codex \`Alpha-codex\` (epoch 2): thread-a"
  assert_eq "$(alpha_notes switch-in)" 1 "switch-in note once acquired"
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
