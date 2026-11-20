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

// Parse the host table: rows of item, state, action; "N item(s) need you.";
// then "[to do]" lines for the in-app steps.
function parseHostReport(text) {
  const pending = /^(\d+) item\(s\) need you\.$/m.exec(text);
  const inApp = [...text.matchAll(/^ {2}\[to do\] (.+)$/gm)].map((match) => match[1].trim());
  const done = [...text.matchAll(/^ {2}\[done\] {2}(.+)$/gm)].length;
  return { pending: pending ? Number(pending[1]) : null, inApp, inAppDone: done };
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
  const actions = check.pending > 0 ? [action('operations-host-pending')] : [];
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
    inAppSteps: report.inApp,
  };
}

module.exports = { OWNER_ACTIONS, opsDir, opsProfile, parseHostReport, opsHostCheck, opsOwnerActions, opsHostApply };
