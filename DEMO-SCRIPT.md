# Demo script — live end-to-end

Estimated runtime: **~7 minutes** of live demo, of which ~90 seconds is waiting for two GitHub Actions workflow runs.

Prerequisites: [`SETUP.md`](SETUP.md) completed. Two GitHub accounts ready (maintainer + attacker fork).

**Before each live run, reset state** so the chain is repeatable:

```bash
# From the maintainer account's checkout:
bash scripts/reset-demo.sh                  # evict the poisoned cache
bash scripts/reset-demo.sh --unpublish      # also drop prior poisoned npm versions
```

The cache eviction is load-bearing: `actions/cache@v4` only *saves* on a cache miss, so if a previous run's poisoned cache is still present the new attacker PR's poisoning step gets silently discarded and the release workflow restores the *older* cache. See troubleshooting at the bottom.

---

## Act 1 — set the scene (~90 sec)

1. Open `https://www.npmjs.com/package/<your-package>`. Show v0.1.0. Read the description. "This is just a tiny utility package I published last week."

2. In a terminal:

   ```bash
   cd /tmp && mkdir consumer && cd consumer && npm init -y >/dev/null
   npm install <your-package> --minimum-release-age=0
   ```

   The `--minimum-release-age=0` flag is a per-invocation override. Some environments (including yours, if `npm config get minimum-release-age` returns >0) refuse to install package versions younger than that age. The flag bypasses it without changing your default config.

   Audience sees a normal install. The `postinstall` prints the harmless thank-you message. No calculator. **This is v0.1.0. The package is clean.**

3. Open the GitHub repo. Show the `vulnerable-bundle-size.yml` and `vulnerable-release.yml` workflow files. Talk through what they do. Highlight `pull_request_target`, the shared cache, `id-token: write`. Note that this is exactly the TanStack setup.

---

## Act 2 — the attack (~3 min)

4. **Switch to the attacker GitHub account.** Open the fork in a second browser profile (or new private window).

5. In a fresh terminal, clone the attacker fork (once per demo — re-uses the same fork across runs):

   ```bash
   cd /tmp
   git clone https://github.com/<attacker-account>/gh-actions-demo-cache-poisoning attacker-fork
   cd attacker-fork
   ```

6. Apply the attack. The script creates a **fresh timestamped branch each run** (so successive demos open new PRs instead of touching the previous one), drops in `scripts/dev-hook.js`, edits one line of `package.json`, commits, and pushes:

   ```bash
   bash /path/to/maintainer-checkout/attack/fork-changes/apply-attack.sh --push
   # branch:  docs/fix-typo-<timestamp>
   # status:  committed
   # pushed:  origin/docs/fix-typo-<timestamp>
   ```

   Before pushing, show the audience the diff (`git show HEAD`). Two changes:
   - One line of `package.json` modified (`prepare` hook).
   - A new `scripts/dev-hook.js` file with a "build cache pre-warmup" comment.

   The reviewer's eye sees a build hook for performance. The reality: a payload planter.

7. Open the PR. The script prints the exact `gh pr create` command on success; paste it. Or via the UI: title `docs: fix typo in README`, brief body.

8. **Watch the bundle-size workflow run.** Click into the PR's "Checks" tab. The workflow runs `npm install` against the PR's code. The `prepare` hook plants the payload. The workflow caches `node_modules`. Workflow completes green, ~45 seconds.

   While it runs, talk through what's happening: "Right now the workflow is running my attacker code in the *base repo's* trust context. It's installing the package, which runs my `prepare` hook, which plants the malicious code in `node_modules/is-number/index.js`. The cache is about to be saved with that poisoned content."

9. Close the PR. Don't merge. The attack doesn't need it merged.

---

## Act 3 — the detonation (~90 sec)

10. **Switch back to the maintainer account.** Show that the malicious PR was closed. From the maintainer's perspective, *nothing happened* — a contributor opened a PR that didn't even get merged.

11. Make any tiny change on `main`. The demo's setup: edit `README.md` in the GitHub web UI, add a single character. "Update README" commit. Click "Commit to main directly."

