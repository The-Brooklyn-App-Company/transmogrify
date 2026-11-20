'use strict';

// The desktop-app lookup reads plists and asks Spotlight; it never sends Apple
// Events. With both apps installed the Codex app keeps its priority.

const assert = require('node:assert/strict');
const test = require('node:test');
const { resolveDesktopApp } = require('../scripts/lib/desktop-attach');

function host(apps, spotlight = {}) {
  const calls = [];
  const run = async (executable, args) => {
    calls.push([executable, ...args]);
    if (executable === 'plutil') {
      const app = Object.entries(apps).find(([appPath]) => args[3].startsWith(appPath));
      if (!app) return { code: 1, stdout: '', stderr: 'no file' };
      const [, info] = app;
      const value = { CFBundleIdentifier: info.id, CFBundleShortVersionString: info.version, CFBundleVersion: info.build }[args[1]];
      return { code: 0, stdout: `${value}\n`, stderr: '' };
    }
    if (executable === 'mdfind') {
      const id = /"([^"]+)"/.exec(args[0])[1];
      return { code: 0, stdout: (spotlight[id] || []).map((p) => `${p}\n`).join(''), stderr: '' };
    }
    throw new Error(`unexpected ${executable}`);
  };
  const existsSync = (plist) => Object.keys(apps).some((appPath) => plist === `${appPath}/Contents/Info.plist`);
  return { run, calls, existsSync };
}

test('with both apps installed the Codex app wins, whichever path is checked first', async () => {
  const { run, calls, existsSync } = host({
    '/Applications/ChatGPT.app': { id: 'com.openai.chat', version: '1.0', build: '1' },
    '/Applications/Codex.app': { id: 'com.openai.codex', version: '26.901.1', build: '77' },
  });
  const found = await resolveDesktopApp(run, { HOME: '/nonexistent-home' }, { existsSync });
  assert.deepEqual(found, { bundleId: 'com.openai.codex', appPath: '/Applications/Codex.app', version: '26.901.1', build: '77' });
  assert.ok(!calls.some(([executable]) => executable === 'osascript'));
});

test('Spotlight finds an app outside the standard locations, checked against its plist', async () => {
  const { run, existsSync } = host({
    '/Volumes/Apps/Codex.app': { id: 'com.openai.codex', version: '26.901.2', build: '78' },
    '/Volumes/Apps/Impostor.app': { id: 'com.example.other', version: '1', build: '1' },
  }, { 'com.openai.codex': ['/Volumes/Apps/Impostor.app', '/Volumes/Apps/Codex.app'] });
  const found = await resolveDesktopApp(run, { HOME: '/nonexistent-home' }, { existsSync });
  assert.equal(found.appPath, '/Volumes/Apps/Codex.app');
});

test('nothing installed is null, not a guess', async () => {
  const { run, existsSync } = host({});
  assert.equal(await resolveDesktopApp(run, { HOME: '/nonexistent-home' }, { existsSync }), null);
});
