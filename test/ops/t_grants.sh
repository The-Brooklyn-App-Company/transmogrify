#!/bin/sh
# shellcheck disable=SC2034
# t_grants.sh - grants file, Claude and Codex renderers, three-state check,
# accept and the switch gate. Fakes only: a fixture settings file and a fake
# Codex CLI (fakes/fake-codex-grants); no real client config is touched.
. "$(dirname -- "$0")/lib.sh"

gsetup() {
  cp "$TESTS_DIR/fixtures/GRANTS.example.md" "$T/home/operators/GRANTS.md"
  profile_set grants_codex_bin "$TESTS_DIR/fakes/fake-codex-grants"
  mkdir -p "$T/claude"
  printf '{\n  "model": "x",\n  "autoMode": {\n    "allow": [\n      "Unrelated rule kept as is"\n    ]\n  }\n}\n' \
    >"$T/claude/settings.json"
}
settings() { cat "$T/claude/settings.json"; }
policy_sha() { sed -n 's/.*policy_sha256=\([0-9a-f]*\).*/\1/p' "$1"; }

test_validate_accepts_the_example_and_names_every_grant() {
  gsetup
  run grants.sh validate
  assert_rc 0
  assert_has "$T/out" "own-merges, cheap-calls, notes-only"
}

test_validate_refuses_a_quote_that_is_not_verbatim() {
  gsetup
  sed -i.bak '/^- words:/s/and tell me after\./and tell me later./' "$T/home/operators/GRANTS.md"
  run grants.sh validate
  assert_rc 2
  assert_has "$T/err" "quote not verbatim in the Claude text"
}

test_validate_refuses_an_unknown_actor() {
  gsetup
  sed -i.bak 's/^- actors: operators$/- actors: gamma/' "$T/home/operators/GRANTS.md"
  run grants.sh validate
  assert_rc 2
  assert_has "$T/err" "actor 'gamma' is not operators, oracle or a registry key"
}

test_validate_refuses_a_grant_without_an_expiry() {
  gsetup
  awk '!d && /^- expires: never$/ { d = 1; next } { print }' "$T/home/operators/GRANTS.md" >"$T/g" &&
    mv "$T/g" "$T/home/operators/GRANTS.md"
  run grants.sh validate
  assert_rc 2
  assert_has "$T/err" "grant own-merges: expires: must be YYYY-MM-DD or never"
}

test_render_claude_tags_entries_and_keeps_everything_else() {
  gsetup
  run grants.sh render-claude
  assert_rc 0
  assert_has "$T/out" "claude: added own-merges"
  assert_has "$T/claude/settings.json" '"Unrelated rule kept as is"'
  assert_has "$T/claude/settings.json" '[grant:own-merges]'
  assert_has "$T/claude/settings.json" '[grant:notes-only]'
  assert_has "$T/claude/settings.json" '"model": "x"'
  [ "$(find "$T/claude" -name 'settings.json.bak-*-grants' | wc -l | tr -d ' ')" = 1 ] || _fail "one backup"
  run grants.sh render-claude
  assert_rc 0
  assert_has "$T/out" "rendered, no change (3 managed entries"
}

test_render_claude_refuses_an_edited_untagged_copy() {
  gsetup
  printf '{"autoMode": {"allow": ["Own Reviewed Merges (edited by hand): anything goes"]}}\n' >"$T/claude/settings.json"
  cp "$T/claude/settings.json" "$T/before"
  run grants.sh render-claude
  assert_rc 1
  assert_has "$T/err" "untagged entry 'Own Reviewed Merges' differs from grant own-merges"
  cmp -s "$T/before" "$T/claude/settings.json" || _fail "settings changed"
}

test_render_claude_removes_an_expired_grant() {
  gsetup
  run grants.sh render-claude
  sed -i.bak 's/^- expires: 2099-12-31$/- expires: 2020-01-01/' "$T/home/operators/GRANTS.md"
  run grants.sh check --side claude --no-resolve
  assert_rc 1
  assert_has "$T/out" "cheap-calls expired on 2020-01-01"
  run grants.sh render-claude
  assert_rc 0
  assert_has "$T/out" "removed cheap-calls (expired)"
  assert_lacks "$T/claude/settings.json" '[grant:cheap-calls]'
}

