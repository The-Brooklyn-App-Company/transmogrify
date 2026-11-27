#!/bin/sh
# switch.sh - switch an operator between clients as a scripted checklist, and
# keep one active side per operator and one active Oracle.
#
# Usage: switch.sh switch KEY --to claude|codex --session ID [--name NAME]
#        switch.sh verify KEY
#        switch.sh mark KEY STEP [--evidence TEXT | --cold REASON]
#        switch.sh ack KEY TOKEN
#        switch.sh side KEY
#        switch.sh check
#        switch.sh hold KEY|mailroom --owner WHO --until DATE --reason TEXT
#        switch.sh unhold KEY|mailroom
#        switch.sh oracle-lock [show | take CLIENT --session ID]
#
# A switch is a fixed list of steps that `verify` checks in order, so none
# can be missed (K-36). Steps the script can do or check itself it does;
# steps only a person or the app's own tools can do (titles, pins, models)
# are marked done with `mark` after they are done. The switch counts as done
# only when every step passes; `verify` then closes it.
#   handoff     the outgoing session wrote and committed a warm HANDOFF.md in
#               the home since the switch began (`switch` asks it to by an
#               inbox note); `mark KEY handoff --cold REASON` when the
#               outgoing session is gone
#   routing     the resolver (the registry row, overridden by an optional
#               lease) delivers to the incoming client and session, with no
#               active hold. verify writes the row once handoff passes; a
#               lease must be released by its holder and acquired by the
#               incoming session with its session id (lease.sh --session-id;
#               switch.sh never moves it, and never binds a lease that names
#               no session id by a registry write). Only then the incoming
#               session gets a switch-in note with a one-time token, once
#               (a retry after an interruption finds the note it placed)
#   watchdog    no quiet-list entry silences the operator, and no timed job
#               in JOBS.tsv still names the old session
#   labels      (mark) the incoming session is titled with the operator's
#               name; the outgoing one is retitled or archived
#   pins-claude (mark) Claude sidebar: an active operator is pinned; an
#               inactive one sits in the "Inactive Operators" section
#   pins-codex  (mark) Codex sidebar: the active side's threads are pinned,
#               the parked side's are not
#   models      (mark) the incoming session was created with the model and
#               effort recorded for its client in operator.conf
#               (model.<client>, effort.<client>; operator.sh create)
#   Marks of these four carry --evidence: the app's own readback (a sidebar
#   listing, the session's model as the app shows it), or `gap: ...` when
#   the app gives none (docs/operations/client-capabilities.md). A receipt or an ACK
#   proves receipt, not that the app is set up.
#   switch-in   a move to the other model family has its switch-in audit
#               recorded (lease.sh audit-done, K-22), checked once routing
#               passes; same family: passes. Without a lease, verify records
#               the move itself as the next numbered registry change, as
#               cross-review.sh's hourly observation would; a lease records
#               its own at acquire
#   ack         the incoming session proved it received the switch-in note:
#               it ran `switch.sh ack KEY TOKEN` (from Codex the thread id must
#               match), or a note to the Oracle quotes the token
# pins-* pass by themselves when neither side of the switch is that client.
# See docs/operations/conventions.md.
#
# side       Print `<client> <session> <name>` for KEY: the parked-side
#            guard in each home's AGENTS.md runs it first.
# check      Every operator has exactly one active side (client and
#            session); open switches, holds and the Oracle lock. Exit 1 on a
#            finding.
# hold       A hold names its owner, expiry and reason (K-07): <state_dir>/holds/KEY
#            stops the relay, the watchdog and doorbells for KEY until DATE
#            (YYYY-MM-DD inclusive, or YYYY-MM-DDTHH:MM); `mailroom` pauses
#            the mailroom supervisor instead. An expired hold is ignored and
#            reported by hygiene.sh.
# oracle-lock  <oracle_home>/operators/ORACLE-LOCK names the one active
#            Oracle (holder=client, session=, since=). `take` only on the
#            human's word (K-01).
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 done (verify: every step passes); 1 steps remain or a
# finding; 2 usage or configuration error; 3 busy; 5 refused.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

SW_MARKS='handoff labels pins-claude pins-codex models'
E_REFUSED=5

refuse() {
  ao_msg "refused: $*"
  exit "$E_REFUSED"
}

