# Demo: Cache Poisoning (the TanStack attack)

This is the demo that defeats OIDC trusted publishing.

It reproduces the May 2026 TanStack npm compromise ([postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem), [followup](https://tanstack.com/blog/incident-followup)) using a safe, simulated payload. No real registries are touched.

**The headline:** an attacker opens a normal-looking pull request from a fork. They never get any of your secrets. Three days later, when a maintainer pushes an unrelated change to `main`, your *own release workflow* publishes a malicious version of your package. The npm token was never stolen because **the attacker didn't need a token** — your CI minted one for them.

---

## The setup, in one paragraph

You maintain a small npm package. To be helpful to contributors, every pull request runs a "bundle size" check that builds the package and posts a comment ("bundle grew by +3KB"). To make CI fast, you cache `node_modules` across runs — the cache is shared between the PR-triggered bundle-size workflow and the `main`-triggered release workflow. To be a modern citizen, you use **npm OIDC trusted publishing**: there's no static npm token anywhere in your repo, the release workflow mints a short-lived JWT at publish time and npm trusts it because it's signed by GitHub.

Every individual decision here is good. The combination is fatal.

---

## What you'll learn

1. Why `pull_request_target` + a shared cache + OIDC publishing chains into a publish compromise.
2. Why `permissions: contents: read` does **not** stop cache writes.
3. Why "we don't store any tokens" doesn't save you.
4. Exactly which lines of which workflow files have to change.

---

## The five-minute version

Two workflows. One cache. One trust boundary that nobody notices is a trust boundary.

```
                          ┌─────────────────────────┐
   ┌──────────────┐       │   PR-triggered workflow  │       ┌──────────┐
   │  Fork PR     ├──────▶│  • runs IN BASE TRUST    │──────▶│  WRITES  │
   │  (attacker)  │       │  • checks out PR head     │       │  cache   │
   └──────────────┘       │  • npm install runs      │       └─────┬────┘
                          │    attacker's code        │             │
                          │  • bundle-size comment    │             │ shared
                          └─────────────────────────┘              │ cache
                                                                   │ key
   ┌──────────────┐       ┌─────────────────────────┐              │
   │ Maintainer   │       │  Release workflow        │              │
   │ push to main ├──────▶│  • id-token: write       │◀─────────────┘
   │ (legitimate) │       │  • npm publish (OIDC)    │       RESTORES
   └──────────────┘       │  • runs attacker code    │       cache
                          │    poisoned during PR    │       (which contains
                          └─────────────────────────┘        attacker payload)
```

The attacker's PR can be *closed without merging*. The poison persists in the cache. The next push to `main` — by anyone, for any reason — detonates it.

---

## File tour

| Path | What it is |
|------|------------|
| [`.github/workflows/vulnerable-bundle-size.yml`](.github/workflows/vulnerable-bundle-size.yml) | The bait. `pull_request_target` workflow that writes the cache. |
| [`.github/workflows/vulnerable-release.yml`](.github/workflows/vulnerable-release.yml) | The detonator. `push: main` workflow that restores the cache and publishes. |
| [`.github/workflows/safe-bundle-size.yml`](.github/workflows/safe-bundle-size.yml) | Fixed bundle-size workflow. |
| [`.github/workflows/safe-release.yml`](.github/workflows/safe-release.yml) | Fixed release workflow. |
| [`attack/README.md`](attack/README.md) | Step-by-step "play the attacker" walkthrough. |
| [`attack/payload/`](attack/payload/) | The (safe, simulated) malicious files an attacker would commit to their fork. |
| [`fix/README.md`](fix/README.md) | Line-by-line explanation of the fix. |
| [`why/README.md`](why/README.md) | Why `pull_request_target` and shared caches exist — the legitimate use cases. |

The "package" being defended is deliberately trivial — `src/index.js` exports one function. The interesting code is in the workflows and the attack payload, not the package itself.

---

## How to run this demo

### Setup (one-time)

1. You need **two GitHub accounts**: the "maintainer" account (your normal one) and an "attacker" account (a throwaway). Both need to be able to fork repos.
2. Push this repo to GitHub under the maintainer account as `gh-actions-demo-cache-poisoning`.
3. From the attacker account, fork it.

### Live demo

1. **Show the vulnerable workflows.** Walk the audience through `vulnerable-bundle-size.yml` and `vulnerable-release.yml`. Point out that the workflows look perfectly normal — every part of them maps to a legitimate engineering decision (see [`why/`](why/)).

2. **Show that OIDC is configured.** In `vulnerable-release.yml`, point out:
   - `permissions: id-token: write` (the modern, recommended thing)
   - `npm publish --provenance` (the modern, recommended thing)
   - No `NPM_TOKEN` anywhere (the modern, recommended thing)
   - Audience reaction: "great, what's the problem?"

3. **Play the attacker.** Follow [`attack/README.md`](attack/README.md). From the attacker account, open a PR that adds a "harmless" change to `README.md` along with the payload from `attack/payload/`. The PR's `package.json` adds a `postinstall` script that plants a binary inside `node_modules`. The PR title can even be honest: "fix typo in README" — the attack is in `package.json`.

4. **Watch the bundle-size workflow run on the PR.** It runs `npm install`, which runs the postinstall script, which plants a marker file inside `node_modules`. The workflow caches `node_modules`. Bundle-size posts its usual comment. Nothing in the PR conversation looks suspicious. **Do not merge the PR.** Close it if you want — the cache is already poisoned.

5. **Maintainer pushes to main.** From the maintainer account, push any change to `main` (even just bumping a version comment).

6. **Watch the release workflow detonate.** It restores the poisoned cache, the planted binary executes during the publish step, and the simulated payload writes to `/tmp/cache-poisoning-marker-*.json` recording exactly what context it ran in. In a real attack, this is where the attacker would mint an OIDC token via `id-token: write` and POST directly to `registry.npmjs.org`.

7. **Switch to the fix.** Disable the vulnerable workflows and enable `safe-bundle-size.yml` and `safe-release.yml`. Re-open the same attack PR. Watch the bundle-size workflow refuse to write the cache from PR-triggered code, and the release workflow refuse to restore PR-poisoned caches.

### Quick demo (no second account, no GitHub)

If you can't set up two accounts, you can demonstrate the mechanics locally:

```bash
# Simulate the bundle-size workflow's postinstall execution
cd attack/payload
node simulate-attack.js

# This will create /tmp/cache-poisoning-marker-*.json showing
# what data the payload would have had access to in a real release context.
```

The local simulation is less visceral but still makes the point: the postinstall runs unchecked, and a real attacker controls what it does.

---

## What the simulated payload actually does

To keep this demo safe and shareable, the "malicious" payload in [`attack/payload/`](attack/payload/) does not exfiltrate anything. It writes a JSON marker file to `/tmp/` containing:

- `process.env.GITHUB_REF` (proves it ran in release context)
- `process.env.GITHUB_WORKFLOW`
- the first 8 characters of any token-shaped env var (just to prove it could read them)
- a timestamp

In a real attack the same code position would:

1. Read the `ACTIONS_ID_TOKEN_REQUEST_TOKEN` and `ACTIONS_ID_TOKEN_REQUEST_URL` environment variables.
2. POST to that URL to mint a GitHub OIDC JWT scoped to this workflow.
3. POST that JWT to `https://registry.npmjs.org/-/npm/v1/oidc/token/exchange` to get an npm publish token valid for this package.
4. POST a malicious tarball to `https://registry.npmjs.org/<package>` using that token.

The whole chain takes a single Node.js script and roughly 200ms. None of it touches the legitimate `npm publish` step the workflow ran. The maintainer's audit log shows a normal release.

---

## Key takeaways

- **OIDC is not magic.** It removes static secrets, but a workflow with `id-token: write` *is* the secret. Any code that runs in that workflow can mint a publish token.
- **Caches are a trust boundary.** Treat cache contents the same way you treat downloaded artifacts. Don't share caches across triggers with different trust levels.
- **`permissions:` does not protect the cache.** Cache writes use a separate runner-internal token. `contents: read` does not stop them.
- **`pull_request_target` is the modern footgun.** Even when you don't check out the PR HEAD yourself, transitively `npm install` / `pip install` runs PR-controlled scripts.
- **The audit trail will lie to you.** The release that ships malware looks like a normal, OIDC-signed, provenance-attested publish. The actual `npm publish` step in your workflow was fine. The poison ran in a *previous* step, in a *previous* workflow, days earlier.

---

## Further reading

- [`fix/README.md`](fix/README.md) — what changes, and why each line of the fix matters.
- [`why/README.md`](why/README.md) — why `pull_request_target`, shared caches, and broad `id-token: write` aren't dumb; they're tradeoffs.
- [TanStack postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem)
- [TanStack followup](https://tanstack.com/blog/incident-followup)
- [GitHub Security Lab: keeping your GitHub Actions secure (part 2)](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/)
