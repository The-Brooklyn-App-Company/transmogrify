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
#   2. the profile            owner_tz, your answers for CHANGE-ME keys, the
#                             folders of the claude and codex CLIs added to
#                             its path, and the Codex app's bundled node and
#                             tool server, found inside the app bundle
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
#      Codex's own hooks/list read back (enabled, trusted at the current
#      hash), then one isolated read-only `codex exec` check that the
#      digest arrives
#   8. Claude Code's own commit and pull-request attribution switched off
#      in its settings (K-30: agents act as the user), on consent, unless
#      the profile says attribution=disclose
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
# The caller's PATH, before the profile's `path` replaces it (ao_load).
BS_CALLER_PATH=$PATH
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"
. "$AO_SCRIPTS/lib/mailroom.sh"
. "$AO_SCRIPTS/lib/guide.sh"

# Marks: what a person confirms where no script can see it. pins: the
# Claude sidebar (nothing on disk shows it). The others only stand in where
# the automatic check cannot run: sign-in (no client CLI to ask),
# restart-apps (the app's process start cannot be read), hooks (a Claude
# hook registered where the checklist cannot read it).
BS_MARKS_OK='sign-in restart-apps pins hooks'

bs_marks_file() { printf '%s/bootstrap.marks\n' "$AO_STATE"; }
bs_marked() { [ -n "$(ao_st_get "$(bs_marks_file)" "$1")" ]; }

# bs_profile_set KEY VALUE  Set one key in the kit's own profile (never a
# client's settings): the line is replaced, or appended.
bs_profile_set() {
  _pf=$(ao_profile_path)
  _v=$(printf '%s' "$2" | tr -d '\n')
  { grep -v "^$1=" "$_pf"; printf '%s=%s\n' "$1" "$_v"; } | ao_write_atomic "$_pf" && chmod 600 "$_pf"
}