# sw_shq STRING  Print STRING as one single-quoted shell word, for the
# commands verify prints (install.sh's inst_shq).
sw_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# sw_row KEY  Set R_NAME, R_DIR, R_SID, R_CLIENT, R_AUDIT, and R_LEASE,
# R_PROVIDER, R_EPOCH (lease epoch number, or -) from the resolver: the
# registry row, overridden by a lease in the home; fails when KEY has no row.
# R_LSID is the session id the lease itself names (held or assigned), or -:
# a lease without one resolves to the registry's session when the row names
# the same client and session name, which is not evidence of who holds it.
_sw_row_cb() {
  [ "$OP_KEY" = "$_sw_want" ] || return 0
  R_FOUND=1 R_NAME=$OP_NAME R_DIR=$OP_DIR R_SID=$OP_SID R_CLIENT=$OP_CLIENT R_AUDIT=${OP_AUDIT:--}
  R_LEASE=$OP_LEASE R_PROVIDER=$OP_PROVIDER R_EPOCH=${OP_EPOCH##*-} R_LSID=-
  # The resolver read this row's lease into L_* just now (held or assigned
  # means it was read and valid).
  # shellcheck disable=SC2154 # L_session_id is set by ao_lease_read (lib/lease.sh)
  case $OP_LEASE in held | assigned) R_LSID=${L_session_id:--} ;; esac
}
sw_row() {
  _sw_want=$1 R_FOUND='' R_NAME='' R_DIR='' R_SID='' R_CLIENT='' R_AUDIT=- R_LEASE=none R_PROVIDER='' R_EPOCH=- R_LSID=-
  ao_registry_each _sw_row_cb
  [ -n "$R_FOUND" ]
}

# sw_observe KEY  Record KEY's family against its switch-in audit record
# with the mechanism cross-review.sh runs every hour (ao_audit_observe): a
# first sighting sets the baseline, a move to the other family numbers the
# next change. Called under the registry lock, before and after the routing
# write. A record that cannot be trusted is kept for a human (the switch-in
# step reports it); any other failure stops the switch before routing.
_sw_observe_cb() {
  [ "$OP_KEY" = "$_sw_want" ] || return 0
  ao_audit_observe || _sw_obs=1
}
sw_observe() {
  _sw_want=$1 _sw_obs=0
  ao_registry_each _sw_observe_cb
  [ "$_sw_obs" -ne 0 ] || return 0
  ao_audit_read "$1"
  [ $? -ne 2 ] || return 0
  ao_die "$AO_E_FAIL" "cannot record the switch-in audit state of $1 in $(ao_audit_file "$1")"
}