test_render_codex_writes_baseline_then_clauses_per_actor() {
  gsetup
  printf 'model = "m"\n\n[projects."/x"]\ntrust_level = "trusted"\n' >"$T/proj/alpha/.codex-pre"
  mkdir -p "$T/proj/alpha/.codex"
  mv "$T/proj/alpha/.codex-pre" "$T/proj/alpha/.codex/config.toml"
  run grants.sh render-codex --all
  assert_rc 0
  assert_has "$T/out" "codex alpha:"
  assert_has "$T/out" "written and resolved"
  a=$T/proj/alpha/.codex/config.toml b=$T/proj/beta/.codex/config.toml o=$T/home/.codex/config.toml
  assert_has "$a" 'model = "m"'
  assert_has "$a" 'trust_level = "trusted"'
  assert_has "$a" "Example reviewer policy (fictional, for tests)."
  assert_has "$a" "### Grant \`own-merges\`: Own Reviewed Merges"
  assert_has "$a" "### Grant \`cheap-calls\`"
  assert_has "$a" "- Production deploys."
  assert_lacks "$a" "Merging the release branch"
  assert_has "$b" "Merging the release branch"
  # cheap-calls includes own-merges' list, but never a [no-include] bullet
  assert_has "$o" "### Grant \`cheap-calls\`"
  assert_lacks "$o" "own-merges"
  assert_lacks "$o" "Repositories the operator does not own"
  assert_lacks "$o" "Oracle Notes"
  run grants.sh check --side codex
  assert_rc 0
  assert_has "$T/out" "codex alpha: rendered OK"
  assert_has "$T/out" "resolved OK (config/read: policy"
}

test_render_codex_refuses_an_unknown_baseline() {
  gsetup
  printf 'A different reviewer policy.\n' >"$T/other-policy"
  FAKE_CODEX_BASELINE=$T/other-policy
  export FAKE_CODEX_BASELINE
  run grants.sh render-codex --all
  assert_rc 1
  assert_has "$T/err" "unknown baseline policy sha256"
  assert_no_file "$T/proj/alpha/.codex/config.toml"
  run grants.sh check --side codex --no-resolve
  assert_rc 1
  assert_has "$T/out" "unknown baseline"
}

test_render_codex_refuses_an_unmanaged_auto_review_table() {
  gsetup
  mkdir -p "$T/proj/alpha/.codex"
  printf '[auto_review]\npolicy = "mine"\n' >"$T/proj/alpha/.codex/config.toml"
  run grants.sh render-codex --actor alpha
  assert_rc 1
  assert_has "$T/err" "an unmanaged auto_review setting"
  assert_has "$T/proj/alpha/.codex/config.toml" 'policy = "mine"'
}

test_render_codex_rolls_back_when_not_resolved() {
  gsetup
  mkdir -p "$T/proj/alpha/.codex"
  printf 'model = "m"\n' >"$T/proj/alpha/.codex/config.toml"
  FAKE_CODEX_UNTRUSTED=1
  export FAKE_CODEX_UNTRUSTED
  run grants.sh render-codex --actor alpha
  assert_rc 1
  assert_has "$T/err" "disabled (is the project trusted?)"
  assert_has "$T/err" "rolled back to the previous file"
  assert_eq "$(cat "$T/proj/alpha/.codex/config.toml")" 'model = "m"'
}

test_render_codex_refuses_a_link_into_the_codex_user_folder() {
  gsetup
  mkdir -p "$T/proj/alpha"
  ln -s "$T/codex" "$T/proj/alpha/.codex"
  run grants.sh render-codex --actor alpha --no-readback
  assert_rc 1
  assert_has "$T/err" "is a symlink"
  assert_no_file "$T/codex/config.toml"
}

test_check_reports_stale_and_managed_layers() {
  gsetup
  run grants.sh render-codex --all
  FAKE_CODEX_STALE=1
  export FAKE_CODEX_STALE
  run grants.sh check --side codex --actor alpha
  assert_rc 1
  assert_has "$T/out" "resolved NO (effective auto_review.policy sha"
  unset FAKE_CODEX_STALE
  FAKE_CODEX_MANAGED=1
  export FAKE_CODEX_MANAGED
  run grants.sh check --side codex --actor alpha --findings
  assert_rc 1
  assert_has "$T/out" "a managed layer sets auto_review (mdm)"
}

test_check_flags_a_hand_edit_of_the_rendered_policy() {
  gsetup
  run grants.sh render-codex --all
  sed -i.bak 's/Production deploys\./Production deploys, sometimes./' "$T/proj/alpha/.codex/config.toml"
  run grants.sh check --side codex --actor alpha --no-resolve
  assert_rc 1
  assert_has "$T/out" "rendered NO (disk policy"
}

