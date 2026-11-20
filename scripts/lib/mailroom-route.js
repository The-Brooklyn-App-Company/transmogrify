'use strict';

// Worker completions through the operations layer's mailroom (v2 plan step
// 4, behind a setting). With TRANSMOGRIFY_COMPLETION_ROUTE=mailroom, the
// watcher turns a child's wake into a note in the parent's inbox through
// `ops/inbox-put.sh KEY SLUG`, and the mailroom's degradation ladders deliver
// it like any other note: one delivery path, one telemetry format. The
// default route stays the per-parent wake channel until the mailroom route
// is proven live (K-36: build alongside, then switch).

const path = require('node:path');
const fs = require('node:fs');
const { spawn } = require('node:child_process');

const ROUTES = Object.freeze(['wake', 'mailroom']);
const KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const NOTE_SLUG = 'transmogrify-child';
const PUT_TIMEOUT_MS = 20_000;
const MAX_NOTE_BYTES = 16 * 1024;

class RouteError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'RouteError';
    this.code = code;
  }
}

// The configured route; anything unrecognized keeps the default wake route,
// so a typo never silences completions.
function completionRoute(env = process.env) {
  const value = env.TRANSMOGRIFY_COMPLETION_ROUTE;
  return ROUTES.includes(value) ? value : 'wake';
}

// The parent's registry key and the inbox-put script of the operations layer.
function mailroomTarget(env = process.env) {
  const key = env.TRANSMOGRIFY_OPS_KEY;
  if (!key || !KEY_PATTERN.test(key)) {
    throw new RouteError('MAILROOM_UNCONFIGURED', 'TRANSMOGRIFY_OPS_KEY must name the parent\'s registry key');
  }
  const opsDir = env.TRANSMOGRIFY_OPS_DIR || path.resolve(__dirname, '..', '..', 'ops');
  if (!path.isAbsolute(opsDir)) {
    throw new RouteError('MAILROOM_UNCONFIGURED', 'TRANSMOGRIFY_OPS_DIR must be an absolute path');
  }
  const script = path.join(opsDir, 'inbox-put.sh');
  if (!fs.existsSync(script)) {
    throw new RouteError('MAILROOM_UNCONFIGURED', 'the operations layer has no inbox-put.sh');
  }
  return { key, script };
}

// Write one note. inbox-put.sh writes through a temp file and a rename: exit
// 1 means nothing was written (safe to retry), exit 2 a configuration
// problem (never retried); a timeout or a signal may have written it, so it
// is never retried.
function deliverToMailroom(text, env = process.env, dependencies = {}) {
  const { key, script } = mailroomTarget(env);
  const body = Buffer.from(String(text), 'utf8').subarray(0, MAX_NOTE_BYTES);
  const run = dependencies.spawn || spawn;
  return new Promise((resolve, reject) => {
    let settled = false;
    let stdout = '';
    const child = run('/bin/sh', [script, key, NOTE_SLUG], { env, stdio: ['pipe', 'pipe', 'ignore'] });
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGTERM');
      reject(new RouteError('WAKE_UNCERTAIN', 'the inbox note may have been written; it is not resent'));
    }, dependencies.timeoutMs || PUT_TIMEOUT_MS);
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.on('error', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new RouteError('WAKE_UNDELIVERED', 'the inbox note could not be written'));
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code === 0) {
        resolve({ channel: 'mailroom', method: 'mailroom-inbox', certainty: 'written', note: path.basename(stdout.trim()) });
      } else if (code === 1) {
        reject(new RouteError('WAKE_UNDELIVERED', 'the inbox note could not be written'));
      } else if (code === 2) {
        reject(new RouteError('MAILROOM_UNCONFIGURED', 'the operations layer refused the note (profile or registry key)'));
      } else {
        reject(new RouteError('WAKE_UNCERTAIN', `inbox-put ended ${signal || code}; the note is not resent`));
      }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(body);
  });
}

module.exports = { ROUTES, NOTE_SLUG, RouteError, completionRoute, mailroomTarget, deliverToMailroom };
