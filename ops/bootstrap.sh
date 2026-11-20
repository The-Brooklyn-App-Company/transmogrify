#!/bin/sh
# bootstrap.sh - the guided first run: start the Oracle on whichever client
# you begin with, set up the always-on host, put a toehold in the other
# client, and walk you through the few clicks only a person can do.
#
# Usage: bootstrap.sh [--yes] [--client claude|codex] [--home DIR]
#                     [--example both|claude-only|codex-only]
#                     [--tz ZONE] [--set KEY=VALUE]... [--oracle-session ID]
#        bootstrap.sh status
#        bootstrap.sh mark STEP
#
# It explains each step before doing it and asks you to confirm the choices
# that are yours: the client you start on, the Oracle home, the profile
# example, your timezone, the profile's CHANGE-ME values (models), and
# making this client the one active Oracle. Everything else it does itself,
# by the kit's own scripts, re-runnable at any time:
#   1. install.sh oracle      the Oracle home, registry and profile
#   2. the profile            owner_tz, your answers for CHANGE-ME keys, and
#                             the Codex app's bundled node and tool server,
#                             found inside the app bundle
#   3. install.sh host --apply  App Nap off per desktop app, the ProcessType
#                             check, both launchd units with watch paths
#                             generated from the registry, both bridge homes
#                             with their lean duty files, the bridge rows
#                             (the one file for bridge ids)
#   4. install.sh sync OTHER  the toehold: every home gets the other
#                             client's files
#   5. the Oracle's session id and the Oracle lock (on your word)
#   6. grants.sh render-claude / render-codex --all  the owner's standing
#                             grants written into each client's approval
#                             layer (the Oracle home's .codex included),
#                             only on consent: a yes at the terminal, or
#                             --yes given explicitly
#   7. the Codex recovery hook: <codex home>/hooks.json written on consent,
#      the exact CLI steps to trust it (the desktop app has no /hooks),
#      Codex's trust record read back, then one read-only `codex exec`
#      check that the digest arrives
# Then the checklist: each in-app step with what to do and the check that
# proves it (a registry id, the Codex watcher's heartbeat, a test note's
# delivery); steps no script can see are confirmed with `bootstrap.sh mark`.
# `bootstrap.sh status` prints the checklist only: it sends no test note.
# Guided, it waits for you and re-checks; unattended, it prints what is left.
# docs/operations/hosts-and-ci.md#first-run.
#
# --yes: no questions; choices come from the options and defaults (also the
# behaviour when stdin is not a terminal). AO_APPS_DIR (default
# /Applications) is where the desktop apps are looked for.
#
# Exit codes: 0 every step done; 1 steps left; 2 usage error; 5 refused.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"
. "$AO_SCRIPTS/lib/mailroom.sh"
. "$AO_SCRIPTS/lib/guide.sh"

BS_MARKS='sign-in restart-apps pins'
# `mark hooks`: the Claude recovery hook is registered somewhere the
# checklist cannot read (a project's own settings file).
BS_MARKS_OK="$BS_MARKS hooks"

bs_marks_file() { printf '%s/bootstrap.marks\n' "$AO_STATE"; }
bs_marked() { [ -n "$(ao_st_get "$(bs_marks_file)" "$1")" ]; }

# bs_profile_set KEY VALUE  Set one key in the kit's own profile (never a
# client's settings): the line is replaced, or appended.
bs_profile_set() {
  _pf=$(ao_profile_path)
  _v=$(printf '%s' "$2" | tr -d '\n')
  { grep -v "^$1=" "$_pf"; printf '%s=%s\n' "$1" "$_v"; } | ao_write_atomic "$_pf" && chmod 600 "$_pf"
}