# sw_markers  Print the number of open dispatch markers in R_DIR's lease
# home (unresolved effects block lease.sh release).
sw_markers() {
  _n=0
  for _m in "$R_DIR/.operator/markers"/*; do [ -f "$_m" ] && _n=$((_n + 1)); done
  echo "$_n"
}

# sw_custody  Under the registry lock, take R_DIR's home mutex (outside the
# optional .operator/, lib/lease.sh ao_home_mutex), then its lease lock when
# .operator/ exists: no lease is created, acquired, released or taken over
# until sw_custody_end, so the route verify resolves is the one it writes.
# Creates nothing else in the home (a home without .operator/ keeps none).
# Busy, or left by a crash: fails closed (exit 3), and only this process's
# own locks are ever removed.
sw_custody() {
  [ -d "$R_DIR" ] || return 0
  _hd=$(CDPATH='' cd -- "$R_DIR" && pwd -P) || ao_die "$AO_E_FAIL" "cannot read $R_DIR"
  ao_home_mutex "$_hd" || ao_die "$AO_E_BUSY" "the operator home $_hd is being initialized or acquired by another command; try again"
  [ -d "$_hd/.operator" ] || return 0
  H_OP=$_hd/.operator H_KEY=$_key
  ao_lease_lock || ao_die "$AO_E_BUSY" "the lease lock of $_hd is busy or stuck; try again"
}
sw_custody_end() {
  ao_lease_unlock
  ao_home_unmutex
}

# sw_routed  True when the resolver delivers KEY to the incoming client
# and session (_tc, _ts): no lease or one held by that session, and no
# active hold. Sets _how (what routes it) or _why (what is left, with the
# next commands). A registry write never moves a lease: only its holder's
# release and the incoming session's acquire do.
sw_routed() {
  _how='' _why=''
  # Every value in a printed command is one quoted word: it runs as shown.
  _qh=$(sw_shq "$R_DIR")
  _acq="lease.sh --home $_qh acquire --provider $(sw_shq "$_tc") --session $(sw_shq "$_nm") --session-id $(sw_shq "$_ts")"
  _lst="lease.sh --home $_qh status"
  case $R_LEASE in
    released)
      _why="the lease is released (epoch $R_EPOCH ended): nothing routes until the incoming session acquires it: $_acq"
      return 1 ;;
    assigned)
      # The acquire must carry the assigned session id: without it the
      # lease names no session and routing cannot reach the exact one. An
      # id the takeover did not record is asked for in words, never shown
      # as a value to run.
      _aacq="lease.sh --home $_qh acquire --provider $(sw_shq "$R_PROVIDER") --session $(sw_shq "$R_NAME")"
      if [ "$R_LSID" != - ]; then _aacq="$_aacq --session-id $(sw_shq "$R_LSID")"
      else _aacq="$_aacq, adding --session-id with its own session id (the takeover recorded none)"; fi
      _why="a takeover assigned the lease to $R_PROVIDER \`$R_NAME\` (epoch $R_EPOCH), which has not acquired it: nothing routes until that session runs $_aacq; if it is not the incoming $_tc $_ts, a human settles which session runs $_key ($_lst)"
      return 1 ;;
    invalid)
      _why="the lease $R_DIR/.operator/lease cannot be trusted (unreadable, or another operator or host): nothing routes until a human inspects it ($_lst)"
      return 1 ;;
  esac
  if [ "$R_LEASE" = held ] && { [ "$R_PROVIDER" != "$_tc" ] || [ "$R_SID" != "$_ts" ]; }; then
    if [ "$R_LSID" = - ]; then
      # Acquired without --session-id: the holder may be the outgoing
      # session or the incoming one; nothing here tells which.
      _why="the lease is held by $R_PROVIDER \`$R_NAME\` (epoch $R_EPOCH) without a session id, so it is not known to be the incoming $_tc $_ts, and verify never binds it to a session by a registry write"
    else
      _why="the lease is held by $R_PROVIDER \`$R_NAME\` (session $R_LSID, epoch $R_EPOCH), not the incoming $_tc $_ts"
    fi
    _why="$_why: the holder releases it itself after its warm HANDOFF.md (lease.sh --home $_qh release --instance <its token> --epoch $R_EPOCH; the switch-out note asks it), then the incoming session acquires it with its id ($_acq). switch.sh never releases, acquires or overrides a lease"
    _mk=$(sw_markers)
    [ "$_mk" -eq 0 ] || _why="$_mk dispatch marker(s) open in $R_DIR/.operator/markers (an effect in flight or unresolved): release refuses until it ends or a human settles it (lease.sh settle); then $_why"
    return 1
  fi
  if [ "$R_CLIENT" != "$_tc" ] || [ "$R_SID" != "$_ts" ]; then
    _why="the registry names $R_CLIENT ${R_SID:--}, not $_tc $_ts"
    return 1
  fi
  if ao_hold_active "$AO_STATE/holds/$_key"; then
    _why="a hold by $AO_H_OWNER until $AO_H_UNTIL stops delivery to $_key (K-07): switch.sh unhold $_key, or let it expire"
    return 1
  fi
  if [ "$R_LEASE" = held ]; then _how="lease held by $_tc \`$R_NAME\` (epoch $R_EPOCH): $_ts"
  else _how="registry: $_tc $_ts"; fi
}

sw_key() {
  ao_is_name "${1-}" || ao_die "$AO_E_USAGE" "invalid key '${1-}'"
  ! ao_is_bridge_key "$1" || refuse "$1 is a mailroom bridge, not an operator"
  [ "$1" != "$AO_ORACLE_KEY" ] || refuse "the Oracle moves with switch.sh oracle-lock, not switch"
  sw_row "$1" || ao_die "$AO_E_USAGE" "no registry row for '$1'"
}

sw_state() { printf '%s/switch/%s\n' "$AO_STATE" "$1"; }

# st_get FILE KEY / st_set FILE KEY VALUE  key=value state, last line wins.
st_get() { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1; }
st_set() {
  { [ ! -r "$1" ] || grep -v "^$2=" "$1"; printf '%s=%s\n' "$2" "$3"; } | ao_write_atomic "$1" ||
    ao_die "$AO_E_FAIL" "cannot write $1"
}

# sw_grants_gate KEY CLIENT  0 when there is no grants file, or when the
# grants that apply on CLIENT are rendered and resolved (grants.sh check
# --gate). Sets _gate to the one-line reason.
sw_grants_gate() {
  _gf=$(ao_cfg_path grants_file operators/GRANTS.md)
  if [ ! -f "$_gf" ]; then _gate="no grants file"; return 0; fi
  _grc=0
  _gate=$(sh "$AO_SCRIPTS/grants.sh" check --gate "$1" "$2" 2>&1) || _grc=$?
  _gate=$(printf '%s\n' "$_gate" | tail -n 1)
  [ "$_grc" -eq 0 ]
}

sw_family() { case $1 in claude | codex) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- switch

sw_switch() {
  _key=${1-}
  shift || true
  _to='' _sid='' _name=''
  while [ $# -gt 0 ]; do
    case $1 in
      --to) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--to needs claude or codex"; _to=$2; shift ;;
      --session) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--session needs an id"; _sid=$2; shift ;;
      --name) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--name needs a value"; _name=$2; shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
    esac
    shift
  done
  sw_key "$_key"
  sw_family "$_to" || ao_die "$AO_E_USAGE" "--to must be claude or codex"
  ao_is_name "$_sid" && [ "$_sid" != pending ] && [ "$_sid" != - ] || ao_die "$AO_E_USAGE" "--session needs the incoming session or thread id"
  case $_name in *"$AO_TAB"* | *"$AO_NL"*) ao_die "$AO_E_USAGE" "--name must be one line without tabs" ;; esac
  [ "$_to" != "$R_CLIENT" ] || [ "$_sid" != "$R_SID" ] || refuse "$_key already runs on $_to in session $_sid"
  sw_grants_gate "$_key" "$_to" ||
    refuse "the standing grants on $_to do not match the grants file ($_gate); render them (grants.sh render-$_to), then switch"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  _other=$(awk -F'\t' -v k="$_key" -v s="$_sid" '$1 !~ /^#/ && $1 != k && $4 == s { print $1; exit }' "$AO_REGISTRY")
  [ -z "$_other" ] || refuse "session $_sid already leads '$_other': one session per operator"
  _st=$(sw_state "$_key")
  [ ! -f "$_st" ] || refuse "a switch of $_key is open since $(ao_utc "$(st_get "$_st" started)"); finish it with switch.sh verify $_key, or remove $_st"
  _tok=$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')
  {
    printf 'from_client=%s\nfrom_sid=%s\nto_client=%s\nto_sid=%s\nname=%s\n' "$R_CLIENT" "$R_SID" "$_to" "$_sid" "${_name:-$R_NAME}"
    printf 'started=%s\ntoken=%s\n' "$AO_T_EPOCH" "$_tok"
  } | ao_write_atomic "$_st" || ao_die "$AO_E_FAIL" "cannot write $_st"
  # shellcheck disable=SC2016 # backticks are Markdown in the note
  {
    printf 'Operator switch (the Oracle, by switch.sh; automated, not from the human): %s moves from %s to %s.\nBefore anything else: write a warm HANDOFF.md in your home (in flight, next steps, open asks; `lease.sh note` prints a template), commit it, and take no new work for this operator. The incoming session takes over from your HANDOFF.md.\n' \
      "$R_NAME" "$R_CLIENT" "$_to"
    # A held lease moves only by its holder's release and the incoming
    # session's acquire: ask for the release here.
    [ "$R_LEASE" != held ] ||
      printf 'This operator has a lease, held by %s `%s` (epoch %s). Once HANDOFF.md is written (it must start with the `epoch: %s ... kind: warm` line `lease.sh note` prints), release the lease yourself: `lease.sh --home %s release --instance <your token> --epoch %s`. Release refuses while a dispatch marker is open: let it finish, or the human settles it. Nobody releases it for you; the incoming session acquires it after you.\n' \
        "$R_PROVIDER" "$R_NAME" "$R_EPOCH" "$R_EPOCH" "$(sw_shq "$R_DIR")" "$R_EPOCH"
  } | ao_inbox_put "$_key" switch-out >/dev/null
  echo "switch opened for $_key: $R_CLIENT -> $_to ($_sid); the outgoing session was asked for a warm handoff."
  case $R_LEASE in
    none) ;;
    held) echo "lease: held by $R_PROVIDER (epoch $R_EPOCH); the outgoing session was asked to release it. Routing passes only once the incoming session holds it." ;;
    *) echo "lease: $R_LEASE; routing passes only once the incoming session holds it (switch.sh verify says what is left)." ;;
  esac
  echo "Next: switch.sh verify $_key (repeat until every step passes)."
}

# ---------------------------------------------------------------- verify

# sw_registry_set KEY CLIENT SESSION NAME  Rewrite one registry row.
sw_registry_set() {
  _tmp=$(ao_tmp registry)
  awk -F'\t' -v OFS='\t' -v k="$1" -v c="$2" -v s="$3" -v n="$4" '
    $1 == k { $4 = s; $5 = c; if (n != "") $2 = n }
    { print }' "$AO_REGISTRY" >"$_tmp" && ao_write_atomic "$AO_REGISTRY" <"$_tmp"
}

# sw_say STATE STEP TEXT
sw_say() { printf '%-5s %-12s %s\n' "$1" "$2" "$3"; [ "$1" = PASS ] || _left=$((_left + 1)); }

sw_marked() { [ -n "$(st_get "$_st" "done_$1")" ]; }

sw_verify() {
  sw_key "${1-}"
  _key=$1
  _st=$(sw_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open switch for $_key (switch.sh switch first)"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  _fc=$(st_get "$_st" from_client) _fs=$(st_get "$_st" from_sid)
  _tc=$(st_get "$_st" to_client) _ts=$(st_get "$_st" to_sid)
  _nm=$(st_get "$_st" name) _since=$(st_get "$_st" started) _tok=$(st_get "$_st" token)
  ao_is_uint "${_since:-x}" || ao_die "$AO_E_FAIL" "unreadable switch record $_st"
  _left=0
  printf 'Switch of %s: %s (%s) -> %s (%s), opened %s UTC\n' "$_key" "$_fc" "$_fs" "$_tc" "$_ts" "$(ao_utc "$_since")"
  # handoff
  _hc=$(git -C "$R_DIR" log --since="@$_since" --format=%ct -1 -- HANDOFF.md 2>/dev/null)
  if [ -n "$_hc" ]; then sw_say PASS handoff "HANDOFF.md committed $(ao_utc "$_hc") UTC"
  elif sw_marked handoff; then sw_say PASS handoff "$(st_get "$_st" done_handoff | cut -d ' ' -f 2-)"
  else sw_say WAIT handoff "the outgoing session has not committed HANDOFF.md in $R_DIR yet (gone? switch.sh mark $_key handoff --cold REASON)"; fi
  # approvals: the grants must follow the operator before it is routed
  if sw_grants_gate "$_key" "$_tc"; then sw_say PASS approvals "$_gate"
  else sw_say TODO approvals "$_gate (grants.sh render-$_tc, then verify again)"; fi
  # routing: PASS only when the resolver (registry row, overridden by a
  # lease) delivers to the incoming client and session. Resolved again
  # under the home's custody, held through the write and the observations.
  sw_custody
  sw_row "$_key" || ao_die "$AO_E_FAIL" "the registry row of $_key is gone"
  _routed='' _wrote='' _dup='' _xfam=''
  if sw_family "$_fc" && sw_family "$_tc" && [ "$_fc" != "$_tc" ]; then _xfam=1; fi
  ! sw_routed || _routed=1
  # The row is written once the handoff and approvals pass, when there is
  # no lease or the resolver already names the incoming session as the
  # holder; the write alone moves no lease. Under a lease that names no
  # session id the resolver takes the registry's session for a row of the
  # same client and name, so a write would bind the lease to the incoming
  # session whoever holds it: the holder must already resolve to it.
  if [ "$_left" -eq 0 ] &&
    { [ "$R_LEASE" = none ] || { [ "$R_LEASE" = held ] && [ "$R_PROVIDER" = "$_tc" ] && [ "$R_SID" = "$_ts" ]; }; } &&
    ! awk -F'\t' -v k="$_key" -v c="$_tc" -v s="$_ts" '$1 == k && $4 == s && $5 == c { f = 1 } END { exit !f }' "$AO_REGISTRY"; then
    _dup=$(awk -F'\t' -v k="$_key" -v s="$_ts" '$1 !~ /^#/ && $1 != k && $4 == s { print $1; exit }' "$AO_REGISTRY")
    if [ -z "$_dup" ]; then
      # Without a lease, observe the family before the write too, so the
      # outgoing family is the baseline and the move is numbered as a
      # change (K-22) instead of the new client becoming the baseline.
      [ "$R_LEASE" != none ] || [ -z "$_xfam" ] || sw_observe "$_key"
      sw_registry_set "$_key" "$_tc" "$_ts" "$_nm" || ao_die "$AO_E_FAIL" "cannot update $AO_REGISTRY"
      sw_row "$_key"
      _wrote=1 _routed=''
      ! sw_routed || _routed=1
    fi
  fi
  if [ -n "$_dup" ]; then
    _routed=''
    sw_say TODO routing "session $_ts now leads '$_dup': one session per operator; fix the registry or switch to another session"
  elif [ -n "$_routed" ]; then
    if [ -z "$_wrote" ]; then sw_say PASS routing "$_how"
    elif [ "$R_LEASE" = none ]; then sw_say PASS routing "registry updated: $_tc $_ts"
    else sw_say PASS routing "registry updated; $_how"; fi
  elif [ "$_left" -gt 0 ]; then
    if [ "$R_LEASE" = none ]; then sw_say WAIT routing "applied once the handoff passes"
    else sw_say WAIT routing "applied once the handoff passes; then: $_why"; fi
  else
    sw_say TODO routing "$_why"
  fi
  # A registry move to the other family is recorded at once (and again on a
  # retry after an interruption; a no-op once seen). A lease records its own
  # move at acquire, so it is not recorded twice.
  if [ -n "$_routed" ] && [ "$R_LEASE" = none ] && [ -n "$_xfam" ]; then
    sw_observe "$_key"
    sw_row "$_key"
  fi
  sw_custody_end
  # A run that died after placing the note but before recording it finds
  # it (in the inbox, claimed by the relay, or archived) and only records it.
  if [ -n "$_routed" ] && [ -z "$(st_get "$_st" note_sent)" ]; then
    if sw_note_placed || sw_note | ao_inbox_put "$_key" switch-in >/dev/null; then
      st_set "$_st" note_sent "$AO_T_EPOCH"
    fi
  fi
  # watchdog
  _q=$(ao_quiet_until "$_key" "$R_NAME")
  _j=$AO_HOME/JOBS.tsv
  if [ -n "$_q" ]; then sw_say TODO watchdog "a quiet-list entry silences $_key until $_q: remove it from $AO_QUIET"
  elif [ -n "$_fs" ] && [ "$_fs" != "$_ts" ] && [ -r "$_j" ] && grep -qF -- "$_fs" "$_j"; then sw_say TODO watchdog "$_j still names the old session $_fs"
  else sw_say PASS watchdog "the stall watch follows the registry; no quiet entry, no job on the old session"; fi
  # in-app steps
  for _m in labels pins-claude pins-codex models; do
    if sw_marked "$_m"; then sw_say PASS "$_m" "$(st_get "$_st" "done_$_m" | cut -d ' ' -f 2-)"; continue; fi
    case $_m in
      labels) _do="title the $_tc session \"$_nm\"; retitle or archive the $_fc one" ;;
      pins-claude)
        if [ "$_tc" != claude ] && [ "$_fc" != claude ]; then sw_say PASS "$_m" "no Claude side"; continue; fi
        if [ "$_tc" = claude ]; then _do="pin the Claude session; take it out of \"Inactive Operators\""
        else _do="unpin the Claude session; move it to \"Inactive Operators\""; fi ;;
      pins-codex)
        if [ "$_tc" != codex ] && [ "$_fc" != codex ]; then sw_say PASS "$_m" "no Codex side"; continue; fi
        if [ "$_tc" = codex ]; then _do="pin the Codex thread"; else _do="unpin the Codex thread"; fi ;;
      models)
        _om=$(sed -n "s/^model\.$_tc=//p" "$R_DIR/operator.conf" 2>/dev/null | tail -n 1)
        _oe=$(sed -n "s/^effort\.$_tc=//p" "$R_DIR/operator.conf" 2>/dev/null | tail -n 1)
        if [ -n "$_om" ]; then _do="create the $_tc session with model $_om${_oe:+ and effort $_oe} (operator.conf), set at creation, never by a message"
        else _do="decide the $_tc model with the owner (operator.sh model $_key --client $_tc ...), then create the session with it"; fi ;;
    esac
    sw_say TODO "$_m" "$_do, then: switch.sh mark $_key $_m --evidence '<the app's readback, or gap: ...>'"
  done
  # switch-in
  # Checked only once routing passes: before that, a recorded audit belongs
  # to an earlier move, not this one.
  if [ "$_fc" = "$_tc" ] || ! sw_family "$_fc"; then sw_say PASS switch-in "same model family: no audit"
  elif [ -z "$_routed" ]; then sw_say WAIT switch-in "checked once routing passes (the audit must be of this move)"
  elif [ "$R_AUDIT" = "done" ]; then sw_say PASS switch-in "audit recorded"
  elif [ "$R_AUDIT" = invalid ]; then sw_say TODO switch-in "the audit record cannot be trusted: a human inspects $(ao_audit_file "$_key") (lease.sh --home $(sw_shq "$R_DIR") status)"
  elif [ "$R_LEASE" = held ]; then sw_say WAIT switch-in "audit $R_AUDIT: the incoming session triages and commits the report (lease.sh audit-brief), then runs lease.sh --home $(sw_shq "$R_DIR") audit-done --instance <its token> --epoch $R_EPOCH --report PATH"
  else sw_say WAIT switch-in "audit $R_AUDIT: the incoming session triages and commits the report (lease.sh --home $(sw_shq "$R_DIR") audit-brief), then runs lease.sh --home $(sw_shq "$R_DIR") audit-done --report PATH"; fi
  # ack
  _ack=$(st_get "$_st" ack)
  if [ -n "$_ack" ]; then sw_say PASS ack "$(printf '%s' "$_ack" | cut -d ' ' -f 2-)"
  elif _r=$(sw_reply "$_since" "$_tok"); then sw_say PASS ack "token quoted in ${_r##*/}"
  elif [ -n "$(st_get "$_st" note_sent)" ]; then sw_say WAIT ack "the incoming session has not acknowledged the switch-in note"
  else sw_say WAIT ack "sent once routing passes"; fi
  if [ "$_left" -gt 0 ]; then
    printf '%s step(s) left.\n' "$_left"
    exit "$AO_E_FAIL"
  fi
  mkdir -p "$AO_STATE/switch/done" && mv -f "$_st" "$AO_STATE/switch/done/$_key.$AO_T_STAMP"
  ao_inbox_put "$AO_ORACLE_KEY" switched >/dev/null <<EOF || true
