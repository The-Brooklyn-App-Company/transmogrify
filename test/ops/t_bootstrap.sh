#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_bootstrap.sh - the guided first run, unattended (--yes): the Oracle
# home, the profile, the host, the toehold, the Oracle lock, and the
# checklist that ends with a test note's delivery.
. "$(dirname -- "$0")/lib.sh"

fresh() {
  AO_PROFILE=$T/cfg/profile AO_APPS_DIR=$T/Applications
  GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
  GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
  export AO_PROFILE AO_APPS_DIR GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  # Fakes: defaults and launchctl only record; the Codex app bundle holds a
  # node and the app tool server.
  mkdir -p "$T/defaults" "$T/loaded"
  cat >"$T/bin/defaults" <<EOF
#!/bin/sh
d=$T/defaults
case \$1 in
  read) [ -e "\$d/\$2" ] || exit 1; [ \$# -eq 2 ] && exit 0; cat "\$d/\$2.\$3" 2>/dev/null || exit 1 ;;
  write) : >"\$d/\$2"; echo 1 >"\$d/\$2.\$3"; echo "write \$*" >>"\$d/log" ;;
esac
EOF
  cat >"$T/bin/launchctl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/launchctl.log"
case \$1 in
  print) [ -e "$T/loaded/\${2##*/}" ] ;;
  bootstrap) f=\${3##*/}; : >"$T/loaded/\${f%.plist}" ;;
  bootout) rm -f "$T/loaded/\${2##*/}" ;;
esac
EOF
  chmod +x "$T/bin/defaults" "$T/bin/launchctl"
  r=$T/Applications/Codex.app/Contents/Resources
  mkdir -p "$r/bin" "$r/plugins/codex-app-tools"
  printf '#!/bin/sh\n' >"$r/bin/node" && chmod +x "$r/bin/node"
  : >"$r/plugins/codex-app-tools/server.mjs"
}

# The profile's PATH must find the fakes first: never the real defaults or
# launchctl (a test must not touch the real launchd domain).
SETS='--set relay_claude_model=small-c --set worker_model=small-x --set reviewer_model=big-x
--set implementer_claude_model=big-c --set implementer_codex_model=big-x
--set reviewer_claude_model=big-c --set reviewer_codex_model=big-x'