test_accept_needs_rendered_and_resolved_and_follows_the_hash() {
  gsetup
  run grants.sh accept codex alpha 'fresh thread refused a force-push, allowed a reviewed merge'
  assert_rc 1
  run grants.sh render-codex --all
  run grants.sh accept codex alpha 'fresh thread refused a force-push, allowed a reviewed merge'
  assert_rc 0
  run grants.sh check --side codex --actor alpha
  assert_has "$T/out" "accepted OK"
  # a changed grant makes the probe pending again
  sed -i.bak 's/^- Production deploys\.$/- Production deploys or promotions./' "$T/home/operators/GRANTS.md"
  run grants.sh render-codex --all
  run grants.sh check --side codex --actor alpha --findings
  assert_rc 0
  assert_has "$T/out" "codex alpha accepted-state probe pending"
}

test_out_dir_proof_render_leaves_homes_alone() {
  gsetup
  run grants.sh render-codex --all --out-dir "$T/proof"
  assert_rc 0
  assert_file "$T/proof/alpha/.codex/config.toml"
  assert_no_file "$T/proj/alpha/.codex/config.toml"
  assert_lacks "$FAKE_LOG" "app-server"
}

test_gate_refuses_until_the_target_side_matches() {
  gsetup
  run grants.sh check --gate alpha codex
  assert_rc 1
  assert_has "$T/out" "grants gate codex alpha: REFUSED"
  run grants.sh render-codex --all
  run grants.sh check --gate alpha codex
  assert_rc 0
  run grants.sh check --gate alpha claude
  assert_rc 1
  run grants.sh render-claude
  run grants.sh check --gate alpha claude
  assert_rc 0
}

test_baseline_prints_hashes_never_the_text() {
  gsetup
  run grants.sh baseline
  assert_rc 0
  assert_has "$T/out" "policy sha256 f5f98f09e5996039cf6cb3671f5370513f8c3ea63c5c148ecbc50ffff03aad82, 88 bytes"
  assert_lacks "$T/out" "Deny anything"
  run grants.sh baseline --write "$T/read-me.md"
  assert_rc 0
  assert_has "$T/read-me.md" "Deny anything that leaves the sandbox."
  run grants.sh baseline --write "$T/read-me.md"
  assert_rc 2
}

test_no_command_prints_config_or_policy_text() {
  gsetup
  run grants.sh render-codex --all
  run grants.sh check
  assert_lacks "$T/out" "Deny anything"
  assert_lacks "$T/out" "Merge your own reviewed"
}

test_switch_is_refused_until_the_target_side_matches() {
  gsetup
  run lane.sh switch alpha --to codex --session thread-new
  assert_rc 5
  assert_has "$T/err" "the standing grants on codex do not match the grants file"
  assert_no_file "$T/state/switch/alpha"
  run grants.sh render-codex --all
  run lane.sh switch alpha --to codex --session thread-new
  assert_rc 0
  run lane.sh verify alpha
  assert_has "$T/out" "PASS  approvals    grants gate codex alpha: ok"
  # a later edit of the rendered policy holds the routing back
  sed -i.bak 's/Production deploys\./Production deploys, sometimes./' "$T/proj/alpha/.codex/config.toml"
  run lane.sh verify alpha
  assert_has "$T/out" "TODO  approvals"
  assert_lacks "$T/out" "PASS  routing"
}

test_switch_without_a_grants_file_is_not_gated() {
  run lane.sh switch alpha --to codex --session thread-new
  assert_rc 0
  run lane.sh verify alpha
  assert_has "$T/out" "PASS  approvals    no grants file"
}

test_hygiene_reports_grant_findings() {
  gsetup
  run hygiene.sh
  assert_rc 1
  assert_has "$T/out" "- grants: claude not rendered"
  assert_has "$T/out" "- grants: codex alpha not rendered"
}

test_markers_inside_a_toml_string_are_not_a_managed_block() {
  gsetup
  mkdir -p "$T/proj/alpha/.codex"
  {
    printf 'developer_instructions = """\n'
    printf '# >>> transmogrify grants: managed by ops/grants.sh from the grants file; do not edit by hand >>>\n'
    printf 'keep this instruction\n'
    printf '# <<< transmogrify grants <<<\n'
    printf '"""\n\n[projects."/x"]\ntrust_level = "trusted"\n'
  } >"$T/proj/alpha/.codex/config.toml"
  cp "$T/proj/alpha/.codex/config.toml" "$T/before"
  run grants.sh render-codex --actor alpha
  assert_rc 0
  assert_has "$T/proj/alpha/.codex/config.toml" "keep this instruction"
  head -c "$(wc -c <"$T/before")" "$T/proj/alpha/.codex/config.toml" | cmp -s - "$T/before" || _fail "the existing text changed"
  run grants.sh check --side codex --actor alpha
  assert_rc 0
}