bs_tz() {
  if [ -n "${TZ:-}" ]; then printf '%s\n' "$TZ"; return; fi
  _l=$(readlink /etc/localtime 2>/dev/null)
  case $_l in */zoneinfo/*) printf '%s\n' "${_l#*/zoneinfo/}" ;; *) echo UTC ;; esac
}
bs_is_tz() { case $1 in '' | *[!A-Za-z0-9/_+-]*) return 1 ;; esac; return 0; }
bs_is_example() { case $1 in both | claude-only | codex-only) return 0 ;; esac; return 1; }

# bs_codex_paths  Find the Codex desktop app's bundled node and its
# codex-app-tools server inside the app bundle; prints `NODE SERVER`.
bs_codex_paths() {
  _ad=${AO_APPS_DIR:-/Applications}
  _srv=$(find "$_ad" -maxdepth 7 -path '*/Contents/Resources/*' -name server.mjs -path '*codex-app-tools*' 2>/dev/null | head -n 1)
  [ -n "$_srv" ] || return 1
  _res=${_srv%%/Contents/Resources/*}/Contents/Resources
  _node=$(find "$_res" -maxdepth 4 -type f -name node -perm -u+x 2>/dev/null | head -n 1)
  [ -n "$_node" ] || return 1
  printf '%s %s\n' "$_node" "$_srv"
}

bs_sid() { awk -F'\t' -v k="$1" '$1 == k { print $4; exit }' "$AO_REGISTRY" 2>/dev/null; }
bs_has() { case $(bs_sid "$1") in '' | - | pending) return 1 ;; esac; return 0; }

# ---------------------------------------------------------------- run

bs_run() {
  _client='' _home='' _example='' _tz='' _osid=''
  _sets=$(ao_tmp sets)
  : >"$_sets"
  while [ $# -gt 0 ]; do
    case $1 in
      --client | --home | --example | --tz | --set | --oracle-session)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        case $1 in
          --client) _client=$2 ;;
          --home) _home=$2 ;;
          --example) _example=$2 ;;
          --tz) _tz=$2 ;;
          --set) case $2 in [a-z]*=*) printf '%s\n' "$2" >>"$_sets" ;; *) ao_die "$AO_E_USAGE" "--set needs KEY=VALUE" ;; esac ;;
          --oracle-session) _osid=$2 ;;
        esac
        shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1' (see --help)" ;;
    esac
    shift
  done
  if [ -z "$_client" ]; then
    if [ -n "${CODEX_THREAD_ID:-}" ]; then _client=codex; else _client=claude; fi
  fi
  _pf=$(ao_profile_path)
  _phome=''
  [ ! -r "$_pf" ] || _phome=$(sed -n 's/^oracle_home=//p' "$_pf" | tail -n 1)
  ao_explain "Transmogrify: first run" \
    "This sets up your Oracle (your persistent main session) on the client you" \
    "start with, makes this machine an always-on host, and puts a toehold in the" \
    "other client. It asks only for your choices; it never signs in, never uses" \
    "sudo and edits a client's own settings only on your yes. Safe to run again."
  ao_ask _client "Client you start the Oracle on (claude or codex)" "$_client" ao_is_client
  ao_ask _home "Oracle home (a new private git repository)" "${_home:-${_phome:-~/ops/oracle}}" ao_is_dir_path
  ao_ask _example "Clients you use (both, claude-only, codex-only)" "${_example:-both}" bs_is_example
  ao_ask _tz "Your timezone (times are reported in it; logs stay UTC)" "${_tz:-$(bs_tz)}" bs_is_tz
  ao_confirm "Set up the Oracle in $_home on $_client now?" || { ao_msg "refused: not confirmed"; exit 5; }

  ao_explain "1. The Oracle home" "install.sh oracle: the home, its registry and your profile ($_pf)."
  _homeabs=$(ao_expand_path "$_home" "$PWD")
  sh "$AO_SCRIPTS/install.sh" oracle "$_homeabs" --client "$_client" --profile-example "$_example" </dev/null |
    grep -E '^(create|keep) ' | sed 's/^/   /'
  [ -r "$_pf" ] || ao_die "$AO_E_FAIL" "no profile at $_pf after install.sh oracle"

  ao_explain "2. Your profile" "Your timezone, the models (CHANGE-ME values), and the Codex app's paths."
  bs_profile_set owner_tz "$_tz" || ao_die "$AO_E_FAIL" "cannot write $_pf"
  while IFS= read -r _kv; do
    bs_profile_set "${_kv%%=*}" "${_kv#*=}" || ao_die "$AO_E_FAIL" "cannot write $_pf"
  done <"$_sets"
  # Keys are single words, and ao_ask reads the terminal, so not a read loop.
  # shellcheck disable=SC2013
  for _k in $(sed -n 's/^\([a-z_]*\)=CHANGE-ME.*/\1/p' "$_pf"); do
    _ans=''
    [ -z "$AO_GUIDED" ] || ao_ask _ans "$_k (Enter to decide later)" "" ""
    [ -z "$_ans" ] || bs_profile_set "$_k" "$_ans"
  done
  ao_load
  if [ "$_example" != claude-only ] && [ -z "$(ao_cfg bridge_codex_server '')" ]; then
    if _cp=$(bs_codex_paths); then
      printf '   found the Codex app tools: %s\n' "${_cp#* }"
      if ao_confirm "Use the node and tool server bundled in the Codex app for the Codex Mailroom?"; then
        bs_profile_set bridge_codex_node "${_cp%% *}" && bs_profile_set bridge_codex_server "${_cp#* }"
      fi
    else
      echo "   the Codex app's bundled tool server was not found under ${AO_APPS_DIR:-/Applications}; set bridge_codex_node and bridge_codex_server later"
    fi
  fi
  ao_load

  ao_explain "3. The always-on host" \
    "install.sh host --apply: App Nap off per desktop app, the launchd units (watch" \
    "paths generated from the registry), both Mailroom homes with their duty files," \
    "the bridge rows. First the check, then the changes."
  sh "$AO_SCRIPTS/install.sh" host </dev/null | sed -n '1,/item(s) need you/p' | sed 's/^/   /'
  if ao_confirm "Apply the host changes listed above?"; then
    sh "$AO_SCRIPTS/install.sh" host --apply </dev/null | sed -n '1,/item(s) need you/p' | sed 's/^/   /'
  fi

  _other=codex
  [ "$_client" = claude ] || _other=claude
  if [ "$_example" = both ]; then
    ao_explain "4. A toehold in $_other" "install.sh sync $_other: every home gets what $_other needs (its files, a session line)."
    sh "$AO_SCRIPTS/install.sh" sync "$_other" </dev/null | grep -E '^(create|keep|append) ' | sed 's/^/   /'
  fi

  ao_explain "5. The Oracle session and the Oracle lock" \
    "The registry records the Oracle's session id; the lock names the one active" \
    "Oracle (K-13). The lock changes only on your word."
  [ -n "$_osid" ] || [ "$_client" != codex ] || _osid=${CODEX_THREAD_ID:-}
  if [ -z "$_osid" ] && ! bs_has "$AO_ORACLE_KEY" && [ -n "$AO_GUIDED" ]; then
    ao_ask _osid "The Oracle's session or thread id (Enter if not started yet)" "" ""
  fi
  if [ -n "$_osid" ]; then
    sh "$AO_SCRIPTS/operator.sh" session "$AO_ORACLE_KEY" "$_osid" --client "$_client" </dev/null | sed 's/^/   /'
  fi
  if bs_has "$AO_ORACLE_KEY" && [ ! -f "$AO_HOME/operators/ORACLE-LOCK" ] &&
    ao_confirm "Make $_client the one active Oracle (session $(bs_sid "$AO_ORACLE_KEY"))?"; then
    sh "$AO_SCRIPTS/switch.sh" oracle-lock take "$_client" --session "$(bs_sid "$AO_ORACLE_KEY")" </dev/null | sed 's/^/   /'
  fi
  bs_grants
  bs_hooks
  bs_checklist_loop
}

# ---------------------------------------------------------------- recovery hooks
# Each client runs ops/recover-context.sh at session start, so a session
# (re)starts from the home's files. Claude Code: a SessionStart hook in its
# settings; the checklist reads the settings file. Codex: a SessionStart hook
# in <codex home>/hooks.json, which Codex runs only once a person trusts it
# in the interactive CLI (the desktop app's composer has no /hooks). Codex
# records the trust in its config.toml; the checklist reads that record, then
# makes one read-only `codex exec` run that must quote the digest.

# bs_uses CLIENT  The registry has a row on CLIENT, or its Mailroom.
bs_uses() {
  ao_registry_has "mailroom-$1" ||
    awk -F'\t' -v c="$1" '$5 == c { f = 1 } END { exit !f }' "$AO_REGISTRY" 2>/dev/null
}

bs_codex_home() { printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; }
bs_claude_settings() { printf '%s/settings.json\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# bs_codex_cli  The Codex CLI used for the trust step and its check: the
# profile's codex_cli, else codex on PATH, else one inside a desktop app
# bundle. A candidate counts only if it answers --version: no app path is
# assumed to exist or to work.
bs_codex_cli() {
  _ad=${AO_APPS_DIR:-/Applications}
  for _c in "$(ao_cfg codex_cli '')" "$(command -v codex 2>/dev/null)" \
    "$_ad/ChatGPT.app/Contents/Resources/codex-cli/bin/codex" \
    "$_ad/Codex.app/Contents/Resources/codex-cli/bin/codex"; do
    [ -n "$_c" ] && [ -x "$_c" ] || continue
    ao_timeout 30 "$_c" --version >/dev/null 2>&1 || continue
    printf '%s\n' "$_c"
    return 0
  done
  return 1
}

# bs_hook_cmd  The hook's command: the digest script by absolute path, with
# the profile when it is not at its default place.
bs_hook_cmd() {
  _hc_p=$(ao_profile_path)
  if [ "$_hc_p" = "${XDG_CONFIG_HOME:-$HOME/.config}/agent-operations/profile" ]; then
    printf '%s\n' "$AO_SCRIPTS/recover-context.sh"
  else
    printf 'env AO_PROFILE=%s %s\n' "$_hc_p" "$AO_SCRIPTS/recover-context.sh"
  fi
}

# bs_codex_hook_state  ours | other | toml | none: whether hooks.json runs
# the digest, exists without it, or hooks are defined in config.toml (Codex
# takes one or the other, never both).
bs_codex_hook_state() {
  _hs_d=$(bs_codex_home)
  if grep -Eq '^[[:space:]]*\[hooks\][[:space:]]*$|^[[:space:]]*\[\[hooks\.' "$_hs_d/config.toml" 2>/dev/null; then echo toml
  elif [ ! -f "$_hs_d/hooks.json" ]; then echo none
  elif grep -q 'recover-context\.sh' "$_hs_d/hooks.json"; then echo ours
  else echo other; fi
}

# bs_codex_hook_trusted  Codex's own record: a [hooks.state."<hooks.json>:
# session_start:..."] table with a trusted_hash and enabled = true.
bs_codex_hook_trusted() {
  _ht_d=$(bs_codex_home)
  awk -v p="[hooks.state.\"$_ht_d/hooks.json:session_start:" '
    function close_s() { if (in_s && h && e) found = 1 }
    index($0, p) == 1 { close_s(); in_s = 1; h = 0; e = 0; next }
    /^[[:space:]]*\[/ { close_s(); in_s = 0; next }
    in_s && /^[[:space:]]*trusted_hash[[:space:]]*=[[:space:]]*"[^"]+"/ { h = 1 }
    in_s && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { e = 1 }
    END { close_s(); exit !found }' "$_ht_d/config.toml" 2>/dev/null
}

# bs_codex_hook_write  Write <codex home>/hooks.json (it must not exist).
bs_codex_hook_write() {
  _hw_d=$(bs_codex_home)
  mkdir -p "$_hw_d" || return 1
  /usr/bin/python3 -I - "$_hw_d/hooks.json" "$(bs_hook_cmd)" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
doc = {"description": "Transmogrify recovery digest (ops/recover-context.sh)",
       "hooks": {"SessionStart": [{"matcher": "startup|resume|compact|fork",
                                   "hooks": [{"type": "command", "command": cmd,
                                              "statusMessage": "Loading recovery digest", "timeout": 10}]}]}}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(json.dumps(doc, indent=2) + "\n")
PY
}

# bs_trust_steps CLI  The exact owner steps for trusting the hook.
bs_trust_steps() {
  printf '   1. In a terminal, run: "%s" -C "%s"\n' "$1" "$AO_HOME"
  printf '   2. Type /hooks, choose SessionStart, then Trust.\n'
  printf '   3. Leave the CLI with /exit. (The desktop app has no /hooks command.)\n'
}

# bs_hooks  Step 7: write the Codex hook on consent and guide its trust.
bs_hooks() {
  bs_uses codex || return 0
  _hk_d=$(bs_codex_home)
  ao_explain "7. The recovery hook on Codex" \
    "Codex runs ops/recover-context.sh at session start once it is in $_hk_d/hooks.json" \
    "and you have trusted it in the Codex CLI. This writes a file in Codex's own folder," \
    "so it asks first; then it shows the exact trust steps and checks Codex's record."
  case $(bs_codex_hook_state) in
    none)
      printf '   Would write %s with one SessionStart hook: %s\n' "$_hk_d/hooks.json" "$(bs_hook_cmd)"
      case "$(ao_profile_path)$AO_SCRIPTS" in *' '* | *\"* | *\'*)
        echo "   Not written: a path has a space or a quote; add the hook by hand (ops/templates/home/settings/README.md)."; return 0 ;;
      esac
      if [ -n "${_yes-}" ] || ao_consent "Write $_hk_d/hooks.json?"; then
        if bs_codex_hook_write; then echo "   written: $_hk_d/hooks.json"
        else echo "   could not write $_hk_d/hooks.json"; return 0; fi
      else
        echo "   Not written (no consent): run bootstrap.sh at a terminal or with --yes."; return 0
      fi ;;
    other) echo "   $_hk_d/hooks.json exists without the digest: add this SessionStart hook to it yourself: $(bs_hook_cmd)"; return 0 ;;
    toml) echo "   Hooks are defined in $_hk_d/config.toml: add a SessionStart hook there that runs $(bs_hook_cmd) (Codex reads one place, never both)."; return 0 ;;
  esac
  bs_codex_hook_trusted && { echo "   Codex records the hook as trusted."; return 0; }
  if ! _hk_cli=$(bs_codex_cli); then
    echo "   No working Codex CLI found (profile codex_cli, PATH, or inside the desktop app). Install it, or set codex_cli in $(ao_profile_path), then run bootstrap.sh again."
    return 0
  fi
  echo "   Trust it once:"
  bs_trust_steps "$_hk_cli"
  while ! bs_codex_hook_trusted; do
    ao_pause "Trust the hook as above" || return 0
  done
  echo "   Codex records the hook as trusted."
}