# bs_path_add_clis  The profile's `path` replaces PATH for every kit script,
# so the directories holding the claude and codex CLIs must be on it: each
# one the caller's PATH finds (and ~/.local/bin, where Claude Code's native
# installer puts claude, when claude is there but not on PATH) is appended
# when missing. Appended, never prepended, so the profile's order wins.
# Nothing changes when the profile has no `path` (PATH then stays as is).
# The parsed value is extended and written back unquoted (values are
# literal), so a quoted `path="..."` stays a valid search path.
bs_path_add_clis() {
  # The parsed value (quotes removed, last line wins), as ao_load will read it.
  _pa_cur=$(ao_profile_parse "$(ao_profile_path)" 2>/dev/null && ao_cfg path '')
  [ -n "$_pa_cur" ] || return 0
  _pa_new=$_pa_cur _pa_added=''
  for _pa_cli in claude codex; do
    _pa_bin=$(PATH=$BS_CALLER_PATH; command -v "$_pa_cli" 2>/dev/null) || _pa_bin=''
    case $_pa_bin in /*) ;; *) _pa_bin='' ;; esac
    if [ -z "$_pa_bin" ] && [ "$_pa_cli" = claude ] && [ -x "$HOME/.local/bin/claude" ]; then
      _pa_bin=$HOME/.local/bin/claude
    fi
    [ -n "$_pa_bin" ] || continue
    _pa_dir=${_pa_bin%/*}
    case $_pa_dir in '' | *:*) continue ;; esac
    case ":$_pa_new:" in *":$_pa_dir:"*) continue ;; esac
    _pa_new=$_pa_new:$_pa_dir
    _pa_added="$_pa_added $_pa_cli ($_pa_dir)"
  done
  [ -n "$_pa_added" ] || return 0
  bs_profile_set path "$_pa_new" || return 1
  echo "   path: added the folder of$_pa_added, so kit scripts find the CLI"
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

  ao_explain "2. Your profile" "Your timezone, the models (CHANGE-ME values), the CLIs' folders on its path, and the Codex app's paths."
  bs_profile_set owner_tz "$_tz" || ao_die "$AO_E_FAIL" "cannot write $_pf"
  while IFS= read -r _kv; do
    bs_profile_set "${_kv%%=*}" "${_kv#*=}" || ao_die "$AO_E_FAIL" "cannot write $_pf"
  done <"$_sets"
  bs_path_add_clis || ao_die "$AO_E_FAIL" "cannot write $_pf"
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
  bs_attribution
  bs_checklist_loop
}

# ---------------------------------------------------------------- attribution
# K-30: agents act as the authorized user. Claude Code adds its own commit
# trailer and pull-request footer unless its settings switch them off
# (`attribution`: {"commit": "", "pr": ""}; `includeCoAuthoredBy`: false for
# older clients). Step 8 sets both in the Claude settings file on consent,
# unless the profile says attribution=disclose; the checklist reads them.

bs_attr_disclosed() { [ "$(ao_cfg attribution none)" = disclose ]; }

bs_attribution() {
  bs_uses claude || return 0
  bs_attr_disclosed && return 0
  _at_s=$(bs_claude_settings)
  [ "$(bs_fr claude-attribution "$_at_s" | cut -f 1)" = ok ] && return 0
  ao_explain "8. No agent tags in Claude Code" \
    "Agents act as you (K-30): commits and pull requests made for you carry no agent" \
    "or model tag. Claude Code adds one unless its settings switch it off, so this sets" \
    "\"attribution\": {\"commit\": \"\", \"pr\": \"\"} and \"includeCoAuthoredBy\": false in $_at_s," \
    "keeping every other byte, after a backup. It asks first. (attribution=disclose in the" \
    "profile keeps the tags instead.)"
  if [ -n "${_yes-}" ] || ao_consent "Switch off Claude Code's commit and pull-request attribution in $_at_s?"; then
    _at_r=$(bs_fr claude-attribution-write "$_at_s")
    case $_at_r in
      written*) echo "   written: $_at_s (backup: ${_at_r#*"$AO_TAB"})" ;;
      unchanged) echo "   already set: $_at_s" ;;
      *) echo "   not written: ${_at_r#*"$AO_TAB"}" ;;
    esac
  else
    echo "   Not written (no consent): run bootstrap.sh at a terminal or with --yes."
  fi
}

bs_attribution_row() {
  bs_uses claude || return 0
  if bs_attr_disclosed; then ao_step PASS attribution "the profile discloses agent attribution (attribution=disclose)"; return; fi
  _ar_s=$(bs_claude_settings)
  _ar_v=$(bs_fr claude-attribution "$_ar_s")
  if [ "${_ar_v%%"$AO_TAB"*}" = ok ]; then ao_step PASS attribution "Claude Code adds no commit or pull-request attribution ($_ar_s)"
  else ao_step TODO attribution "${_ar_v#*"$AO_TAB"}: bootstrap.sh sets \"attribution\": {\"commit\": \"\", \"pr\": \"\"} and \"includeCoAuthoredBy\": false in $_ar_s on your yes (or add them yourself); the checklist then reads them"; fi
}

# ---------------------------------------------------------------- recovery hooks
# Each client runs ops/recover-context.sh at session start, so a session
# (re)starts from the home's files. Claude Code: a SessionStart hook in its
# settings, checked by parsing the settings JSON. Codex: a SessionStart hook
# (in <codex home>/hooks.json, or [hooks] in config.toml), which Codex runs
# only once a person trusts it in the interactive CLI (the desktop app's
# composer has no /hooks). The check asks Codex itself (`codex app-server`,
# hooks/list for the Oracle home: every layer, both representations, the
# hook's current hash and trust status), then makes one isolated read-only
# `codex exec` run that must quote the digest; a pass is bound to the hook's
# current hash and the home.

# bs_fr ARGS  The structured reader (lib/firstrun.py, system Python).
bs_fr() { /usr/bin/python3 -I "$AO_SCRIPTS/lib/firstrun.py" "$@"; }

# bs_rows  name TAB session TAB client for every operator, the client
# resolved the registry's one way (ao_operator_resolve: the row, else
# relay_default, overridden by a lease).
_bs_rows_cb() { printf '%s\t%s\t%s\n' "$OP_NAME" "${OP_SID:--}" "$OP_CLIENT"; }
bs_rows() { ao_registry_each _bs_rows_cb 2>/dev/null; }

# bs_uses CLIENT  Some operator (the Oracle and the Mailrooms included) runs
# on CLIENT, by the registry's resolution.
bs_uses() { bs_rows | awk -F'\t' -v c="$1" '$3 == c { f = 1 } END { exit !f }'; }

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

# bs_hook_cmd  The hook's command, every word shell-quoted: the digest
# script by absolute path, with the profile when it is not at its default
# place (both clients run the command through a shell).
bs_hook_cmd() {
  _hc_p=$(ao_profile_path)
  if [ "$_hc_p" = "${XDG_CONFIG_HOME:-$HOME/.config}/agent-operations/profile" ]; then
    bs_fr shell-quote "$AO_SCRIPTS/recover-context.sh"
  else
    printf 'env %s\n' "$(bs_fr shell-quote "AO_PROFILE=$_hc_p" "$AO_SCRIPTS/recover-context.sh")"
  fi
}

# bs_codex_toml_hooks  Hooks are defined in <codex home>/config.toml (a
# [hooks] table other than the trust records under [hooks.state]). Used only
# to choose where to add the hook; the check itself asks Codex.
bs_codex_toml_hooks() {
  grep -E '^[[:space:]]*\[\[?hooks(\]|\.)' "$(bs_codex_home)/config.toml" 2>/dev/null |
    grep -Evq '^[[:space:]]*\[hooks\.state(\]|\.)'
}

# bs_codex_hook_status CLI  Codex's verdict for the Oracle home, cached for
# one checklist pass: trusted HASH KEY SOURCE | untrusted | modified |
# disabled | none | error REASON.
bs_codex_hook_status() {
  if [ -z "${BS_HOOK_STATUS-}" ]; then
    BS_HOOK_STATUS=$(bs_fr codex-hook "$1" "$AO_HOME" "$AO_SCRIPTS/recover-context.sh" 60 2>/dev/null)
    [ -n "$BS_HOOK_STATUS" ] || BS_HOOK_STATUS="error	no answer from the reader"
  fi
  printf '%s\n' "$BS_HOOK_STATUS"
}

# bs_trust_steps CLI  The exact owner steps for trusting the hook.
bs_trust_steps() {
  printf '   1. In a terminal, run: "%s" -C "%s"\n' "$1" "$AO_HOME"
  printf '   2. Type /hooks, choose SessionStart, then Trust.\n'
  printf '   3. Leave the CLI with /exit. (The desktop app has no /hooks command.)\n'
}

# bs_hooks  Step 7: add the Codex hook on consent and guide its trust.
bs_hooks() {
  bs_uses codex || return 0
  _hk_d=$(bs_codex_home)
  ao_explain "7. The recovery hook on Codex" \
    "Codex runs ops/recover-context.sh at session start once it is one of its hooks" \
    "and you have trusted it in the Codex CLI. Adding it writes a file in Codex's own" \
    "folder, so it asks first; then it shows the exact trust steps and asks Codex itself."
  if ! _hk_cli=$(bs_codex_cli); then
    echo "   No working Codex CLI found (profile codex_cli, PATH, or inside the desktop app). Install it, or set codex_cli in $(ao_profile_path), then run bootstrap.sh again."
    return 0
  fi
  BS_HOOK_STATUS=''
  case $(bs_codex_hook_status "$_hk_cli") in
    trusted*) echo "   Codex reports the hook as trusted."; return 0 ;;
    disabled) printf '   The hook is disabled in Codex: run "%s" -C "%s", type /hooks, enable SessionStart, then /exit.\n' "$_hk_cli" "$AO_HOME"; return 0 ;;
    error*) echo "   Codex did not answer hooks/list ($(bs_codex_hook_status "$_hk_cli" | cut -f 2)); run bootstrap.sh again later."; return 0 ;;
    none)
      if [ -f "$_hk_d/hooks.json" ]; then
        echo "   $_hk_d/hooks.json exists without the digest: add a SessionStart hook to it that runs: $(bs_hook_cmd)"; return 0
      elif bs_codex_toml_hooks; then
        echo "   Your Codex hooks live in $_hk_d/config.toml: add a SessionStart hook there that runs: $(bs_hook_cmd) (Codex loads both places but warns; keep one)."; return 0
      fi
      printf '   Would write %s with one SessionStart hook: %s\n' "$_hk_d/hooks.json" "$(bs_hook_cmd)"
      if [ -n "${_yes-}" ] || ao_consent "Write $_hk_d/hooks.json?"; then
        mkdir -p "$_hk_d" && [ "$(bs_fr codex-hook-write "$_hk_d/hooks.json" "$(bs_hook_cmd)")" = written ] ||
          { echo "   could not write $_hk_d/hooks.json"; return 0; }
        echo "   written: $_hk_d/hooks.json"
      else
        echo "   Not written (no consent): run bootstrap.sh at a terminal or with --yes."; return 0
      fi ;;
  esac
  echo "   Trust it once:"
  bs_trust_steps "$_hk_cli"
  BS_HOOK_STATUS=''
  while :; do
    case $(bs_codex_hook_status "$_hk_cli") in trusted*) break ;; esac
    ao_pause "Trust the hook as above" || return 0
    BS_HOOK_STATUS=''
  done
  echo "   Codex reports the hook as trusted."
}

# ---------------------------------------------------------------- sign-in, restart, pins

# bs_signin_rows  Each client's CLI says whether you are signed in (the kit's
# headless steps use it). Model-free: `claude auth status --json`,
# `codex login status`.
bs_signin_rows() {
  if bs_uses claude; then
    _si_o=unknown
    if command -v claude >/dev/null 2>&1; then
      _si_o=$(ao_timeout 20 claude auth status --json 2>/dev/null | bs_fr claude-auth)
    fi
    case $_si_o in
      in) ao_step PASS sign-in-claude "the Claude CLI reports signed in" ;;
      out) ao_step TODO sign-in-claude "signed out: in a terminal run \"claude auth login\" and sign in yourself, and sign in to the Claude desktop app; the checklist then asks the CLI again" ;;
      *) if bs_marked sign-in; then ao_step PASS sign-in-claude "confirmed"
         else ao_step TODO sign-in-claude "no Claude CLI answered \"claude auth status\": install Claude Code, run \"claude auth login\", sign in to the desktop app (or, without the CLI: bootstrap.sh mark sign-in)"; fi ;;
    esac
  fi
  bs_uses codex || return 0
  if _si_c=$(bs_codex_cli); then
    _si_o=$(ao_timeout 20 "$_si_c" login status 2>&1)
    _si_r=$?
    if printf '%s' "$_si_o" | grep -Eiq 'not logged in|signed out'; then
      ao_step TODO sign-in-codex "signed out: in a terminal run \"$_si_c\" login and sign in yourself (the desktop app shares it); the checklist then asks again"
    elif [ "$_si_r" -eq 0 ]; then ao_step PASS sign-in-codex "the Codex CLI reports signed in"
    elif bs_marked sign-in; then ao_step PASS sign-in-codex "confirmed"
    else ao_step TODO sign-in-codex "\"$_si_c login status\" did not answer (exit $_si_r): sign in with \"$_si_c\" login, then run bootstrap.sh again"; fi
  elif bs_marked sign-in; then ao_step PASS sign-in-codex "confirmed"
  else ao_step TODO sign-in-codex "no working Codex CLI (profile codex_cli, PATH or the desktop app): install it and run \"codex login\", or set codex_cli in $(ao_profile_path)"; fi
}

# bs_app_name BUNDLE  The desktop app's name for people.
bs_app_name() {
  case $1 in
    com.openai.codex) echo "the Codex (ChatGPT) desktop app" ;;
    com.anthropic.claudefordesktop) echo "the Claude desktop app" ;;
    *) echo "$1" ;;
  esac
}

# bs_proc_start PID  The process's start time in epoch seconds, from its
# elapsed time ([[dd-]hh:]mm:ss); nothing when it cannot be read.
bs_proc_start() {
  _ps_e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
  [ -n "$_ps_e" ] || return 1
  _ps_s=$(printf '%s\n' "$_ps_e" | awk -F'[-:]' '{
    if (index($0, "-")) { d = $1; h = $2; m = $3; s = $4 }
    else if (NF == 3) { d = 0; h = $1; m = $2; s = $3 }
    else { d = 0; h = 0; m = $1; s = $2 }
    print ((d * 24 + h) * 60 + m) * 60 + s }')
  ao_is_uint "$_ps_s" || return 1
  echo $((AO_T_EPOCH - _ps_s))
}

# bs_restart_row  Each desktop app whose App Nap install.sh turned off must
# have started since (or not be running): its process start time against the
# time of the write (<state_dir>/host/app-nap.<bundle>).
bs_restart_row() {
  _rs_todo='' _rs_unknown='' _rs_ok=''
  for _rs_f in "$AO_STATE"/host/app-nap.*; do
    [ -f "$_rs_f" ] || continue
    _rs_id=${_rs_f##*/app-nap.}
    _rs_at=$(cat "$_rs_f" 2>/dev/null)
    ao_is_uint "$_rs_at" || continue
    _rs_pid=$(_ao_mr_app_pid "$_rs_id")
    if [ "$_rs_pid" = none ]; then _rs_ok="$_rs_ok $_rs_id"
    elif [ -n "$_rs_pid" ] && _rs_st=$(bs_proc_start "$_rs_pid"); then
      if [ "$_rs_st" -gt "$_rs_at" ]; then _rs_ok="$_rs_ok $_rs_id"; else _rs_todo="$_rs_todo $_rs_id"; fi
    else _rs_unknown="$_rs_unknown $_rs_id"; fi
  done
  if [ -n "$_rs_todo" ]; then
    _rs_n=''
    for _rs_id in $_rs_todo; do _rs_n="${_rs_n:+$_rs_n and }$(bs_app_name "$_rs_id")"; done
    ao_step TODO restart-apps "quit $_rs_n (Cmd-Q, not just the window) and open it again, so App Nap stays off; the checklist reads the app's start time"
  elif [ -n "$_rs_unknown" ] && ! bs_marked restart-apps; then
    ao_step TODO restart-apps "quit and reopen$(for _rs_id in $_rs_unknown; do printf ' %s' "$(bs_app_name "$_rs_id")"; done) once; its start time cannot be read here, so then: bootstrap.sh mark restart-apps"
  elif [ -n "$_rs_ok" ]; then ao_step PASS restart-apps "every app started after App Nap was turned off, or is not running"
  else ao_step PASS restart-apps "no App Nap change waits for a restart"; fi
}

