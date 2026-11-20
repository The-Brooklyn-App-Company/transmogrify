'use strict';

// The operations layer inside the doctor and setup: a read-only host check
// that becomes non-blocking owner actions, and a consented apply. The
// end-to-end case runs the real ops/install.sh --dry-run host against a
// sandbox profile (no desktop apps, a sandbox launchd folder) and proves it
// writes nothing.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { OWNER_ACTIONS, opsHostApply, opsHostCheck, opsOwnerActions, parseHostReport } = require('../scripts/lib/ops-host');
const { parseDoctorArgs, renderSetupSummary } = require('../scripts/doctor');
const { parseSetupArgs, runHostSetup } = require('../scripts/setup');
const { doctorReport } = require('./helpers/onboarding-fixture');

const REPORT = `ITEM                               STATE                                    ACTION
app-nap com.openai.codex           would set                                defaults write com.openai.codex NSAppSleepDisabled -bool YES
power                              ok (system sleep off)                    -

1 item(s) need you.

In the apps (once; a person does these):
  [done]  Claude: the Mailroom session.
  [to do] Codex sidebar: pin the threads of the operators active on Codex, and the Mailroom.
`;

function tempDir(t, prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

const present = { existsSync: () => true };

test('the host report parses into pending items and in-app steps', () => {
  assert.deepEqual(parseHostReport(REPORT), {
    pending: 1, inApp: ['Codex sidebar: pin the threads of the operators active on Codex, and the Mailroom.'], inAppDone: 1,
  });
  assert.equal(parseHostReport('garbage').pending, null);
});

test('the check states map to non-blocking owner actions', async () => {
  assert.deepEqual(await opsHostCheck({ TRANSMOGRIFY_OPS_DIR: '/nonexistent-ops' }), { state: 'absent' });
  assert.deepEqual(await opsHostCheck({ HOME: '/nonexistent-home' }, { existsSync: (p) => p.endsWith('install.sh') }),
    { state: 'unconfigured' });
  const failed = await opsHostCheck({ AO_PROFILE: '/p' }, { ...present, runSh: async () => ({ code: 1, out: 'boom' }) });
  assert.equal(failed.state, 'failed');
  const calls = [];
  const needs = await opsHostCheck({ AO_PROFILE: '/p' }, {
    ...present, runSh: async (script, args) => { calls.push([path.basename(script), ...args]); return { code: 0, out: REPORT }; },
  });
  assert.deepEqual(calls, [['install.sh', '--dry-run', 'host']], 'the doctor only ever runs the dry run');
  assert.equal(needs.state, 'needsOwner');
  const actions = opsOwnerActions(needs);
  assert.deepEqual(actions.map((a) => [a.provider, a.reason, a.blocking]), [
    ['operations', 'operations-host-pending', false], ['operations', 'operations-in-app', false],
  ]);
  assert.equal(actions[0].ownerAction, OWNER_ACTIONS['operations-host-pending']);
  assert.deepEqual(opsOwnerActions({ state: 'unconfigured' }).map((a) => a.reason), ['operations-unconfigured']);
  assert.deepEqual(opsOwnerActions({ state: 'absent' }), []);
  assert.deepEqual(opsOwnerActions({ state: 'ready', pending: 0, inAppSteps: [] }), []);
});

test('the doctor adds the operations checks only when asked, and they never block lanes', async (t) => {
  assert.equal(parseDoctorArgs(['--repo-root', '/tmp/r', '--target', 'claude']).operations, undefined);
  assert.equal(parseDoctorArgs(['--repo-root', '/tmp/r', '--target', 'claude', '--operations']).operations, true);
  const without = await doctorReport(t, { target: 'codex', persisted: true, desktopState: 'attached' });
  assert.equal(without.operations, undefined);
  let checked = 0;
  const withOps = await doctorReport(t, {
    target: 'codex', persisted: true, desktopState: 'attached', operations: true,
    opsHostCheck: async () => { checked += 1; return { state: 'needsOwner', pending: 2, inAppSteps: [] }; },
  });
  assert.equal(checked, 1);
  assert.equal(withOps.operations.state, 'needsOwner');
  assert.ok(withOps.setup.ownerActions.some((a) => a.provider === 'operations' && a.reason === 'operations-host-pending' && a.blocking === false));
  assert.equal(withOps.setup.ready, without.setup.ready, 'operations actions never change lane readiness');
  assert.match(renderSetupSummary(withOps), /^Operations: Allow setup to apply the host steps/m, 'the terminal summary shows them');
  assert.doesNotMatch(renderSetupSummary(without), /^Operations:/m);
});

test('setup applies the host steps only on --apply-host, alone, after a read-only check', async () => {
  assert.equal(parseSetupArgs(['--repo-root', '/tmp/r']).applyHost, false);
  assert.equal(parseSetupArgs(['--repo-root', '/tmp/r', '--apply-host']).applyHost, true);
  assert.throws(() => parseSetupArgs(['--repo-root', '/tmp/r', '--apply-host', '--sign-in']), /one consent at a time/);
  let applied = 0;
  const needs = async () => ({ state: 'needsOwner', pending: 3, inAppSteps: ['pin it'] });
  const apply = async () => { applied += 1; return { applied: true, state: 'applied', pending: 0, inAppSteps: ['pin it'] }; };
  const dry = await runHostSetup({ dryRun: true }, {}, { opsHostCheck: needs, opsHostApply: apply });
  assert.deepEqual([dry.ok, dry.host.state, applied], [true, 'wouldApply', 0]);
  const done = await runHostSetup({ dryRun: false }, {}, { opsHostCheck: needs, opsHostApply: apply });
  assert.deepEqual([done.ok, done.host.state, done.host.inAppSteps, applied], [true, 'applied', ['pin it'], 1]);
  const nothing = await runHostSetup({ dryRun: false }, {}, {
    opsHostCheck: async () => ({ state: 'needsOwner', pending: 0, inAppSteps: ['pin it'] }), opsHostApply: apply,
  });
  assert.deepEqual([nothing.ok, applied], [true, 1], 'nothing to apply: the apply never runs');
  const refused = await runHostSetup({ dryRun: false }, {}, { opsHostCheck: async () => ({ state: 'unconfigured' }), opsHostApply: apply });
  assert.deepEqual([refused.ok, refused.code, refused.refusal.reason, applied], [false, 'POLICY_REFUSAL', 'operations-unconfigured', 1]);
  const failing = await runHostSetup({ dryRun: false }, {}, {
    opsHostCheck: needs, opsHostApply: async () => ({ applied: false, state: 'failed', pending: 3, inAppSteps: [] }),
  });
  assert.deepEqual([failing.ok, failing.code], [false, 'PROVIDER_UNAVAILABLE']);
});

test('the apply runs install.sh host --apply', async () => {
  const calls = [];
  const result = await opsHostApply({}, {
    ...present, runSh: async (script, args) => { calls.push(args); return { code: 0, out: REPORT.replace('1 item', '0 item') }; },
  });
  assert.deepEqual(calls, [['host', '--apply']]);
  assert.deepEqual([result.applied, result.state, result.pending], [true, 'applied', 0]);
});

test('end to end: the real dry run reads a sandbox host and writes nothing', async (t) => {
  if (process.platform === 'win32' || !fs.existsSync('/bin/sh')) return t.skip('needs /bin/sh');
  const root = tempDir(t, 'tm-host-');
  const home = path.join(root, 'home');
  fs.mkdirSync(path.join(home, 'operators'), { recursive: true });
  fs.mkdirSync(path.join(root, 'agents'));
  fs.writeFileSync(path.join(home, 'operators', 'REGISTRY.tsv'), `# key\tname\thome\tsession\tclient\noracle\tOracle\t${home}\tsid-o\tclaude\n`);
  fs.writeFileSync(path.join(root, 'profile'),
    `oracle_home=${home}\nstate_dir=${root}/state\nhost_apps=none\nhost_launchd_dirs=${root}/agents\n`);
  const before = fs.readdirSync(root, { recursive: true }).sort();
  const check = await opsHostCheck({ PATH: '/usr/bin:/bin:/usr/sbin:/sbin', HOME: root, AO_PROFILE: path.join(root, 'profile') });
  assert.ok(['ready', 'needsOwner'].includes(check.state), JSON.stringify(check));
  assert.equal(typeof check.pending, 'number');
  assert.ok(check.inAppSteps.length > 0, 'the in-app steps are listed');
  const after = fs.readdirSync(root, { recursive: true }).filter((p) => !p.startsWith('state')).sort();
  assert.deepEqual(after, before.filter((p) => !p.startsWith('state')), 'the dry run creates nothing in the home');
});