# bs_hook_rows  The checklist rows for both recovery hooks.
bs_hook_rows() {
  if bs_uses claude; then
    _hr_s=$(bs_claude_settings)
    if grep -q 'recover-context\.sh' "$_hr_s" 2>/dev/null; then ao_step PASS hook-claude "SessionStart hook in $_hr_s"
    elif bs_marked hooks; then ao_step PASS hook-claude "confirmed (registered elsewhere)"
    else ao_step TODO hook-claude "add to $_hr_s: {\"hooks\": {\"SessionStart\": [{\"matcher\": \"compact|resume\", \"hooks\": [{\"type\": \"command\", \"command\": \"$(bs_hook_cmd)\"}]}]}} (merge with what is there); the checklist then finds it (registered elsewhere: bootstrap.sh mark hooks)"; fi
  fi
  bs_uses codex || return 0
  _hr_d=$(bs_codex_home)
  _hr_m=$(bs_marks_file)
  case $(bs_codex_hook_state) in
    none) ao_step TODO hook-codex "bootstrap.sh writes $_hr_d/hooks.json on your yes (run it at a terminal, or with --yes)"; return ;;
    other | toml) ao_step TODO hook-codex "add a SessionStart hook that runs $(bs_hook_cmd) to Codex's hooks ($_hr_d/hooks.json or config.toml, one of them)"; return ;;
  esac
  if ! bs_codex_hook_trusted; then
    _hr_cli=$(bs_codex_cli) || _hr_cli='<codex CLI: set codex_cli in the profile>'
    ao_step TODO hook-codex "trust it once in the Codex CLI: run \"$_hr_cli\" -C \"$AO_HOME\", type /hooks, choose SessionStart, Trust, then /exit (the desktop app has no /hooks); the checklist then reads Codex's record"
    return
  fi
  if [ -n "$(ao_st_get "$_hr_m" hook-codex-verified)" ]; then
    ao_step PASS hook-codex "trusted; a fresh Codex run received the digest"
    return
  fi
  if [ -n "${BS_READONLY-}" ] || [ -n "${BS_HOOK_TRIED-}" ]; then
    ao_step WAIT hook-codex "trusted; bootstrap.sh (not status) runs one read-only Codex check that the digest arrives"
    return
  fi
  BS_HOOK_TRIED=1
  if ! _hr_cli=$(bs_codex_cli); then ao_step TODO hook-codex "trusted, but no working Codex CLI to check it: set codex_cli in the profile"; return; fi
  _hr_o=$(ao_tmp hook-check)
  ao_timeout 300 "$_hr_cli" exec --ephemeral --skip-git-repo-check -s read-only -C "$AO_HOME" -o "$_hr_o" \
    "Reply with only the first line of the recovery digest your session start hook gave you, exactly as given, or NONE if you received none." >/dev/null 2>&1
  if grep -q '^## Oracle recovery (' "$_hr_o" 2>/dev/null; then
    ao_st_set "$_hr_m" hook-codex-verified "$AO_T_EPOCH"
    ao_step PASS hook-codex "trusted; a fresh read-only Codex run quoted the digest's first line"
  else
    ao_step TODO hook-codex "trusted, but a fresh read-only Codex run did not quote the digest (it said: $(head -n 1 "$_hr_o" 2>/dev/null | cut -c 1-80)); check $_hr_d/hooks.json, re-trust after any edit, then run bootstrap.sh again"
  fi
}