# bs_pin_rows  Codex: the threads that must be pinned (the active Codex rows
# with a thread id: the Oracle when it runs on Codex, operators, the
# Mailroom) are read back from the desktop app's own state file
# (<codex home>/.codex-global-state.json, "pinned-thread-ids"; undocumented,
# read only). Operators are resolved the registry's one way (bs_rows).
# Claude: nothing on disk shows the sidebar, so the step lists
# exactly what to pin and waits for `bootstrap.sh mark pins`.
bs_pin_rows() {
  if bs_uses codex; then
    _pn_out=$(bs_rows | bs_fr codex-pins "$(bs_codex_home)/.codex-global-state.json")
    case $_pn_out in
      ok*) ao_step PASS pins-codex "the Codex app shows all ${_pn_out#*"$AO_TAB"} active thread(s) pinned" ;;
      missing*) ao_step TODO pins-codex "in the Codex app, pin: ${_pn_out#*"$AO_TAB"} (right-click the thread, Pin); the checklist reads the app's pinned list" ;;
      none) ao_step PASS pins-codex "no Codex thread recorded yet to pin" ;;
      *) if bs_marked pins; then ao_step PASS pins-codex "confirmed"
         else ao_step TODO pins-codex "pin the Oracle (if on Codex), the active Codex operators and the Mailroom in the Codex app; its pinned list cannot be read here, so then: bootstrap.sh mark pins"; fi ;;
    esac
  fi
  bs_uses claude || return 0
  if bs_marked pins; then ao_step PASS pins-claude "confirmed"; return; fi
  _pn_on=$(bs_rows | awk -F'\t' '$3 == "claude" && $1 != "Mailroom" { printf "%s\"%s\"", (n++ ? ", " : ""), $1 }')
  _pn_off=$(bs_rows | awk -F'\t' '$3 != "claude" && $1 != "Mailroom" { printf "%s\"%s\"", (n++ ? ", " : ""), $1 }')
  ao_step TODO pins-claude "in the Claude app: pin ${_pn_on:-the Oracle}; the Mailroom may nest under the Oracle; ${_pn_off:+put $_pn_off in a sidebar section named \"Inactive Operators\"; }then: bootstrap.sh mark pins (nothing on disk shows the Claude sidebar)"
}