test_first_run_sets_up_everything_then_lists_the_human_steps() {
  [ "$(uname -s)" = Darwin ] || { echo "    (skipped: launchd units are macOS)"; return 0; }
  fresh
  # shellcheck disable=SC2086 # deliberate split of the option list
  run bootstrap.sh --yes --client claude --home "$T/ops/oracle" --tz Etc/UTC --set "path=$T/bin:/usr/bin:/bin" $SETS
  assert_rc 1
  assert_has "$T/launchctl.log" "bootstrap gui/"
  # The choices are printed, the home and profile exist, the host is set.
  assert_has "$T/out" "Client you start the Oracle on (claude or codex): claude"
  assert_file "$T/ops/oracle/operators/REGISTRY.tsv"
  assert_has "$AO_PROFILE" "owner_tz=Etc/UTC"
  assert_has "$AO_PROFILE" "implementer_codex_model=big-x"
  assert_has "$AO_PROFILE" "bridge_codex_server=$T/Applications/Codex.app/Contents/Resources/plugins/codex-app-tools/server.mjs"
  assert_has "$AO_PROFILE" "bridge_codex_node=$T/Applications/Codex.app/Contents/Resources/bin/node"
  assert_has "$T/defaults/log" "write com.openai.codex NSAppSleepDisabled -bool YES"
  assert_file "$T/user/Library/LaunchAgents/local.agent-operations.relay.plist"
  assert_has "$T/ops/mailroom-claude/AGENTS.md" "Mailroom (Claude): your whole duty"
  assert_has "$T/ops/oracle/operators/REGISTRY.tsv" "mailroom-codex${TAB}Mailroom${TAB}"
  # The toehold: the other client's files in every home.
  assert_has "$T/ops/oracle/operator.conf" "session.codex="
  # The checklist: what a person does, each with its check.
  assert_has "$T/out" "PASS  profile"
  assert_has "$T/out" "TODO  oracle        start a claude session in $T/ops/oracle"
  assert_has "$T/out" "TODO  oracle-lock"
  assert_has "$T/out" "TODO  sign-in"
  assert_has "$T/out" "TODO  claude-mailroom in Claude, start a session in"
  assert_has "$T/out" "TODO  codex-mailroom"
  assert_has "$T/out" "WAIT  round-trip"
  # Again, with the Oracle's session: recorded and the lock taken (unattended
  # runs take the confirmed default).
  run bootstrap.sh --yes --oracle-session sid-oracle --home "$T/ops/oracle"
  assert_rc 1
  assert_has "$T/ops/oracle/operators/ORACLE-LOCK" "holder=claude"
  assert_has "$T/out" "PASS  oracle-lock   claude"
  # The person's steps, then the proof.
  run operator.sh session mailroom-claude sid-bridge
  run operator.sh session mailroom-codex thread-bridge
  for m in sign-in restart-apps pins hooks; do run bootstrap.sh mark "$m"; assert_rc 0; done
  echo none >"$T/apps/com.openai.codex" && echo none >"$T/apps/com.anthropic.claudefordesktop"
  # The Codex hook: written by the --yes run above, trusted in Codex's own
  # record, then checked by one read-only run (the fake quotes the digest).
  assert_has "$CODEX_HOME/hooks.json" "recover-context.sh"
  printf '[hooks.state."%s/hooks.json:session_start:0:0"]\ntrusted_hash = "sha256:x"\nenabled = true\n' "$CODEX_HOME" >>"$CODEX_HOME/config.toml"
  FAKE_OUTPUT='## Oracle recovery (2026-11-19). The files win over any summary.'
  export FAKE_OUTPUT
  sleep 300 >/dev/null 2>&1 &
  live=$!
  mkdir -p "$T/ops/oracle/inbox/.mailroom/codex/.watcher"
  printf '2026-11-19T00:00:00Z %s\n' "$live" >"$T/ops/oracle/inbox/.mailroom/codex/.watcher/heartbeat"
  # status only reads: no test note goes out from it
  run bootstrap.sh status
  assert_rc 1
  assert_has "$T/out" "WAIT  round-trip    no test note sent yet (status only reads"
  ! ls "$T/ops/oracle/inbox/oracle"/*bootstrap-check.md >/dev/null 2>&1 || _fail "status sent a test note"
  run bootstrap.sh --yes --oracle-session sid-oracle --home "$T/ops/oracle"
  run bootstrap.sh status
  assert_rc 1
  assert_has "$T/out" "PASS  hook-codex    trusted; a fresh Codex run received the digest"
  assert_has "$T/out" "PASS  hook-claude   confirmed"
  assert_has "$T/out" "PASS  codex-watcher armed"
  assert_has "$T/out" "WAIT  round-trip    a test note went to the Oracle"
  ls "$T/ops/oracle/inbox/oracle"/*bootstrap-check.md >/dev/null 2>&1 || _fail "no test note"
  # Only a delivered ring that lists the test note counts.
  d=$T/ops/oracle/inbox/.mailroom/claude/delivered
  mkdir -p "$d"
  printf -- '- x-oracle-other-note.md\n' >"$d/sid-oracle--oracle-1.md"
  printf '2026-11-19T00:00:00Z\t%s\tsid-oracle--oracle-1.md\tt2-bridge\tsend\tok\t900\t-\n' "$(($(date +%s) + 5))" >>"$d/log.tsv"
  run bootstrap.sh status
  assert_has "$T/out" "WAIT  round-trip"
  tn=$(ls "$T/ops/oracle/inbox/oracle"/*bootstrap-check.md)
  tn=${tn##*/}
  printf -- '- 20261119T000000-oracle-%s\n' "$tn" >"$d/sid-oracle--oracle-2.md"
  printf '2026-11-19T00:00:00Z\t%s\tsid-oracle--oracle-2.md\tt2-bridge\tsend\tok\t900\t-\n' "$(($(date +%s) + 5))" >>"$d/log.tsv"
  run bootstrap.sh status
  kill "$live" 2>/dev/null
  assert_rc 0
  assert_has "$T/out" "PASS  round-trip    the test note reached the Oracle"
}

test_choices_are_validated_and_marks_are_fixed() {
  fresh
  run bootstrap.sh --yes --client claude --home relative/path
  assert_rc 2
  assert_no_file "$AO_PROFILE"
  run bootstrap.sh --yes --client other --home "$T/ops/oracle"
  assert_rc 2
}