Operator switch done (switch.sh verify, every step passed): $_key now runs on $_tc ($_ts). Record: $AO_STATE/switch/done/$_key.$AO_T_STAMP
EOF
  echo "switch of $_key complete."
}

# sw_note  Print this switch's switch-in note (_key, _tc, _tok): the same
# bytes on every run of the switch, which is what identifies it.
sw_note() {
  # shellcheck disable=SC2016 # backticks are Markdown in the note
  printf 'Operator switch (the Oracle, by switch.sh; automated, not from the human): you are now the active side for %s (%s). Read HANDOFF.md first, then MANDATE.md and NOTES.md. Prove you received this: run `sh %s/switch.sh ack %s %s` from your session (or reply to the Oracle quoting %s). Triage the switch-in audit when it arrives (K-22).\n' \
    "$_key" "$_tc" "$AO_SCRIPTS" "$_key" "$_tok" "$_tok"
}

# sw_note_placed  True when this switch's switch-in note was already placed:
# a file named as ao_inbox_put names it (<stamp>-switch-in.md, or
# <stamp>-switch-in-N.md beside a taken name) that is, byte for byte, the
# note, wherever the relay may have moved it: still in the inbox, claimed in
# its .claimed/ folder (in flight), or archived in the sent folder as
# <stamp>-<key>-<that name>.md. A note that merely quotes the token is not it.
# The relay only moves a note forward (inbox, claimed, sent; it links the
# archive copy before it drops the claimed one), so each folder is listed
# only after the one before it was compared: a note that moved on after its
# folder was listed is in a folder listed later. It is found as long as a
# copy stays in one of them (the archive is not pruned before the retry).
sw_note_placed() {
  _want=$(ao_tmp switch-in-note)
  sw_note >"$_want" || return 1
  _sw_note_in "$AO_INBOX/$_key"/*.md ||
    _sw_note_in "$AO_INBOX/$_key/.claimed"/*.md ||
    _sw_note_in "$AO_INBOX/$_key/.claimed"/c.*/*.md ||
    _sw_note_in "$AO_SENT"/*-"$_key"-*.md
}

# _sw_note_in FILE...  True when one of FILE... is this switch's note
# (_want), by name and bytes.
_sw_note_in() {
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    _n=${_f##*/}
    _n=${_n%.md}
    case ${_n##*-} in '' | *[!0-9]*) ;; *) _n=${_n%-*} ;; esac
    case $_n in *-switch-in) ;; *) continue ;; esac
    cmp -s "$_want" "$_f" && return 0
  done
  return 1
}