12. **Watch the release workflow run.** Actions tab → "release (VULNERABLE)" → newest run. It restores the cache, runs `npm install` (no-op because the cache is fresh), `npm run build` bundles the poisoned `is-number` into `dist/postinstall.js`, bumps the version to v0.1.1, runs `npm publish --provenance`.

    Talk through what's happening: "The workflow is restoring the cache that the attacker's PR wrote. The build step is bundling the poisoned `is-number` into `dist/postinstall.js`. In about 30 seconds, npm will host a malicious v0.1.1 of this package, published with provenance from this repo, attested by GitHub."

13. Workflow completes. Refresh `https://www.npmjs.com/package/<your-package>`. v0.1.1 appears. Check the provenance badge — it's there. **The malicious version has a valid SLSA attestation.**

---

## Act 4 — the audience pwn + retrace (~90 sec)

14. **Audience invitation.** "Anyone watching, in your terminal:"

    ```bash
    cd /tmp && mkdir -p consumer-v2 && cd consumer-v2 && npm init -y >/dev/null
    npm install <your-package> --minimum-release-age=0
    ```

    The `--minimum-release-age=0` flag is per-invocation only — it bypasses the recently-published-protection without changing the audience's default config. Most audiences won't have `minimum-release-age` set at all, but including the flag makes the demo robust regardless.

    Their calculator opens. The `[supply-chain-demo]` line prints in their terminal.

