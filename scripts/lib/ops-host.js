'use strict';

// The operations layer's host checks inside the doctor and setup (v2 plan
// step 3): one first run for both layers. The doctor runs
// `ops/install.sh --dry-run host`, which only reads (App Nap, power, the
// launchd units, the mailroom bridge ids, the Oracle lock) and turns what it
// finds into owner actions; setup applies the host steps only with the
// owner's consent (`setup.js --apply-host`, which runs `ops/install.sh host
// --apply`). Nothing here signs in, sends Apple Events or reads a Keychain.

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const CHECK_TIMEOUT_MS = 60_000;
const APPLY_TIMEOUT_MS = 180_000;
const MAX_OUTPUT_BYTES = 256 * 1024;

const OWNER_ACTIONS = Object.freeze({
  'operations-unconfigured': 'Run `ops/bootstrap.sh` for the guided first run of the operations layer: the Oracle home, the profile and the always-on host, then the few in-app steps.',
  'operations-host-pending': 'Allow setup to apply the host steps (`setup.js --apply-host`, which runs `ops/install.sh host --apply`): App Nap off for the desktop apps, the tick and relay launchd units, and the mailroom bridge homes.',
  'operations-check-failed': 'Run `ops/install.sh --dry-run host` and fix what it reports; the doctor could not read the host checks.',
});

function opsDir(env = process.env) {
  const dir = env.TRANSMOGRIFY_OPS_DIR || path.resolve(__dirname, '..', '..', 'ops');
  return path.isAbsolute(dir) ? dir : null;
}

// The operations profile, as ops/lib/core.sh finds it.
function opsProfile(env = process.env) {
  if (env.AO_PROFILE) return env.AO_PROFILE;
  const config = env.XDG_CONFIG_HOME || (env.HOME ? path.join(env.HOME, '.config') : null);
  return config ? path.join(config, 'agent-operations', 'profile') : null;
}

