# Demo: Cache Poisoning → Real npm Publish

This is the **flagship demo** in a series of eight GitHub Actions supply-chain attack reproductions. It is the only demo in the set that publishes a malicious version to **real public npm** by way of the attack chain. Audience members can `npm install` the package and execute the payload.

The other seven companion demos (script injection, `pull_request_target`, mutable action tags, credential leaks, `workflow_dispatch`, build-input compromise, self-hosted runner takeover) currently live in private repos.

The headline: **no credential is stolen. No maintainer is compromised. A stranger's PR — closed without merging — causes a future innocent push to `main` to publish a malicious release.**

This is a faithful reproduction of the [TanStack npm supply-chain compromise](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem) (May 2026) using a package we control.

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
