'use strict';

// Worker completions through the operations layer's mailroom, behind
// TRANSMOGRIFY_COMPLETION_ROUTE=mailroom. The end-to-end case writes through
// the real ops/inbox-put.sh into a sandbox Oracle home; nothing reaches a
// real session, inbox or profile.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { completionRoute, deliverToMailroom, mailroomTarget } = require('../scripts/lib/mailroom-route');
const {
  createParentContext, loadParentContext, recordEvent, recordParentWake, reserveDispatch,
} = require('../scripts/lib/dispatch');
const { registerLane } = require('../scripts/lib/state');
const { watchOnce } = require('../scripts/watch');
const { createStateFixture } = require('./helpers/state-fixture');

function tempDir(t, prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// A stand-in ops/ folder whose inbox-put.sh exits with the given code.
function fakeOps(t, code) {
  const dir = tempDir(t, 'tm-ops-');
  fs.writeFileSync(path.join(dir, 'inbox-put.sh'),
    `#!/bin/sh\ncat >"${dir}/note-$1-$2"\n[ ${code} -ne 0 ] || echo "${dir}/inbox/$1/stamp-$2.md"\nexit ${code}\n`, { mode: 0o755 });
  return dir;
}

// A sandbox Oracle home and profile for the real ops/inbox-put.sh.
function sandboxProfile(t) {
  const root = tempDir(t, 'tm-home-');
  fs.mkdirSync(path.join(root, 'home', 'operators'), { recursive: true });
  fs.writeFileSync(path.join(root, 'home', 'operators', 'REGISTRY.tsv'),
    `# key\tname\thome\tsession\tclient\noracle\tOracle\t${root}/home\tsid-o\tclaude\nalpha\tAlpha Op\t${root}/alpha\tsid-a\tcodex\n`);
  fs.writeFileSync(path.join(root, 'profile'), `oracle_home=${root}/home\nstate_dir=${root}/state\n`);
  return { root, env: { PATH: '/usr/bin:/bin', HOME: root, AO_PROFILE: path.join(root, 'profile') } };
}

function parentWithChild(t) {
  const fixture = createStateFixture(t);
  const context = createParentContext({ hostProvider: 'codex', hostApp: 'codex-desktop', displayName: 'Routed parent' }, fixture.env);
  const laneId = crypto.randomUUID();
  const reserved = reserveDispatch({
    parentContext: context, repoRoot: fixture.repoRoot, laneId, targetProvider: 'claude',
    backend: 'claude-remote-control', displayName: '::: routed child', prompt: 'Work.',
  }, fixture.env);
  registerLane(fixture.repoRoot, {
    laneId, backend: 'claude-remote-control', target: 'claude', providerId: 'session_routed1', displayName: '::: routed child',
    state: 'active', runtime: {}, lineage: reserved.lineage,
  }, fixture.env);
  return { fixture, context: loadParentContext(context.file, fixture.env), dispatch: reserved.dispatch };
}

test('the completion route defaults to the wake channel and ignores unknown values', () => {
  assert.equal(completionRoute({}), 'wake');
  assert.equal(completionRoute({ TRANSMOGRIFY_COMPLETION_ROUTE: 'mailroom' }), 'mailroom');
  assert.equal(completionRoute({ TRANSMOGRIFY_COMPLETION_ROUTE: 'mailrom' }), 'wake');
});

test('the mailroom route needs a registry key and an operations layer', (t) => {
  assert.throws(() => mailroomTarget({}), { code: 'MAILROOM_UNCONFIGURED' });
  assert.throws(() => mailroomTarget({ TRANSMOGRIFY_OPS_KEY: 'bad key' }), { code: 'MAILROOM_UNCONFIGURED' });
  assert.throws(() => mailroomTarget({ TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: 'relative' }), { code: 'MAILROOM_UNCONFIGURED' });
  const ops = fakeOps(t, 0);
  assert.equal(mailroomTarget({ TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: ops }).key, 'alpha');
  assert.ok(mailroomTarget({ TRANSMOGRIFY_OPS_KEY: 'alpha' }).script.endsWith(path.join('ops', 'inbox-put.sh')));
});

test('inbox-put outcomes map to written and never-retried codes', async (t) => {
  const written = fakeOps(t, 0);
  const receipt = await deliverToMailroom('child done', { TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: written });
  assert.deepEqual(receipt, { channel: 'mailroom', method: 'mailroom-inbox', certainty: 'written', note: 'stamp-transmogrify-child.md' });
  assert.equal(fs.readFileSync(path.join(written, 'note-alpha-transmogrify-child'), 'utf8'), 'child done');
  await assert.rejects(() => deliverToMailroom('x', { TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: fakeOps(t, 1) }), { code: 'WAKE_UNCERTAIN' },
    'exit 1 can follow a published note: never resent');
  const big = 'x'.repeat(64 * 1024);
  await deliverToMailroom(big, { TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: written });
  assert.equal(fs.readFileSync(path.join(written, 'note-alpha-transmogrify-child'), 'utf8').length, big.length, 'never truncated');
  await assert.rejects(() => deliverToMailroom('x', { TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: fakeOps(t, 2) }), { code: 'MAILROOM_UNCONFIGURED' });
  await assert.rejects(() => deliverToMailroom('x', { TRANSMOGRIFY_OPS_KEY: 'alpha', TRANSMOGRIFY_OPS_DIR: fakeOps(t, 9) }), { code: 'WAKE_UNCERTAIN' });
});

test('with the mailroom route a completion becomes one inbox note, even without a wake channel', async (t) => {
  const { fixture, context, dispatch } = parentWithChild(t);
  const notes = [];
  let woke = 0;
  const env = { ...fixture.env, TRANSMOGRIFY_COMPLETION_ROUTE: 'mailroom', TRANSMOGRIFY_OPS_KEY: 'alpha' };
  const observe = async () => {
    recordEvent({ dispatchId: dispatch.dispatchId, type: 'child.turn-completed', fingerprint: 'turn:1', data: { state: 'idle' } }, env);
    return { dispatches: [dispatch], errors: [], observed: [{ dispatchId: dispatch.dispatchId, phase: 'idle' }] };
  };
  const deliverMailroom = async (text) => { notes.push(text); return { channel: 'mailroom', method: 'mailroom-inbox', certainty: 'written' }; };
  const state = { wakedEventIds: [] };
  const first = await watchOnce(context, {}, env, state, { observe, deliver: async () => { woke += 1; }, deliverMailroom });
  assert.deepEqual(first.wakes.map((w) => [w.kind, w.delivered, w.method, w.certainty]), [['complete', true, 'mailroom-inbox', 'written']]);
  assert.equal(woke, 0, 'the per-parent wake channel is not used');
  assert.match(notes[0], /finished its turn and is idle/);
  const second = await watchOnce(context, {}, env, state, { observe, deliverMailroom });
  assert.equal(second.wakes.length, 0, 'never written twice');
  assert.equal(notes.length, 1);
});

test('the default route still uses the recorded wake channel', async (t) => {
  const { fixture, context, dispatch } = parentWithChild(t);
  recordParentWake(context, { channel: 'claude-bridge', id: 'session_routeDefault1', cwd: null, receipt: { source: 'test' } }, fixture.env);
  const reloaded = loadParentContext(context.file, fixture.env);
  let mailed = 0;
  const observe = async () => {
    recordEvent({ dispatchId: dispatch.dispatchId, type: 'child.turn-completed', fingerprint: 'turn:1', data: { state: 'idle' } }, fixture.env);
    return { dispatches: [dispatch], errors: [], observed: [] };
  };
  const pass = await watchOnce(reloaded, {}, fixture.env, { wakedEventIds: [] }, {
    observe, deliver: async () => ({ channel: 'claude-bridge' }), deliverMailroom: async () => { mailed += 1; },
  });
  assert.equal(pass.wakes[0].method, 'claude-bridge');
  assert.equal(mailed, 0);
});

test('end to end: the note lands in the sandbox inbox through the real ops/inbox-put.sh', async (t) => {
  if (!fs.existsSync('/bin/sh')) return t.skip('no /bin/sh');
  const { root, env } = sandboxProfile(t);
  const receipt = await deliverToMailroom('Transmogrify: child "::: routed child" finished its turn and is idle.\n',
    { ...env, TRANSMOGRIFY_OPS_KEY: 'alpha' });
  assert.equal(receipt.certainty, 'written');
  const inbox = path.join(root, 'home', 'inbox', 'alpha');
  const files = fs.readdirSync(inbox);
  assert.equal(files.length, 1);
  assert.match(files[0], /transmogrify-child\.md$/);
  assert.equal(receipt.note, files[0]);
  assert.match(fs.readFileSync(path.join(inbox, files[0]), 'utf8'), /finished its turn and is idle/);
  await assert.rejects(() => deliverToMailroom('x', { ...env, TRANSMOGRIFY_OPS_KEY: 'nobody' }), { code: 'MAILROOM_UNCONFIGURED' });
});
