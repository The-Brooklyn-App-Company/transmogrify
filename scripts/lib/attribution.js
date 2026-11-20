'use strict';

// Agents act as the authorized user (kit rule K-30): what a worker lane
// does carries no agent or model attribution unless the operations profile
// opts in with `attribution=disclose`. TRANSMOGRIFY_ATTRIBUTION, when set,
// decides instead. The profile is parsed as the sh tools parse it: literal
// values, one pair of surrounding quotes removed, later lines winning.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function profileValue(raw) {
  const value = raw.trim();
  const quoted = /^(["'])(.*)\1$/.exec(value);
  return quoted ? quoted[2] : value;
}

function attributionDisclosed(env = process.env) {
  if (env.TRANSMOGRIFY_ATTRIBUTION !== undefined) return profileValue(env.TRANSMOGRIFY_ATTRIBUTION) === 'disclose';
  const file = env.AO_PROFILE || path.join(env.XDG_CONFIG_HOME || path.join(env.HOME || os.homedir(), '.config'),
    'agent-operations', 'profile');
  let value;
  try {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const match = /^\s*attribution\s*=(.*)$/.exec(line);
      if (match) value = profileValue(match[1]);
    }
  } catch {
    return false;
  }
  return value === 'disclose';
}

// Claude Code's own switches for its commit trailer and pull-request footer:
// `attribution` (current clients) and `includeCoAuthoredBy` (older ones).
const CLAUDE_NO_ATTRIBUTION = Object.freeze({
  attribution: Object.freeze({ commit: '', pr: '' }),
  includeCoAuthoredBy: false,
});

function claudeAttributionSettings(env = process.env) {
  return attributionDisclosed(env) ? {} : { ...CLAUDE_NO_ATTRIBUTION, attribution: { commit: '', pr: '' } };
}

module.exports = { attributionDisclosed, claudeAttributionSettings };