# sw_reply SINCE TOKEN  Print a note to the Oracle placed since SINCE that
# quotes TOKEN (inbox or the relay's archive).
sw_reply() {
  for _f in "$AO_INBOX/$AO_ORACLE_KEY"/*.md "$AO_SENT"/*-"$AO_ORACLE_KEY"-*.md; do
    [ -f "$_f" ] || continue
    [ "$(ao_mtime "$_f")" -ge "$1" ] || continue
    grep -qF -- "$2" "$_f" && { printf '%s\n' "$_f"; return 0; }
  done
  return 1
}

sw_mark() {
  sw_key "${1-}"
  _key=$1 _step=${2-}
  shift 2 2>/dev/null || ao_die "$AO_E_USAGE" "usage: switch.sh mark KEY STEP [--evidence TEXT | --cold REASON]"
  case " $SW_MARKS " in *" $_step "*) ;; *) ao_die "$AO_E_USAGE" "STEP must be one of: $SW_MARKS" ;; esac
  if [ "$_step" = handoff ]; then
    if [ "${1-}" != --cold ] || [ -z "${2-}" ]; then ao_die "$AO_E_USAGE" "handoff is checked from git; mark it only as: switch.sh mark KEY handoff --cold REASON"; fi
    _note="cold: $2"
  else
    if [ "${1-}" != --evidence ] || [ -z "${2-}" ]; then ao_die "$AO_E_USAGE" "$_step needs --evidence: the app's own readback, or 'gap: <why there is none>'"; fi
    _note="evidence: $2"
  fi
  _note=$(printf '%s' "$_note" | tr '\t\n' '  ')
  _st=$(sw_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open switch for $_key"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  st_set "$_st" "done_$_step" "$AO_T_EPOCH $_note"
  echo "marked $_step for $_key"
}

sw_ack() {
  sw_key "${1-}"
  _key=$1 _tok=${2-}
  _st=$(sw_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open switch for $_key"
  [ -n "$_tok" ] && [ "$_tok" = "$(st_get "$_st" token)" ] || refuse "wrong token for $_key"
  _tc=$(st_get "$_st" to_client) _ts=$(st_get "$_st" to_sid)
  # Which client is asking: a Codex command session carries its thread id,
  # a Claude Code shell carries CLAUDECODE.
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    [ "$_tc" = codex ] && [ "$CODEX_THREAD_ID" = "$_ts" ] || refuse "this Codex thread is not the incoming session ($_tc $_ts)"
    _how="acknowledged from Codex thread $_ts"
  elif [ -n "${CLAUDECODE:-}" ]; then
    [ "$_tc" = claude ] || refuse "this is a Claude session; the incoming side is $_tc"
    _how="acknowledged from a Claude session"
  else
    _how="acknowledged (client not detectable)"
  fi
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  st_set "$_st" ack "$AO_T_EPOCH $_how"
  echo "$_how"
}

sw_side() {
  ao_is_name "${1-}" || ao_die "$AO_E_USAGE" "usage: switch.sh side KEY"
  sw_row "$1" || ao_die "$AO_E_USAGE" "no registry row for '$1'"
  printf '%s %s %s\n' "$R_CLIENT" "$R_SID" "$R_NAME"
}

# ---------------------------------------------------------------- check

_sw_check_cb() {
  ao_is_bridge_key "$OP_KEY" && return 0
  case $OP_SID in '' | - | pending)
    printf 'no active side: %s has no session in the registry\n' "$OP_KEY"; _bad=1; return 0 ;;
  esac
  printf 'ok: %s on %s (%s)\n' "$OP_KEY" "$OP_CLIENT" "$OP_SID"
}

sw_check() {
  _bad=0
  ao_registry_each _sw_check_cb
  # A session id may lead one operator only.
  _dup=$(awk -F'\t' '$1 !~ /^#/ && $4 != "" && $4 != "-" && $4 != "pending" { print $4 }' "$AO_REGISTRY" | sort | uniq -d)
  [ -z "$_dup" ] || { printf 'one session on several rows: %s\n' "$_dup"; _bad=1; }
  for _s in "$AO_STATE/switch"/*; do
    [ -f "$_s" ] || continue
    _at=$(st_get "$_s" started)
    printf 'open switch: %s since %s UTC (switch.sh verify %s)\n' "${_s##*/}" "$(ao_utc "${_at:-0}")" "${_s##*/}"
    _bad=1
  done
  for _h in "$AO_STATE/holds"/* "$AO_STATE/mailroom-pause"; do
    [ -f "$_h" ] || continue
    if ao_hold_active "$_h"; then
      printf 'hold: %s by %s until %s%s\n' "${_h##*/}" "$AO_H_OWNER" "$AO_H_UNTIL" "${AO_H_REASON:+ ($AO_H_REASON)}"
    else
      printf 'hold not honoured (expired, or no owner, expiry or reason): %s (switch.sh unhold %s)\n' "$_h" "${_h##*/}"
      _bad=1
    fi
  done
  _lk=$AO_HOME/operators/ORACLE-LOCK
  if [ ! -f "$_lk" ]; then printf 'no Oracle lock: %s (switch.sh oracle-lock take CLIENT --session ID)\n' "$_lk"; _bad=1
  else
    _hold=$(sed -n 's/^holder=//p' "$_lk" | head -n 1)
    if sw_family "$_hold"; then printf 'oracle: %s (%s)\n' "$_hold" "$(sed -n 's/^session=//p' "$_lk" | head -n 1)"
    else printf 'Oracle lock has no valid holder: %s\n' "$_lk"; _bad=1; fi
  fi
  exit "$_bad"
}