function runSh(script, args, env, timeoutMs, dependencies = {}) {
  const run = dependencies.spawn || spawn;
  return new Promise((resolve) => {
    let out = '';
    let settled = false;
    const child = run('/bin/sh', [script, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    const finish = (result) => { if (!settled) { settled = true; clearTimeout(timer); resolve(result); } };
    const timer = setTimeout(() => { child.kill('SIGTERM'); finish({ code: null, out, timedOut: true }); }, timeoutMs);
    const take = (chunk) => { if (out.length < MAX_OUTPUT_BYTES) out += chunk; };
    child.stdout.on('data', take);
    child.stderr.on('data', take);
    child.on('error', () => finish({ code: null, out }));
    child.on('close', (code) => finish({ code, out }));
  });
}

// States the host table counts as done (install.sh host_row).
const DONE_STATE = /^(ok|set|created|installed|updated|loaded|removed|off \(opt-in)/;

// One table row: printf '%-34s %-40s %s' (item, state, action); a wider cell
// pushes the rest right, so fall back to splitting on runs of two spaces.
function parseRow(line) {
  const cell = (value) => (value === '-' ? '' : value);
  const fixed = /^(.{34}) (.{40}) (.*)$/.exec(line);
  const fits = (value, width) => /\s$/.test(value) || value.trim().length === width;
  if (fixed && fixed[1].trim() && fixed[2].trim() && fits(fixed[1], 34) && fits(fixed[2], 40)) {
    return { item: fixed[1].trim(), state: fixed[2].trim(), action: cell(fixed[3].trim()) };
  }
  const cells = line.trim().split(/ {2,}/);
  if (cells.length < 2) return null;
  return { item: cells[0], state: cells[1], action: cell(cells.slice(2).join(' ')) };
}

// Parse the host report: the table (header ITEM STATE ACTION), "N item(s)
// need you.", then "[to do]" lines for the in-app steps. Rows that are not
// done split into those `install.sh host --apply` fixes and manual ones.
function parseHostReport(text) {
  const lines = text.split(/\r?\n/);
  const pendingLine = lines.findIndex((line) => /^\d+ item\(s\) need you\.$/.test(line));
  const header = lines.findIndex((line) => /^ITEM\s+STATE\s+ACTION$/.test(line));
  const rows = header >= 0 && pendingLine > header
    ? lines.slice(header + 1, pendingLine).filter((line) => line.trim()).map(parseRow).filter(Boolean) : [];
  const open = rows.filter((row) => !DONE_STATE.test(row.state));
  const applicable = open.filter((row) => /^would /.test(row.state) || /--apply\b/.test(row.action));
  const manual = open.filter((row) => !applicable.includes(row))
    .map((row) => `${row.item}: ${row.state}${row.action ? ` (${row.action})` : ''}`);
  const inApp = lines.map((line) => /^ {2}\[to do\] (.+)$/.exec(line)).filter(Boolean).map((match) => match[1].trim());
  const done = lines.filter((line) => /^ {2}\[done\] {2}/.test(line)).length;
  return {
    pending: pendingLine >= 0 ? Number(/^(\d+)/.exec(lines[pendingLine])[1]) : null,
    applicable: applicable.length, manual, inApp, inAppDone: done,
  };
}

// The read-only check. States: absent (no ops/ beside the skill),
// unconfigured (no operations profile yet), ready, needsOwner, failed.
async function opsHostCheck(env = process.env, dependencies = {}) {
  const dir = opsDir(env);
  const exists = dependencies.existsSync || fs.existsSync;
  if (!dir || !exists(path.join(dir, 'install.sh'))) return { state: 'absent' };
  const profile = opsProfile(env);
  if (!profile || !exists(profile)) return { state: 'unconfigured' };
  const result = await (dependencies.runSh || runSh)(path.join(dir, 'install.sh'), ['--dry-run', 'host'], env,
    dependencies.timeoutMs || CHECK_TIMEOUT_MS, dependencies);
  const report = parseHostReport(result.out || '');
  if (result.code !== 0 || report.pending === null) return { state: 'failed', timedOut: result.timedOut === true };
  return {
    state: report.pending === 0 && report.inApp.length === 0 ? 'ready' : 'needsOwner',
    pending: report.pending,
    applicable: report.applicable,
    manualSteps: report.manual,
    inAppSteps: report.inApp,
  };
}

// Owner actions for the doctor's setup summary. None of them block lanes.
function opsOwnerActions(check) {
  const action = (reason, ownerAction = OWNER_ACTIONS[reason]) => ({
    provider: 'operations', reason, blocking: false, ownerAction,
  });
  if (check.state === 'unconfigured') return [action('operations-unconfigured')];
  if (check.state === 'failed') return [action('operations-check-failed')];
  if (check.state !== 'needsOwner') return [];
  // --apply-host is offered only for what it can fix; the rest is manual.
  const actions = check.applicable > 0 ? [action('operations-host-pending')] : [];
  for (const step of check.manualSteps || []) actions.push(action('operations-manual', step));
  for (const step of check.inAppSteps || []) actions.push(action('operations-in-app', step));
  return actions;
}

// Apply the host steps; only ever called after the owner's consent.
async function opsHostApply(env = process.env, dependencies = {}) {
  const dir = opsDir(env);
  const exists = dependencies.existsSync || fs.existsSync;
  if (!dir || !exists(path.join(dir, 'install.sh'))) return { applied: false, state: 'absent' };
  const result = await (dependencies.runSh || runSh)(path.join(dir, 'install.sh'), ['host', '--apply'], env,
    dependencies.timeoutMs || APPLY_TIMEOUT_MS, dependencies);
  const report = parseHostReport(result.out || '');
  return {
    applied: result.code === 0,
    state: result.code === 0 ? 'applied' : (result.timedOut ? 'timedOut' : 'failed'),
    pending: report.pending,
    manualSteps: report.manual,
    inAppSteps: report.inApp,
  };
}

module.exports = { OWNER_ACTIONS, opsDir, opsProfile, parseHostReport, opsHostCheck, opsOwnerActions, opsHostApply };