test_an_expired_grant_never_removes_an_untagged_entry() {
  gsetup
  text=$(awk '/^### grant: cheap-calls/ { g = 1 } g && /^~~~text$/ { getline; print; exit }' "$T/home/operators/GRANTS.md")
  /usr/bin/python3 -I -c 'import json,sys; json.dump({"autoMode": {"allow": [sys.argv[1]]}}, open(sys.argv[2], "w"))' \
    "$text" "$T/claude/settings.json"
  sed -i.bak 's/^- expires: 2099-12-31$/- expires: 2020-01-01/' "$T/home/operators/GRANTS.md"
  run grants.sh render-claude
  assert_rc 0
  assert_has "$T/claude/settings.json" "Paid Calls Under One Dollar (the owner"
  assert_lacks "$T/claude/settings.json" "[grant:cheap-calls]"
}

test_the_gate_refuses_a_symlinked_codex_folder() {
  gsetup
  run grants.sh render-codex --all
  mkdir -p "$T/elsewhere"
  mv "$T/proj/alpha/.codex" "$T/elsewhere/.codex"
  ln -s "$T/elsewhere/.codex" "$T/proj/alpha/.codex"
  run grants.sh check --gate alpha codex
  assert_rc 1
  assert_has "$T/out" "is a symlink"
}

test_managed_requirements_must_be_checked_by_a_person() {
  gsetup
  run grants.sh render-codex --all
  FAKE_CODEX_REQUIREMENTS=allowedSandboxModes
  export FAKE_CODEX_REQUIREMENTS
  run grants.sh check --gate alpha codex
  assert_rc 1
  assert_has "$T/out" "managed requirements present (allowedSandboxModes)"
  profile_set grants_managed_requirements_ok allowedSandboxModes
  run grants.sh check --gate alpha codex
  assert_rc 0
  unset FAKE_CODEX_REQUIREMENTS
  FAKE_CODEX_REQUIREMENTS_ERROR=1
  export FAKE_CODEX_REQUIREMENTS_ERROR
  run grants.sh check --gate alpha codex
  assert_rc 1
  assert_has "$T/out" "configRequirements/read gave no answer"
}

test_read_commands_and_dry_runs_create_nothing() {
  gsetup
  rm -rf "$T/state"
  run grants.sh check
  run grants.sh validate
  run grants.sh check --gate alpha codex
  assert_no_file "$T/state"
  run grants.sh render-codex --all --out-dir "$T/proof" --dry-run
  assert_rc 0
  assert_no_file "$T/proof"
  assert_no_file "$T/proj/alpha/.codex"
}

test_an_empty_grants_file_passes_with_settings_without_auto_mode() {
  cp "$SCRIPTS/templates/oracle/GRANTS.md" "$T/home/operators/GRANTS.md"
  profile_set grants_codex_bin "$TESTS_DIR/fakes/fake-codex-grants"
  mkdir -p "$T/claude"
  printf '{"model": "x"}\n' >"$T/claude/settings.json"
  run grants.sh check
  assert_rc 0
  assert_has "$T/out" "claude: rendered OK"
  run grants.sh check --gate alpha claude
  assert_rc 0
  run grants.sh check --gate alpha codex
  assert_rc 0
}

test_an_interrupted_render_rolls_back() {
  gsetup
  mkdir -p "$T/proj/alpha/.codex"
  printf 'model = "m"\n' >"$T/proj/alpha/.codex/config.toml"
  FAKE_CODEX_SILENT=1 GRANTS_READBACK_TIMEOUT=30
  export FAKE_CODEX_SILENT GRANTS_READBACK_TIMEOUT
  "$AO_TEST_SHELL" "$SCRIPTS/grants.sh" render-codex --actor alpha </dev/null >"$T/out" 2>"$T/err" &
  bg=$!
  n=0
  until grep -q 'transmogrify grants: managed' "$T/proj/alpha/.codex/config.toml" 2>/dev/null || [ "$n" -ge 100 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  pid=$(ps -axo pid=,command= | awk -v f="$SCRIPTS/lib/grants.py" 'index($0, f) && /render-codex/ { print $1; exit }')
  [ -n "$pid" ] || _fail "no render process found"
  [ -z "$pid" ] || kill -TERM "$pid"
  wait "$bg"
  rc=$?
  assert_rc 1
  assert_has "$T/err" "interrupted"
  assert_eq "$(cat "$T/proj/alpha/.codex/config.toml")" 'model = "m"'
}

ao_test_main "$0"