# bs_hook_rows  The checklist rows for both recovery hooks.
bs_hook_rows() {
  if bs_uses claude; then
    _hr_s=$(bs_claude_settings)
    _hr_v=$(bs_fr claude-hook "$_hr_s" "$AO_SCRIPTS/recover-context.sh")
    if [ "${_hr_v%%"$AO_TAB"*}" = ok ]; then ao_step PASS hook-claude "a SessionStart hook for compact and resume in $_hr_s runs the digest"
    elif bs_marked hooks; then ao_step PASS hook-claude "confirmed (registered elsewhere)"
    else ao_step TODO hook-claude "${_hr_v#*"$AO_TAB"}: add to $_hr_s (merge with what is there): $(bs_fr claude-hook-snippet "$(bs_hook_cmd)"); the checklist then finds it (registered elsewhere: bootstrap.sh mark hooks)"; fi
  fi
  bs_uses codex || return 0
  _hr_d=$(bs_codex_home)
  _hr_m=$(bs_marks_file)
  if ! _hr_cli=$(bs_codex_cli); then
    ao_step TODO hook-codex "no working Codex CLI to ask (profile codex_cli, PATH or the desktop app): install it, or set codex_cli in $(ao_profile_path)"
    return
  fi
  _hr_st=$(bs_codex_hook_status "$_hr_cli")
  case $_hr_st in
    none) ao_step TODO hook-codex "Codex has no SessionStart hook for this home that runs the digest: bootstrap.sh adds it on your yes (or add $(bs_hook_cmd) to $_hr_d/hooks.json, or to [hooks] in config.toml)"; return ;;
    disabled) ao_step TODO hook-codex "the hook is disabled in Codex: run \"$_hr_cli\" -C \"$AO_HOME\", type /hooks, enable SessionStart, then /exit"; return ;;
    untrusted | modified)
      ao_step TODO hook-codex "trust it$([ "$_hr_st" = modified ] && printf ' again (it changed since it was trusted)') in the Codex CLI: run \"$_hr_cli\" -C \"$AO_HOME\", type /hooks, choose SessionStart, Trust, then /exit (the desktop app has no /hooks); the checklist then asks Codex"
      return ;;
    error*) ao_step TODO hook-codex "Codex did not answer hooks/list (${_hr_st#*"$AO_TAB"}); run bootstrap.sh again"; return ;;
  esac
  # trusted HASH KEY SOURCE: a pass is bound to this hash and this home.
  _hr_h=$(printf '%s\n' "$_hr_st" | cut -f 2)
  if [ "$(ao_st_get "$_hr_m" hook-codex-verified)" = "$_hr_h $AO_HOME" ]; then
    ao_step PASS hook-codex "trusted (Codex's hooks/list); a fresh isolated Codex run quoted the digest for this hook"
    return
  fi
  if [ -n "${BS_READONLY-}" ] || [ -n "${BS_HOOK_TRIED-}" ]; then
    ao_step WAIT hook-codex "trusted; bootstrap.sh (not status) runs one isolated read-only Codex check that the digest arrives"
    return
  fi
  BS_HOOK_TRIED=1
  # The probe is boxed like every unattended Codex run (lib/vendor-codex.sh,
  # K-25): plugins and apps off, every listed tool server off, failing
  # closed when the list cannot be read; read-only, ephemeral.
  ao_vendor_use codex || { ao_step TODO hook-codex "trusted, but the Codex vendor helpers did not load"; return; }
  R_CMD=$_hr_cli R_MCP=''
  _hr_e=$(ao_tmp hook-check-err)
  if ! _hr_off=$(_vendor_codex_mcp_args "$AO_HOME" 2>"$_hr_e"); then
    ao_step TODO hook-codex "trusted, but the check did not run: $(head -n 1 "$_hr_e") (it runs only with every Codex tool server off)"
    return
  fi
  _hr_o=$(ao_tmp hook-check)
  # shellcheck disable=SC2086 # fixed words; tool-server names validated by the vendor helper
  ao_timeout 300 "$_hr_cli" $_VX_OFF exec --ephemeral --skip-git-repo-check -s read-only -C "$AO_HOME" -o "$_hr_o" $_hr_off \
    "Reply with only the first line of the recovery digest your session start hook gave you, exactly as given, or NONE if you received none." >/dev/null 2>&1
  if grep -q '^## Oracle recovery (' "$_hr_o" 2>/dev/null; then
    ao_st_set "$_hr_m" hook-codex-verified "$_hr_h $AO_HOME"
    ao_step PASS hook-codex "trusted (Codex's hooks/list); a fresh isolated read-only Codex run quoted the digest's first line"
  else
    ao_step TODO hook-codex "trusted, but a fresh isolated read-only Codex run did not quote the digest (it said: $(head -n 1 "$_hr_o" 2>/dev/null | cut -c 1-80)); check the hook's command, then run bootstrap.sh again"
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
  bs_attribution_row
  bs_signin_rows
  bs_restart_row
  bs_pin_rows
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