15. **Walk through what they just lived through.** Now retrace the chain by clicking through the actual GitHub artifacts. The URLs below are from the most recent successful chain (npm v0.1.19) — if you re-ran live in Acts 2–3, swap these for your latest PR + run URLs (`gh pr list -R lullu57/gh-actions-demo-cache-poisoning --state all` and `gh run list -R lullu57/gh-actions-demo-cache-poisoning --limit 5`):

    | Artifact | Purpose in the chain | URL |
    |---|---|---|
    | Attacker PR (opened, then closed without merging) | "A stranger opened a PR and the maintainer never merged it." | [PR #1](https://github.com/lullu57/gh-actions-demo-cache-poisoning/pull/1) |
    | Bundle-size workflow run on the PR | This is where the cache got poisoned. `prepare` hook ran inside the base repo's trust context, rewrote `node_modules/is-number/index.js`, and `actions/cache@v4` saved the poisoned `node_modules` to the shared cache. | [run 25823773637](https://github.com/lullu57/gh-actions-demo-cache-poisoning/actions/runs/25823773637) |
    | Main-branch commit after the PR was closed | Any subsequent push to `main` (here, a docs commit) triggers the release workflow. Nothing in the commit itself is malicious. | [`db6872d`](https://github.com/lullu57/gh-actions-demo-cache-poisoning/commit/db6872d37dd04cfedd417ae988aab8c45d561201) |
    | Release workflow run on that commit | Restored the poisoned cache (cache hit on the lockfile hash), `npm run build` bundled the poisoned `is-number` into `dist/postinstall.js`, `npm version patch` → `npm publish --provenance`. | [run 25824062329](https://github.com/lullu57/gh-actions-demo-cache-poisoning/actions/runs/25824062329) |
    | Published npm version | The bundled poison lives here. Provenance badge is present and valid — npm and GitHub both attest this was built by the maintainer's repo. | [v0.1.19 on npmjs.com](https://www.npmjs.com/package/cache-poisoning-pwn-demo/v/0.1.19) |

    Click through each in order. The pitch: "There was no merge. There was no token theft. There was no malicious commit on `main`. There was one closed PR that wrote to a cache, and one ordinary `main` push that read from it."

16. **Reveal.** Open the npm tarball:

    ```bash
    curl -s -L $(npm view <your-package>@0.1.1 dist.tarball) | tar xz -O package/dist/postinstall.js | head -50
    ```

    Audience sees the bundled malicious code inside the published artifact. Highlight: this is the file that opened their calculator. It was bundled by the maintainer's own workflow. The maintainer never wrote a malicious line of code. The maintainer's npm token was never stolen.

---

## Act 5 — the lesson (~60 sec)

17. **What happened, in one breath.** No credential was stolen. No maintainer was compromised. A pull request from a stranger, that the maintainer didn't even merge, ended up publishing a malicious package version through the maintainer's own CI.

18. **What would have prevented it.** Switch to `safe-bundle-size.yml` and `safe-release.yml`. Three changes (`pull_request_target` → `pull_request`, cache key scoping, build/publish split). Each costs a small amount of operational complexity. Together they make this attack chain impossible.

19. **What this maps to.** TanStack, May 2026. Same shape. Real attack, real packages, real consumers. Postmortem at `tanstack.com/blog/npm-supply-chain-compromise-postmortem`.

---

## Cleanup

After the demo:

```bash
npm unpublish <your-package> --force
# or version by version:
npm unpublish <your-package>@0.1.1
```

And delete the malicious branch on the attacker fork.

Reset the local repo to the clean state:

```bash
git restore .
rm -rf node_modules dist
npm install
```

---

## Troubleshooting

**Workflow doesn't trigger on the PR.** Check that the target repo's "Settings → Actions → General → Fork pull request workflows from outside collaborators" is set to allow PRs from outside collaborators. For private repos used in a demo where the attacker fork is from your own account, this is usually fine.

**`npm publish` fails with auth error.** Trusted publishing not configured. Re-check `SETUP.md` step 4. Common mistake: wrong workflow filename.

**`npm publish` fails with "version already exists".** A previous demo run left the version. Either unpublish or bump again. The workflow does `npm version patch` so subsequent pushes auto-increment.

**Calculator doesn't open on audience machine.** Some firewall/sandbox blocks `child_process.exec`. Have them run the payload directly: `node -e "$(npm view <your-package>@0.1.1 dist.tarball ...)"`. Or just show the bundled source.

**`npm install` fails with `ENOVERSIONS`.** The audience member has `minimum-release-age` set (npm 10+ defensive feature, increasingly common in security-conscious orgs). Tell them to add `--minimum-release-age=0` to the install command. This is a per-invocation override and doesn't change their default config.

**Cache doesn't hit on the release workflow.** Verify the lockfile is committed and identical between the attacker's PR and main. The cache key is `nm-${{ hashFiles('package-lock.json') }}`.

**Published version comes out CLEAN even after running the attack PR.** This is the most subtle gotcha. `actions/cache@v4` only *saves* on cache miss. If the cache key already has an entry (e.g. populated by a prior release workflow run), the bundle-size workflow's "Cache hit" path will skip the save step, and the poisoned `node_modules` is never persisted to the shared cache. The release workflow then restores the old (clean) cache.

Fix before running a live demo: **evict the cache between runs.**
```bash
gh -R lullu57/gh-actions-demo-cache-poisoning cache list --json id,key \
  | python3 -c "import sys,json,subprocess; [subprocess.run(['gh','-R','lullu57/gh-actions-demo-cache-poisoning','cache','delete',str(c['id'])]) for c in json.load(sys.stdin) if c['key'].startswith('nm-')]"
```

Then re-trigger the bundle-size workflow (close + reopen the PR, or push a new commit to the attack branch). With no existing cache, bundle-size hits a miss → installs fresh → dev-hook plants poison → cache is **saved** with the poison → release workflow restores it → poisoned version publishes.

This gotcha is itself part of the attack's real-world dynamics: in the TanStack incident, the cache state at the time of the attacker's PR happened to be favorable. For a demo you want determinism, so always evict before each live run.

**Poisoned version stays on npm after the demo and pwn's anyone who finds it.** Unpublish immediately:
```bash
npm unpublish cache-poisoning-pwn-demo@0.1.X
# requires interactive SSO/OTP — must be run by the package owner from their terminal
```
npm allows unpublish within 72 hours of original publish OR for packages with no dependents. The demo package qualifies.

---

## Variant: faster demo, no live attack

If you don't want to wait for two workflow runs during the demo:

1. Run the attack chain ahead of time (Acts 2-3). v0.1.1 is live on npm.
2. During the demo, only run Acts 1, 4, 5. Just install v0.1.1, pwn the audience, reveal.

This loses the "you can watch it happen" drama but works in 3 minutes.

The dramatic best is "**c**" (pre-staged AND live), where v0.1.1 is already published from a prior chain, and you also run the live chain to produce v0.1.2 during the demo. Audience can install v0.1.1 to get pwned now, and you can show v0.1.2 appearing on npm seconds later as proof of repeatability.