test_grants_are_written_into_client_settings_only_on_consent() {
  [ "$(uname -s)" = Darwin ] || { echo "    (skipped: launchd units are macOS)"; return 0; }
  fresh
  mkdir -p "$T/claude"
  printf '{"model": "x"}\n' >"$T/claude/settings.json"
  # shellcheck disable=SC2086 # deliberate split of the option list
  run bootstrap.sh --yes --client claude --home "$T/ops/oracle" --tz Etc/UTC --set "path=$T/bin:/usr/bin:/bin" $SETS \
    --set "grants_claude_settings=$T/claude/settings.json" --set "grants_codex_bin=$TESTS_DIR/fakes/fake-codex-grants"
  sed '/\[only: beta\]/d' "$TESTS_DIR/fixtures/GRANTS.example.md" >"$T/ops/oracle/operators/GRANTS.md"
  # No terminal and no --yes: not consent; nothing is written.
  run bootstrap.sh --home "$T/ops/oracle"
  assert_has "$T/out" "6. Approvals that follow an operator"
  assert_has "$T/out" "Not written (no consent)"
  assert_lacks "$T/claude/settings.json" "[grant:"
  # --yes given: written.
  run bootstrap.sh --yes --home "$T/ops/oracle"
  assert_has "$T/claude/settings.json" "[grant:own-merges]"
  assert_has "$T/claude/settings.json" '"model": "x"'
}

test_codex_hook_is_written_on_consent_trusted_by_the_owner_then_checked() {
  [ "$(uname -s)" = Darwin ] || { echo "    (skipped: launchd units are macOS)"; return 0; }
  fresh
  # shellcheck disable=SC2086 # deliberate split of the option list
  run bootstrap.sh --client claude --home "$T/ops/oracle" --tz Etc/UTC --set "path=$T/bin:/usr/bin:/bin" $SETS
  # No terminal, no --yes: nothing is written; the step says how.
  assert_no_file "$CODEX_HOME/hooks.json"
  assert_has "$T/out" "Not written (no consent)"
  assert_has "$T/out" "TODO  hook-codex    bootstrap.sh writes $CODEX_HOME/hooks.json on your yes"
  assert_has "$T/out" "TODO  hook-claude   add to $CLAUDE_CONFIG_DIR/settings.json"
  # --yes: written, and the exact trust steps name the CLI and the home.
  run bootstrap.sh --yes --home "$T/ops/oracle"
  assert_has "$CODEX_HOME/hooks.json" '"matcher": "startup|resume|compact|fork"'
  assert_has "$CODEX_HOME/hooks.json" "$SCRIPTS/recover-context.sh"
  assert_has "$T/out" "1. In a terminal, run: \"$T/bin/codex\" -C \"$T/ops/oracle\""
  assert_has "$T/out" "2. Type /hooks, choose SessionStart, then Trust."
  assert_has "$T/out" "TODO  hook-codex    trust it once in the Codex CLI"
  # A record for another file, or without enabled = true, is not trust.
  printf '[hooks.state."/elsewhere/hooks.json:session_start:0:0"]\ntrusted_hash = "sha256:x"\nenabled = true\n' >"$CODEX_HOME/config.toml"
  printf '[hooks.state."%s/hooks.json:session_start:0:0"]\ntrusted_hash = "sha256:x"\nenabled = false\n' "$CODEX_HOME" >>"$CODEX_HOME/config.toml"
  run bootstrap.sh status
  assert_has "$T/out" "TODO  hook-codex    trust it once"
  # Trusted: status only reads; bootstrap.sh runs the one check, which fails
  # when the run does not quote the digest, and passes when it does.
  printf '[hooks.state."%s/hooks.json:session_start:0:0"]\ntrusted_hash = "sha256:x"\nenabled = true\n' "$CODEX_HOME" >>"$CODEX_HOME/config.toml"
  run bootstrap.sh status
  assert_has "$T/out" "WAIT  hook-codex    trusted; bootstrap.sh (not status) runs one"
  FAKE_OUTPUT=NONE
  export FAKE_OUTPUT
  run bootstrap.sh --yes --home "$T/ops/oracle"
  assert_has "$T/out" "TODO  hook-codex    trusted, but a fresh read-only Codex run did not quote the digest (it said: NONE)"
  assert_has "$FAKE_LOG" "arg: --ephemeral"
  assert_has "$FAKE_LOG" "arg: read-only"
  FAKE_OUTPUT='## Oracle recovery (2026-11-19). The files win.'
  run bootstrap.sh --yes --home "$T/ops/oracle"
  assert_has "$T/out" "PASS  hook-codex    trusted; a fresh read-only Codex run quoted the digest's first line"
  # An existing hooks.json is never rewritten.
  rm "$CODEX_HOME/hooks.json"
  printf '{"hooks": {}}\n' >"$CODEX_HOME/hooks.json"
  run bootstrap.sh --yes --home "$T/ops/oracle"
  assert_eq "$(cat "$CODEX_HOME/hooks.json")" '{"hooks": {}}'
  assert_has "$T/out" "exists without the digest"
}