# ---------------------------------------------------------------- holds

sw_hold_file() {
  if [ "$1" = mailroom ]; then printf '%s/mailroom-pause\n' "$AO_STATE"
  else
    if ! ao_is_name "$1" || ! ao_registry_has "$1"; then ao_die "$AO_E_USAGE" "no registry row for '$1'"; fi
    printf '%s/holds/%s\n' "$AO_STATE" "$1"
  fi
}

sw_hold() {
  [ $# -ge 1 ] || ao_die "$AO_E_USAGE" "usage: switch.sh hold KEY|mailroom --owner WHO --until DATE --reason TEXT"
  _f=$(sw_hold_file "$1")
  shift
  _o='' _u='' _r=''
  while [ $# -gt 0 ]; do
    case $1 in
      --owner | --until | --reason)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        case $2 in *"$AO_NL"*) ao_die "$AO_E_USAGE" "$1 must be one line" ;; esac
        case $1 in --owner) _o=$2 ;; --until) _u=$2 ;; --reason) _r=$2 ;; esac
        shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
    esac
    shift
  done
  [ -n "$_o" ] && [ -n "$_r" ] || ao_die "$AO_E_USAGE" "a hold names its owner, expiry and reason (--owner, --until, --reason; K-07)"
  _tmp=$(ao_tmp hold)
  printf 'owner=%s\nuntil=%s\nreason=%s\nset=%s\n' "$_o" "$_u" "$_r" "$AO_T_ISO" >"$_tmp"
  ao_hold_active "$_tmp" || ao_die "$AO_E_USAGE" "--until must be today or later: YYYY-MM-DD or YYYY-MM-DDTHH:MM"
  ao_write_atomic "$_f" <"$_tmp" || ao_die "$AO_E_FAIL" "cannot write $_f"
  echo "held: ${_f##*/} by $_o until $_u"
}

