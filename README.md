# cache-poisoning-pwn-demo

> **⚠️ Educational demo, do NOT use in production.** Installing this package opens Calculator (or your platform's equivalent) on your machine. That's the point — it demonstrates a real supply-chain attack against npm packages built with GitHub Actions.
>
> Published to npm: [`cache-poisoning-pwn-demo`](https://www.npmjs.com/package/cache-poisoning-pwn-demo)

## What this repo is

A faithfully-reproducible cache-poisoning attack against an npm package's CI/CD pipeline, modeled on the [May 2026 TanStack npm supply-chain compromise](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem). The package is real, published to public npm, and the attack chain runs end-to-end on GitHub Actions infrastructure.

**The point in one sentence:** no credential is stolen, no maintainer is compromised, and a stranger's pull request — *closed without merging* — causes the maintainer's *own* CI to publish a malicious release on the next innocent push to `main`. The published version is signed with **npm provenance attestation**, which is the modern "trust me, this came from a real workflow" stamp; the attestation is correctly issued and verifiable, because the attack works *inside* the trusted workflow, not by stealing its keys.

## Why this repo exists

To make this attack class touchable. Reading [the TanStack postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem) communicates the shape; running this demo communicates the *speed* and the *invisibility*. Audiences who watch the malicious version appear on the npm UI seconds after an innocuous `git push` rarely forget the demo.

It also serves as a **shareable reference** for engineers who need to harden their own publishing pipelines: every link in the unsafe chain has a paired safe alternative in [`fix/`](fix/README.md), and every "bad practice" has an empathy note in [`why/README.md`](why/README.md) explaining the legitimate engineering reason it was tempting.

## If you found this organically (via npm, search, or a colleague)

- The package on npm is real. Installing it triggers the educational payload (opens Calculator + prints a marker message). It does not exfiltrate, persist, or do anything other than open a GUI app.
- This is **not a typosquat** of any popular package — the name `cache-poisoning-pwn-demo` is intentionally demo-flagged.
- If you maintain an npm package built with GitHub Actions, read [`fix/README.md`](fix/README.md) — the three workflow-level changes there make this attack class structurally impossible.
- If you consume npm packages in CI, the single most-effective consumer-side defense is `npm config set minimum-release-age 10080` — read the [hardening section](#consumer-side-mitigation) below.

## The attack in one diagram

```
Attacker fork PR (or any same-repo branch from a write-access account)
    │
    ▼
.github/workflows/vulnerable-bundle-size.yml
    │  (triggers on pull_request_target → runs in BASE repo trust context)
    │  (checks out PR HEAD; runs npm install → fires attacker's prepare hook)
    │  (caches node_modules — INCLUDING the poisoned is-number/index.js)
    ▼
[ shared GitHub Actions cache key: nm-<hash-of-package-lock.json> ]
    │  cache persists even after PR is closed
    ▼
Any future push to main (a typo fix, a Dependabot bump, anything)
    │
    ▼
.github/workflows/vulnerable-release.yml
    │  (restores the poisoned cache; runs build; bundles poisoned is-number into dist/postinstall.js)
    │  (mints OIDC token; publishes v0.1.N with provenance attestation)
    ▼
npm registry: cache-poisoning-pwn-demo@0.1.N is now MALICIOUS
    │
    ▼
Anyone running `npm install cache-poisoning-pwn-demo`
    → postinstall executes → calculator opens → "[supply-chain-demo] supply-chain attack PoC triggered."
```

---

## What the demo shows

| Stage | What happens | Audience-visible? |
|-------|--------------|-------------------|
| Baseline | v0.1.0 published to npm by maintainer. Clean. | `npm install` shows "thanks for installing" |
| Attack | Fork PR triggers `pull_request_target` workflow. Plants payload into `node_modules/is-number`. Cache poisoned. PR closed. | Workflow log on PR (innocuous-looking) |
| Detonation | Maintainer pushes any change to `main`. Release workflow restores cache, builds, publishes v0.1.1 to npm. | New version visible on npm with provenance |
| Pwn | Audience runs `npm install <package>` → calculator opens. | Calculator opens on every audience machine |

---

## File tour

| Path | What it is |
|------|------------|
| [`package.json`](package.json), [`src/`](src/), [`scripts/build.js`](scripts/build.js) | A real, working npm package — tiny utility wrapping `is-number`. Uses esbuild to bundle node_modules into dist/. |
| [`.github/workflows/vulnerable-bundle-size.yml`](.github/workflows/vulnerable-bundle-size.yml) | `pull_request_target` workflow that writes the poisoned cache |
| [`.github/workflows/vulnerable-release.yml`](.github/workflows/vulnerable-release.yml) | `push: main` workflow that restores the cache, builds, publishes to public npm via OIDC trusted publishing |
| [`.github/workflows/safe-bundle-size.yml`](.github/workflows/safe-bundle-size.yml) + [`safe-release.yml`](.github/workflows/safe-release.yml) | Fixed versions |
| [`attack/README.md`](attack/README.md) | The attacker's full walkthrough |
| [`attack/fork-changes/`](attack/fork-changes/) | The exact files an attacker commits to their fork, plus `apply-attack.sh` to scaffold a fork in one command |
| [`attack/simulate-attack.js`](attack/simulate-attack.js) | Local-only simulation (no GitHub, no npm) — opens calculator on the demoer's machine |
| [`SETUP.md`](SETUP.md) | One-time setup: npm account, package name, OIDC trusted publisher, repo push |
| [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) | Live demo timing, ~6 minutes, what to click, what to say |
| [`fix/README.md`](fix/README.md) | Line-by-line explanation of the fix |
| [`why/README.md`](why/README.md) | Why the unsafe pattern exists |

---

## Quick start

Three paths, from fastest to most dramatic:

### Path A — local-only (no GitHub, no npm). ~30 seconds.

```bash
npm install
node attack/simulate-attack.js
```

Calculator opens. Done. Useful for proving the chain works before staging the live version.

### Path B — staged live (recommended for demos)

1. Follow [`SETUP.md`](SETUP.md): create npm account, publish v0.1.0 manually, configure trusted publishing, push repo.
2. **Pre-stage** the attack once (Acts 1-3 of [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md)) to get v0.1.1 published.
3. During the live demo: do Acts 4-5 (audience installs, gets pwned, reveal).

### Path C — live in front of the audience. ~6 min.

Follow [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) end to end. Audience watches the attack PR open, the cache poison, the release happen, then installs the result.

---

## What's bundled into the published artifact

```
node_modules/is-number/index.js        ← attacker plants payload here via fork PR
                ↓
              esbuild
                ↓
dist/postinstall.js                    ← bundled output; published to npm in package files
                ↓
        npm install <pkg>
                ↓
       postinstall hook runs
                ↓
      `child_process.exec('open -a Calculator')` runs on consumer
```

The legitimate `dist/postinstall.js` (built from clean `node_modules`) just prints `"thanks for installing"`. The poisoned `dist/postinstall.js` (built from poisoned `node_modules`) also opens Calculator. **The maintainer's source code does not change.** Only the bundle does — because the bundle inputs were tampered with.

---

## Why this is hard to detect

- **Maintainer-side audit shows nothing.** No malicious commits on main. The release commit is `npm version patch` from a release-bot. The published version has GitHub-attested provenance pointing to a real, clean commit on main.
- **The malicious PR was closed.** It may not even appear on the repo's main UI. The poisoning step ran in a workflow log archived under the closed PR.
- **The diff that bundle-size cached looks innocuous.** A new `scripts/dev-hook.js` with a "pre-warm the build cache" comment. A one-character prepare hook tweak. Reviewers who looked at the PR would mostly see the README typo fix.
- **npm provenance signed it.** The provenance attestation is *correct* — it accurately states which workflow built which commit. The workflow just happened to bundle attacker-poisoned cache contents.

---

## What the fix changes

Three independent changes, each addressing one link in the chain:

1. `pull_request_target` → `pull_request`. Fork PRs no longer run in base trust context.
2. Cache key scoping. PR workflow and release workflow can't share caches.
3. `npm ci --ignore-scripts` + split build/publish jobs. Even if a dep is compromised, its code can't reach `id-token: write`.

See [`fix/README.md`](fix/README.md).

## Consumer-side mitigation

The single most-effective defense against this attack class — from the consumer side — is to refuse to install package versions that were published very recently. npm 10+ supports this natively:

```bash
npm config set minimum-release-age 10080    # 7 days, in minutes
```

With this set, a malicious version published via the cache-poisoning chain has 7 days for someone to detect and unpublish before any consumer's CI actually installs it. Combined with `npm audit` / `osv-scanner` in CI, this catches most known-compromise scenarios cleanly.

Note: to install **this demo package** despite this setting, append `--minimum-release-age=0` to the install command — it's a per-invocation override that doesn't touch your default config.

## How the demo workflow publishes without a token

The release workflow uses **npm OIDC trusted publishing** — no `NPM_TOKEN` secret is set anywhere. GitHub Actions mints a short-lived JWT, npm verifies it against the package's trusted-publisher config, and `npm publish` succeeds. The provenance attestation is signed by Sigstore.

This is the modern, recommended publishing pattern, used by major OSS projects. The demo's point is that this modernization does *not* save you from cache poisoning — if the attacker gets their bytes into the publish job's `dist/`, they get the registry's blessing for free.

---

## Cleanup

After the demo:

```bash
# Unpublish the malicious version (within 72h or for packages with no dependents):
npm unpublish <your-package>@0.1.1

# Or unpublish everything:
npm unpublish <your-package> --force

# Reset the local working tree:
git restore .
rm -rf node_modules dist
npm install
```

---

## References

- [TanStack postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem)
- [TanStack incident followup](https://tanstack.com/blog/incident-followup)
- [GitHub Security Lab: keeping your GitHub Actions secure (part 2)](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/)
- [npm trusted publishing docs](https://docs.npmjs.com/trusted-publishers)
