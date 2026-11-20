'use strict';

// Apple Events (osascript, `tell application`, `path to application`) raise a
// macOS Automation consent prompt. An unattended host must never see one from
// a read path such as the doctor, setup's checks, or the test suite. The only
// allowed call is the consented Desktop quit in scripts/lib/desktop-attach.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const SCANNED = ['scripts', 'ops', 'install.sh'];
const CODE = /\.(js|cjs|mjs|sh|py)$/;
// An executable invocation, not prose: a quoted 'osascript' argument, an
// osascript command in a shell line, or an AppleScript application reference.
const PATTERN = /['"`]osascript['"`]|(^|[;&|(]|\$\()\s*(\/usr\/bin\/)?osascript\b|tell application|path to application/;
const ALLOWED = { file: 'scripts/lib/desktop-attach.js', fn: 'quitDesktop' };

function files(entry) {
  const full = path.join(ROOT, entry);
  if (!fs.existsSync(full)) return [];
  if (fs.statSync(full).isFile()) return [entry];
  return fs.readdirSync(full, { withFileTypes: true }).flatMap((dirent) => {
    const rel = path.join(entry, dirent.name);
    if (dirent.isDirectory()) return dirent.name === 'node_modules' ? [] : files(rel);
    return CODE.test(dirent.name) || !path.extname(dirent.name) ? [rel] : [];
  });
}

// The [first, last] line numbers of a top-level function body.
function functionLines(lines, name) {
  const start = lines.findIndex((line) => new RegExp(`^(async )?function ${name}\\(`).test(line));
  if (start < 0) return null;
  const end = lines.findIndex((line, index) => index > start && line === '}');
  return [start, end];
}

function isComment(line) {
  return /^\s*(\/\/|#|\*)/.test(line);
}

test('no Apple Events outside the consented Desktop quit', () => {
  const offenders = [];
  for (const rel of SCANNED.flatMap(files)) {
    const lines = fs.readFileSync(path.join(ROOT, rel), 'utf8').split('\n');
    const allowed = rel === ALLOWED.file ? functionLines(lines, ALLOWED.fn) : null;
    lines.forEach((line, index) => {
      if (isComment(line) || !PATTERN.test(line)) return;
      if (allowed && index > allowed[0] && index < allowed[1]) return;
      offenders.push(`${rel}:${index + 1}`);
    });
  }
  assert.deepEqual(offenders, []);
});

test('the Desktop lookup uses fixed paths and Spotlight, never Apple Events', () => {
  const source = fs.readFileSync(path.join(ROOT, ALLOWED.file), 'utf8').split('\n');
  const [start, end] = functionLines(source, 'resolveDesktopApp');
  const body = source.slice(start, end).join('\n');
  assert.match(body, /'\/Applications\/ChatGPT\.app'/);
  assert.match(body, /'mdfind'/);
  assert.doesNotMatch(body.split('\n').filter((line) => !isComment(line)).join('\n'), /osascript/);
});

test('the scanner catches the patterns it guards against', () => {
  for (const sample of [
    "run('osascript', ['-e', 'x'])",
    'osascript -e "quit"',
    'x=$(osascript -e 1)',
    'POSIX path of (path to application id "a.b")',
  ]) assert.match(sample, PATTERN, sample);
  assert.doesNotMatch('Restore lsof, ps, mdfind, and plutil', PATTERN);
});