# bs_grants  Step 6: the owner's standing grants rendered into each client's
# own approval layer, written only on consent: a yes at the terminal, or
# --yes given explicitly. Running without a terminal is not consent here.
bs_grants() {
  _gf=$(ao_cfg_path grants_file operators/GRANTS.md)
  [ -f "$_gf" ] || return 0
  sh "$AO_SCRIPTS/grants.sh" check --no-resolve --findings </dev/null >/dev/null 2>&1 && return 0
  ao_explain "6. Approvals that follow an operator" \
    "Your standing grants ($_gf) are written into each client's own approval layer:" \
    "Claude Code's autoMode.allow, and a managed [auto_review] block in each home's .codex" \
    "(the Oracle home's too, for grants marked for Codex). Only tagged entries and the" \
    "managed block change, after a backup. This writes client settings, so it asks first."
  sh "$AO_SCRIPTS/grants.sh" render-claude --dry-run </dev/null 2>&1 | sed 's/^/   /'
  sh "$AO_SCRIPTS/grants.sh" render-codex --all --dry-run </dev/null 2>&1 | sed 's/^/   /'
  if [ -n "${_yes-}" ] || ao_consent "Write these approvals into the client settings listed above?"; then
    sh "$AO_SCRIPTS/grants.sh" render-claude </dev/null 2>&1 | sed 's/^/   /'
    sh "$AO_SCRIPTS/grants.sh" render-codex --all </dev/null 2>&1 | sed 's/^/   /'
  else
    echo "   Not written (no consent): run bootstrap.sh at a terminal or with --yes, or grants.sh render-claude and render-codex --all yourself."
  fi
}

