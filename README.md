# cache-poisoning-pwn-demo

> **Educational demo, do NOT use in production.** Installing this package opens Calculator (or the platform equivalent) on the consumer's machine. That's the point — it's a real supply-chain attack against an npm package built with GitHub Actions, end-to-end on real infrastructure.
>
> Published to npm: [`cache-poisoning-pwn-demo`](https://www.npmjs.com/package/cache-poisoning-pwn-demo) · Flagship demo in the [series](https://github.com/lullu57/gh-actions-supply-chain-demo#the-nine-patterns).

A faithfully-reproducible cache-poisoning attack modeled on the [May 2026 TanStack npm compromise](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem). The package is real, on public npm, and the attack chain runs end-to-end through real GitHub Actions and real npm OIDC trusted publishing.

**No credential is stolen. No maintainer is compromised.** A stranger's pull request — closed without merging — causes the maintainer's *own* CI to publish a malicious release on the next innocent push to `main`. The published version carries a correctly-issued **npm provenance attestation**, because the attack works inside the trusted workflow, not against its keys.

This is the orchestrator's [GitHub Actions cache seam](https://github.com/lullu57/gh-actions-supply-chain-demo#the-platform-model-behind-the-analogy): caches are shared across triggers, fork PRs can plant entries that a later release restores, and cache writes ignore `permissions: contents: read`. The same kitchen analogy as the orchestrator's [shared spice rack](https://github.com/lullu57/gh-actions-supply-chain-demo#wrong-assumption-1--only-the-chef-touches-the-key).

## Why this repo exists

Reading the TanStack postmortem communicates the *shape* of the attack; running this demo communicates the *speed* and the *invisibility*. Audiences who watch a malicious version appear on the npm UI seconds after an innocuous `git push` rarely forget the demo. It also doubles as a hardening reference: every link in the unsafe chain has a paired safe alternative in [`fix/`](fix/README.md), and every "bad practice" has an empathy note in [`why/README.md`](why/README.md).

## If you found this organically (via npm or search)

The package on npm is real. Installing it triggers the educational payload — it opens Calculator and prints a marker. It does not exfiltrate, persist, or do anything else. It is not a typosquat; the name is intentionally demo-flagged. If you maintain an npm package built with Actions, [`fix/README.md`](fix/README.md) has the three workflow changes that make this attack class structurally impossible. If you consume npm packages in CI, set `npm config set min-release-age 7` (see [below](#consumer-side-mitigation)).

## The attack in one diagram 

```
Attacker fork PR (or any same-repo branch from a write-access account)
    │
    ▼
.github/workflows/vulnerable-bundle-size.yml
    │  triggers on pull_request_target → runs in BASE repo trust context
    │  checks out PR HEAD; npm install fires attacker's prepare hook
    │  caches node_modules — INCLUDING the poisoned is-number/index.js
    ▼
[ shared GitHub Actions cache key: nm-<hash-of-package-lock.json> ]
    │  cache persists even after the PR is closed
    ▼
Any future push to main (a typo fix, a Dependabot bump, anything)
    │
    ▼
.github/workflows/vulnerable-release.yml
    │  restores the poisoned cache; builds; bundles poisoned is-number into dist/postinstall.js
    │  mints OIDC token; publishes v0.1.N with provenance attestation
    ▼
npm registry: cache-poisoning-pwn-demo@0.1.N is now MALICIOUS
    │
    ▼
Anyone running `npm install cache-poisoning-pwn-demo`
    → postinstall executes → calculator opens → "[supply-chain-demo] supply-chain attack PoC triggered."
```

The four stages map to what the audience sees:

| Stage | What happens | Audience-visible |
|-------|--------------|------------------|
| Baseline | v0.1.0 published cleanly by the maintainer | `npm install` prints "thanks for installing" |
| Attack | Fork PR fires `pull_request_target`, plants payload into `node_modules/is-number`, cache poisoned, PR closed | Innocuous-looking workflow log on the PR |
| Detonation | Maintainer pushes any change to `main`; release workflow restores cache, builds, publishes v0.1.1 | New version on npm with provenance |
| Pwn | Audience runs `npm install` | Calculator opens on every audience machine |

## File tour

| Path | What it is |
|------|------------|
| [`package.json`](package.json), [`src/`](src/), [`scripts/build.js`](scripts/build.js) | A real, tiny npm package wrapping `is-number`. esbuild bundles `node_modules` into `dist/`. |
| [`.github/workflows/vulnerable-bundle-size.yml`](.github/workflows/vulnerable-bundle-size.yml) | `pull_request_target` workflow that writes the poisoned cache |
| [`.github/workflows/vulnerable-release.yml`](.github/workflows/vulnerable-release.yml) | `push: main` workflow that restores the cache, builds, publishes to public npm via OIDC |
| [`.github/workflows/safe-*.yml`](.github/workflows/) | Fixed versions |
| [`attack/README.md`](attack/README.md) | Full attacker walkthrough |
| [`attack/fork-changes/`](attack/fork-changes/) | The exact files the attacker commits; `apply-attack.sh` scaffolds a fork in one command |
| [`attack/simulate-attack.js`](attack/simulate-attack.js) | Local-only simulation (no GitHub, no npm) — opens Calculator on the demoer's machine |
| [`SETUP.md`](SETUP.md) | One-time setup (npm account, package name, OIDC trusted publisher, repo push) |
| [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) | Live demo timing (~6 min), what to click, what to say |
| [`fix/README.md`](fix/README.md) | Line-by-line explanation of the fix |
| [`why/README.md`](why/README.md) | Why the unsafe pattern exists |

## Quick start

Three paths, fastest to most dramatic:

**Path A — local only, ~30 seconds.** `npm install && node attack/simulate-attack.js`. Calculator opens. Useful for proving the chain works before staging the live version.

**Path B — staged live (recommended).** Follow [`SETUP.md`](SETUP.md) once. Pre-stage Acts 1–3 of [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) so v0.1.1 is already on npm. During the demo, do Acts 4–5 — audience installs and gets pwned, then reveal.

**Path C — fully live, ~6 min.** Follow [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) end-to-end with the audience watching the attack PR open, the cache poison, the release publish, and the install.

## What ends up on npm

```
node_modules/is-number/index.js   ← attacker plants payload here via fork PR
              ↓ esbuild
dist/postinstall.js               ← bundled output; shipped in package files
              ↓ npm install <pkg>
       postinstall hook runs
              ↓
  child_process.exec('open -a Calculator')
```

A clean `node_modules` produces a `dist/postinstall.js` that prints "thanks for installing". A poisoned `node_modules` produces one that *also* opens Calculator. **The maintainer's source code does not change.** Only the bundle changes — because its inputs were tampered with.

## Why this is hard to detect

A maintainer-side audit shows nothing: no malicious commits on main, the release commit is a release-bot's `npm version patch`, and the published version has GitHub-attested provenance pointing to a real, clean commit. The malicious PR was closed and may not even appear in the repo's main UI — the poisoning step ran in a workflow log archived under the closed PR. The cached diff looks innocuous: a new `scripts/dev-hook.js` with a "pre-warm the build cache" comment, a one-character prepare-hook tweak, a README typo fix in the same PR for reviewer focus. And npm provenance signed it: the attestation is *correct* — it accurately states which workflow built which commit. The workflow just happened to bundle attacker-poisoned cache contents.

## What the fix changes

Three independent changes, each closing one link:

1. `pull_request_target` → `pull_request`. Fork PRs no longer run in base trust context.
2. Scope cache keys with `${{ github.event_name }}` (or use separate workflows). PR and release runs can't share caches.
3. `npm ci --ignore-scripts` + split build/publish jobs. Even a compromised dep can't reach `id-token: write`.

Details in [`fix/README.md`](fix/README.md).

## Consumer-side mitigation

The single most-effective defense from the consumer side is refusing to install package versions that were published very recently. npm 10+ supports this natively:

```bash
npm config set min-release-age 7    # 7 days
```

A malicious version published via this chain then has 7 days to be detected and unpublished before any consumer's CI installs it. Combine with `npm audit` / `osv-scanner` in CI and most known-compromise scenarios get caught cleanly.

To install **this demo package** despite the setting, append `--min-release-age=0` to the install command — a per-invocation override that doesn't touch your default config.

## How the demo publishes without a token

The release workflow uses npm **OIDC trusted publishing** — no `NPM_TOKEN` exists anywhere. GitHub Actions mints a short-lived JWT, npm verifies it against the package's trusted-publisher config, `npm publish` succeeds, and Sigstore signs the provenance attestation. This is the modern recommended pattern, used by major OSS projects. The demo's point is that this modernization does *not* save you from cache poisoning — if attacker bytes reach the publish job's `dist/`, they get the registry's blessing for free.

## Cleanup

```bash
npm unpublish <your-package>@0.1.1     # within 72h, or any time if no dependents
npm unpublish <your-package> --force    # nuclear option
git restore . && rm -rf node_modules dist && npm install
```


## References

- [TanStack postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem) and [followup](https://tanstack.com/blog/incident-followup)
- [GitHub Security Lab — preventing pwn requests](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/)
- [npm trusted publishing docs](https://docs.npmjs.com/trusted-publishers)
