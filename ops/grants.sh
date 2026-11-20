#!/bin/sh
# grants.sh - approvals that follow an operator across Claude Code and Codex:
# one client-neutral grants file, rendered into each client's native layer,
# and a three-state check.
#
# Usage: grants.sh validate
#        grants.sh render-claude [--dry-run] [--prune]
#        grants.sh render-codex (--actor KEY | --all) [--out-dir DIR] [--dry-run] [--no-readback]
#        grants.sh check [--side claude|codex|all] [--actor KEY] [--no-resolve] [--findings]
#        grants.sh check --gate KEY claude|codex
#        grants.sh accept claude '*' NOTE | grants.sh accept codex KEY NOTE
#        grants.sh baseline [--write FILE]
#
# validate      Parse the grants file and check every rule of its format
#               (docs/operations/grants.md).
# render-claude Write one autoMode.allow entry per live grant into the
#               Claude Code settings, each tagged ` [grant:<id>]`. Only
#               tagged entries change (and an untagged copy that is
#               byte-identical to a grant's text gains its tag); every other
#               key and entry stays as it was. Backup first; --prune removes
#               tagged entries no longer in the grants file.
# render-codex  Write a managed root [auto_review] table into each home's
#               own .codex/config.toml: policy = the bundled default reviewer
#               policy, verbatim, then the preamble and the clauses of the
#               grants that name that actor. A local policy replaces the
#               default, so the baseline is kept whole, and an unknown
#               baseline is refused. Read back through `codex app-server`
#               config/read; a failed readback restores the previous file.
#               --out-dir writes DIR/<key>/.codex/config.toml instead (a
#               proof render, never read back).
# check         Three states per side: rendered (disk matches the grants
#               file), resolved (Claude: the settings parse; Codex:
#               config/read shows the rendered policy coming from the home's
#               own .codex layer, with no managed layer above it) and
#               accepted (a fresh-session probe recorded with `accept`).
#               --gate is what `switch.sh switch` and `verify` call: exit 0
#               only when the target side is rendered and resolved.
# accept        Record that a fresh session or thread passed a harmless
#               probe of the rendered grants; refused unless the side is
#               rendered and resolved. The record names the policy hash, so
#               any later change makes the probe pending again.
# baseline      Print the Codex CLI's bundled reviewer policy hash, size and
#               CLI version (never the text); --write FILE saves the text
#               for a person to read before adding it to Known Codex
#               baselines.
#
# Profile keys: grants_file (default operators/GRANTS.md in the Oracle home),
# grants_accepted (default operators/GRANTS-ACCEPTED.tsv),
# grants_claude_settings (default $CLAUDE_CONFIG_DIR or ~/.claude, then
# settings.json), grants_codex_bin (default: codex on PATH),
# grants_managed_requirements_ok (managed Codex requirement keys a person
# has checked and found to set no reviewer policy; any other managed
# requirement, or no answer, leaves Codex unresolved). Needs
# /usr/bin/python3 (the system Python; standard library only).
#
# Never prints a config file, a policy or the model catalog: hashes, lengths
# and origins only. No network, no Keychain, no Apple Events.
#
# Exit codes: 0 ok (check: every side rendered and resolved); 1 findings, a
# refusal or a failure (not synchronized); 2 usage or an invalid grants file;
# 3 busy (another render is writing).
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

# grants_env  Export the paths grants.py reads from the profile.
grants_env() {
  GRANTS_SOURCE=$(ao_cfg_path grants_file operators/GRANTS.md)
  GRANTS_ACCEPTED=$(ao_cfg_path grants_accepted operators/GRANTS-ACCEPTED.tsv)
  GRANTS_REGISTRY=$AO_REGISTRY
  GRANTS_ORACLE_KEY=$AO_ORACLE_KEY
  GRANTS_STATE=$AO_STATE/grants
  _gc=$(ao_cfg grants_claude_settings '')
  if [ -n "$_gc" ]; then GRANTS_CLAUDE_SETTINGS=$(ao_expand_path "$_gc")
  else GRANTS_CLAUDE_SETTINGS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json; fi
  GRANTS_CODEX_BIN=$(ao_cfg grants_codex_bin codex)
  GRANTS_MANAGED_REQUIREMENTS_OK=$(ao_cfg grants_managed_requirements_ok '')
  export GRANTS_SOURCE GRANTS_ACCEPTED GRANTS_REGISTRY GRANTS_ORACLE_KEY GRANTS_STATE \
    GRANTS_CLAUDE_SETTINGS GRANTS_CODEX_BIN GRANTS_MANAGED_REQUIREMENTS_OK
}

main() {
  case ${1-} in -h | --help) ao_usage; exit 0 ;; '') ao_die "$AO_E_USAGE" "usage: grants.sh COMMAND (see --help)" ;; esac
  [ -x /usr/bin/python3 ] || ao_die "$AO_E_FAIL" "grants.sh needs /usr/bin/python3 (the system Python)"
  # Read commands create nothing: the state dir is made only by a render.
  ao_load --no-state
  grants_env
  /usr/bin/python3 -I "$AO_SCRIPTS/lib/grants.py" "$@"
  exit $?
}

main "$@"