test_sign_in_restart_and_pins_are_checked_not_just_marked() {
  [ "$(uname -s)" = Darwin ] || { echo "    (skipped: launchd units are macOS)"; return 0; }
  fresh
  # shellcheck disable=SC2086 # deliberate split of the option list
  run bootstrap.sh --yes --client claude --home "$T/ops/oracle" --tz Etc/UTC --set "path=$T/bin:/usr/bin:/bin" $SETS
  st=$(sed -n 's/^state_dir=//p' "$AO_PROFILE" | tail -n 1)
  [ -n "$st" ] || st=$T/user/.local/state/agent-operations
  # install.sh recorded when it turned App Nap off.
  [ -f "$st/host/app-nap.com.openai.codex" ] || _fail "no App Nap stamp"
  # Sign-in: each CLI is asked. Signed out first, then signed in.
  mkdir -p "$T/fake"
  cp "$TESTS_DIR/fakes/fake-agent" "$T/fake/claude"
  cp "$TESTS_DIR/fakes/fake-agent" "$T/fake/codex"
  printf '#!/bin/sh\nif [ "$1 $2" = "auth status" ]; then cat "%s"; exit 0; fi\nexec "%s" "$@"\n' "$T/claude-auth" "$T/fake/claude" >"$T/bin/claude"
  printf '#!/bin/sh\nif [ "$1 $2" = "login status" ]; then cat "%s"; exit 0; fi\nexec "%s" "$@"\n' "$T/codex-login" "$T/fake/codex" >"$T/bin/codex"
  chmod +x "$T/bin/claude" "$T/bin/codex"
  printf '{"loggedIn": false}\n' >"$T/claude-auth"
  printf 'Not logged in\n' >"$T/codex-login"
  # Restart: the Codex app runs a process older than the App Nap write; the
  # Claude app is not running.
  sleep 300 >/dev/null 2>&1 &
  app=$!
  echo "$app" >"$T/apps/com.openai.codex"
  echo none >"$T/apps/com.anthropic.claudefordesktop"
  echo $(($(date +%s) + 100)) >"$st/host/app-nap.com.openai.codex"
  # Pins: the bridge thread is active on Codex; the app's state lists no pin.
  run operator.sh session mailroom-codex thread-bridge
  printf '{"pinned-thread-ids": ["other"]}\n' >"$CODEX_HOME/.codex-global-state.json"
  run bootstrap.sh status
  assert_has "$T/out" 'TODO  sign-in-claude signed out: in a terminal run "claude auth login"'
  assert_has "$T/out" "TODO  sign-in-codex signed out: in a terminal run"
  assert_has "$T/out" "TODO  restart-apps  quit the Codex (ChatGPT) desktop app (Cmd-Q"
  assert_has "$T/out" 'TODO  pins-codex    in the Codex app, pin: Mailroom'
  assert_has "$T/out" 'TODO  pins-claude   in the Claude app: pin'
  # Each fixed: the checks pass on their own evidence, with no marks.
  printf '{"loggedIn": true}\n' >"$T/claude-auth"
  printf 'Logged in using ChatGPT\n' >"$T/codex-login"
  echo $(($(date +%s) - 100)) >"$st/host/app-nap.com.openai.codex"
  printf '{"pinned-thread-ids": ["other", "thread-bridge"]}\n' >"$CODEX_HOME/.codex-global-state.json"
  run bootstrap.sh status
  kill "$app" 2>/dev/null
  assert_has "$T/out" "PASS  sign-in-claude the Claude CLI reports signed in"
  assert_has "$T/out" "PASS  sign-in-codex the Codex CLI reports signed in"
  assert_has "$T/out" "PASS  restart-apps  every app started after App Nap was turned off"
  assert_has "$T/out" "PASS  pins-codex    the Codex app shows all 1 active thread(s) pinned"
  # The Claude sidebar has no readable state: only the mark passes it.
  assert_has "$T/out" "TODO  pins-claude"
  run bootstrap.sh mark pins
  run bootstrap.sh status
  assert_has "$T/out" "PASS  pins-claude   confirmed"
}

ao_test_main "$0"