# ---------------------------------------------------------------- checklist

bs_checklist() {
  AO_STEPS_LEFT=0
  ao_mr_init
  _cl=$(awk -F'\t' -v k="$AO_ORACLE_KEY" '$1 == k { print $5; exit }' "$AO_REGISTRY" 2>/dev/null)
  _cl=${_cl:-claude}
  _bc=$(ao_registry_has mailroom-claude && echo 1)
  _bx=$(ao_registry_has mailroom-codex && echo 1)
  printf '\nFirst-run checklist (%s):\n' "$AO_T_DATE"
  _left=$(grep -c '^[a-z_]*=CHANGE-ME' "$AO_PROFILE" 2>/dev/null)
  if [ "${_left:-0}" -eq 0 ]; then ao_step PASS profile "no CHANGE-ME left"
  else ao_step TODO profile "$_left CHANGE-ME value(s) in $AO_PROFILE: pick the models with your own judgment, then run bootstrap.sh again"; fi
  if bs_has "$AO_ORACLE_KEY"; then ao_step PASS oracle "session $(bs_sid "$AO_ORACLE_KEY")"
  else ao_step TODO oracle "start a $_cl session in $AO_HOME (model and effort chosen when you create it), title it \"Oracle\", pin it; then: bootstrap.sh --oracle-session <id>"; fi
  if [ -f "$AO_HOME/operators/ORACLE-LOCK" ]; then ao_step PASS oracle-lock "$(sed -n 's/^holder=//p' "$AO_HOME/operators/ORACLE-LOCK" | head -n 1)"
  else ao_step TODO oracle-lock "after the Oracle session: bootstrap.sh again (it asks), or switch.sh oracle-lock take $_cl --session <id>"; fi
  # Standing grants follow an operator across clients (docs/operations/grants.md).
  _gf=$(ao_cfg_path grants_file operators/GRANTS.md)
  if [ ! -f "$_gf" ]; then ao_step PASS grants "no grants file yet (ops/templates/oracle/GRANTS.md when the owner gives one)"
  elif _gc=$(sh "$AO_SCRIPTS/grants.sh" check --findings 2>&1); then ao_step PASS grants "rendered and resolved on both clients"
  else ao_step TODO grants "$(printf '%s\n' "$_gc" | sed -n 's/^- grants: //p' | head -n 1) (review, then grants.sh render-claude / render-codex --all)"; fi
  bs_hook_rows
  for _m in $BS_MARKS; do
    if bs_marked "$_m"; then ao_step PASS "$_m" "confirmed"; continue; fi
    case $_m in
      sign-in) _do="open each desktop app you use and sign in yourself (the kit never signs in for you)" ;;
      restart-apps) _do="quit and reopen each desktop app once, so App Nap stays off" ;;
      pins) _do="pin the Oracle; Claude: active operators pinned, inactive ones in a section named \"Inactive Operators\"; Codex: the active threads and the Mailroom pinned (docs/operations/conventions.md)" ;;
    esac
    ao_step TODO "$_m" "$_do; then: bootstrap.sh mark $_m"
  done
  if [ -n "$_bc" ]; then
    _bh=$(awk -F'\t' '$1 == "mailroom-claude" { print $3; exit }' "$AO_REGISTRY")
    if bs_has mailroom-claude; then ao_step PASS claude-mailroom "session $(bs_sid mailroom-claude)"
    else ao_step TODO claude-mailroom "in Claude, start a session in $_bh on the cheapest model (set at creation), title it \"Mailroom\" (it may nest under the Oracle), allow mailroom.sh (settings/README.md), send it \"Re-arm\"; then: operator.sh session mailroom-claude <id>"; fi
  fi
  if [ -n "$_bx" ]; then
    _bh=$(awk -F'\t' '$1 == "mailroom-codex" { print $3; exit }' "$AO_REGISTRY")
    if bs_has mailroom-codex; then ao_step PASS codex-mailroom "thread $(bs_sid mailroom-codex)"
    else ao_step TODO codex-mailroom "in Codex, create a thread in $_bh on the cheapest model (set at creation), title it \"Mailroom\", pin it; then: operator.sh session mailroom-codex <id>"; fi
    if ao_mr_watcher_up codex; then ao_step PASS codex-watcher "armed"
    else ao_step TODO codex-watcher "send the Codex Mailroom \"Re-arm doorbell watcher\" (needs bridge_codex_node and bridge_codex_server in the profile)"; fi
  fi
  # The proof: a test note to the Oracle comes back as a delivered ring.
  _ms=$(bs_marks_file)
  _sent=$(ao_st_get "$_ms" test-note)
  if [ -z "${BS_READONLY-}" ] && [ -z "$_sent" ] && bs_has "$AO_ORACLE_KEY" && { [ -z "$_bc" ] || bs_has mailroom-claude; }; then
    if _tn=$(printf 'First-run check (bootstrap.sh, automated): if you can read this, the mailroom reached the Oracle. No action needed.\n' |
      ao_inbox_put "$AO_ORACLE_KEY" bootstrap-check); then
      ao_st_set "$_ms" test-note-name "${_tn##*/}"
      ao_st_set "$_ms" test-note "$AO_T_EPOCH"
    fi
    _sent=$(ao_st_get "$_ms" test-note)
  fi
  if [ -z "$_sent" ] && [ -n "${BS_READONLY-}" ]; then
    ao_step WAIT round-trip "no test note sent yet (status only reads; bootstrap.sh sends it once the Oracle and its Mailroom have ids)"
  elif [ -z "$_sent" ]; then
    ao_step WAIT round-trip "a test note to the Oracle goes out once the Oracle and its Mailroom have ids"
  elif ao_mr_note_received "$(ao_st_get "$_ms" test-note-name)" "$_sent"; then
    ao_step PASS round-trip "the test note reached the Oracle"
  else
    ao_step WAIT round-trip "a test note went to the Oracle $(ao_utc "$_sent") UTC; waiting for its delivery (mailroom.sh status)"
  fi
}

bs_checklist_loop() {
  while :; do
    ao_clock
    bs_checklist
    if [ "$AO_STEPS_LEFT" -eq 0 ]; then
      echo "Everything is set up. Next: operator.sh create <key> for your first operator."
      return 0
    fi
    printf '%s step(s) left.\n' "$AO_STEPS_LEFT"
    ao_pause "Do the next step" || return "$AO_E_FAIL"
  done
}

main() {
  _yes=''
  case ${1-} in
    -h | --help) ao_usage; exit 0 ;;
    --yes) _yes=1; shift ;;
  esac
  ao_guide_init "$_yes"
  case ${1-} in
    status) ao_load --no-state; BS_READONLY=1; bs_checklist; [ "$AO_STEPS_LEFT" -eq 0 ] || exit "$AO_E_FAIL" ;;
    mark)
      ao_load
      case " $BS_MARKS_OK " in *" ${2-} "*) ;; *) ao_die "$AO_E_USAGE" "STEP must be one of: $BS_MARKS_OK" ;; esac
      ao_st_set "$(bs_marks_file)" "$2" "$AO_T_EPOCH"
      echo "marked ${2}" ;;
    *)
      bs_run "$@"
      exit $? ;;
  esac
}

main "$@"
