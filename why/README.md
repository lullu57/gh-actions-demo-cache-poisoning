# Why the vulnerable pattern exists

Every line of the vulnerable workflows in this demo maps to a legitimate engineering decision. The point of this document is to make those decisions visible so the demo doesn't read as "look how dumb people are."

## Why `pull_request_target`?

GitHub created `pull_request` for the safe case and `pull_request_target` for the case where you *need* the base repo's trust context — most commonly because you want to:

- **Post comments back on the PR** (e.g. bundle-size bot, lint feedback, AI review). The default `GITHUB_TOKEN` for a fork PR is read-only; you can't post a comment with it.
- **Label PRs** (`needs review`, `breaking change`).
- **Approve workflow runs from new contributors.**
- **Run an integration test against a real environment** where the test needs a secret.

The first one is the killer. *Every* mid-sized JS project has a "bundle size diff" comment. People copy the pattern from TanStack, from React, from Vite. The pattern is `pull_request_target`. It's documented. GitHub's own marketplace actions assume it.

You can avoid it by using a two-workflow pattern: an unprivileged `pull_request` workflow uploads the size as an artifact, and a privileged `workflow_run`-triggered workflow reads only that artifact and posts the comment. This is the GitHub-recommended pattern from 2021. Almost nobody uses it because the docs are buried and the pattern is awkward.

## Why a shared cache?

`npm install` on a small package: 30–90 seconds. On a large one: 3–8 minutes. Multiply by every PR run, every push, every Dependabot update — caching is not a "nice to have," it's the difference between CI taking 2 minutes and CI taking 15.

`actions/cache@v4` makes caching a one-line addition. The default cache key (`node-modules-${{ hashFiles('package-lock.json') }}`) naturally collides across workflows in the same repo because the lockfile is the same. That's *by design* — it's the whole point of the cache. Without that collision, the release workflow would always cache-miss and there'd be no speedup.

To avoid the cross-trigger sharing you have to:
- Prefix cache keys with `github.event_name`, OR
- Maintain separate workflows that never share keys, OR
- Use a third-party cache (e.g. depot.dev, BuildJet) with per-trigger isolation.

None of these are obvious. The default behaviour is "fast and unsafe."

## Why `id-token: write`?

This is the modern, recommended way. The old way was:

```yaml
- run: npm publish
  env:
    NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

A static, long-lived npm token in repo secrets. If it leaks (CI log, mis-scoped permissions, compromised CI provider), the attacker has it until rotation.

The new way:

```yaml
permissions:
  id-token: write
- run: npm publish --provenance
```

No token. The runner mints a short-lived (~5 min) JWT, npm verifies it via federation, publish happens. The provenance attestation is signed and verifiable by consumers.

This is unambiguously better against credential theft. The mistake is treating it as protection against *runtime code execution inside the workflow* — which it never claimed to be.

## Why `npm install` instead of `npm ci --ignore-scripts`?

`npm install` is what every developer types locally. `npm ci --ignore-scripts` is two extra concepts you only learn after a security review.

`--ignore-scripts` also genuinely breaks some packages — anything that needs to download or compile a native binary during install (`node-sass`, `node-canvas`, some Puppeteer setups, anything using `node-gyp`). Disabling lifecycle scripts then needs per-package workarounds (prebuilt binaries, separate jobs).

It's also worth noting: `--ignore-scripts` only protects the *install* step. A malicious dependency can still execute code when it's *imported* during `npm run build`. So `--ignore-scripts` is necessary but not sufficient — you also need to ensure that the build job doesn't hold the publish credentials, which is the "split build from publish" change in [`../fix/README.md`](../fix/README.md).

## Why all three jobs in one workflow?

Original release workflow:

```yaml
jobs:
  publish:
    permissions:
      id-token: write
    steps:
      - checkout
      - setup-node
      - npm ci
      - npm run build
      - npm publish --provenance
```

This is the GitHub-documented "publishing with OIDC" example. It's two screenfuls. It works on the first try. It's what every guide on the internet shows.

The "safe" split into two jobs (`build` and `publish`) adds ~30 seconds of artifact upload/download per release and makes the workflow look more complex. The benefit — that build-time code execution can't reach `id-token: write` — only manifests under attack.

The asymmetry is the problem: the unsafe version saves time *every release* and only costs you *during an attack you may never see*. Engineering teams optimize the visible side of that tradeoff.

## The meta-lesson

Cache poisoning isn't caused by ignorance. Every individual decision that produced TanStack's vulnerable workflow shape was:

- A copy of a published, popular pattern.
- An optimization that genuinely paid off most of the time.
- A modern, recommended alternative to an older, worse practice.

Defending against this class of attack is about treating CI as **adversarial software** — assume any code that touches the runner is adversarial, and design the workflow around what each piece of code is allowed to reach. That's a different posture from "tighten up the bad workflow", and it's why the fix in this demo is a three-line change in spirit but a structural change in shape.