sw_unhold() {
  _f=$(sw_hold_file "${1-}")
  [ -f "$_f" ] || { echo "no hold: ${1-}"; return 0; }
  rm -f "$_f" && echo "released: ${1-}"
}

# ---------------------------------------------------------------- oracle lock

sw_oracle_lock() {
  _lk=$AO_HOME/operators/ORACLE-LOCK
  case ${1:-show} in
    show) [ -f "$_lk" ] || ao_die "$AO_E_FAIL" "no Oracle lock: $_lk"; cat "$_lk" ;;
    take)
      sw_family "${2-}" || ao_die "$AO_E_USAGE" "usage: switch.sh oracle-lock take claude|codex --session ID"
      if [ "${3-}" != --session ] || ! ao_is_name "${4-}"; then ao_die "$AO_E_USAGE" "usage: switch.sh oracle-lock take claude|codex --session ID"; fi
      printf 'holder=%s\nsession=%s\nsince=%s\nnote=The one active Oracle (K-13). Only the holder acts as Oracle; the other client stays dormant and redirects. Change only on the human'"'"'s word.\n' \
        "$2" "$4" "$AO_T_ISO" | ao_write_atomic "$_lk" || ao_die "$AO_E_FAIL" "cannot write $_lk"
      echo "Oracle lock: $2 ($4)" ;;
    *) ao_die "$AO_E_USAGE" "usage: switch.sh oracle-lock [show | take CLIENT --session ID]" ;;
  esac
}

main() {
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    '') ao_usage; exit "$AO_E_USAGE" ;;
  esac
  cmd=$1
  shift
  ao_load
  ao_lease_traps
  case $cmd in
    switch) sw_switch "$@" ;;
    verify) sw_verify "$@" ;;
    mark) sw_mark "$@" ;;
    ack) sw_ack "$@" ;;
    side) sw_side "$@" ;;
    check) sw_check ;;
    hold) sw_hold "$@" ;;
    unhold) sw_unhold "$@" ;;
    oracle-lock) sw_oracle_lock "$@" ;;
    *) ao_die "$AO_E_USAGE" "unknown command '$cmd' (see --help)" ;;
  esac
}

main "$@"
