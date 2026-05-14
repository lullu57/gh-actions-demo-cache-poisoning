# One-time setup

You only do this once, when you first set up the demo. After this, the attack chain runs end-to-end on real npm.

## 0. Decide on a package name

The package is published to **public npm**, so the name must be unique globally. Options:

1. **Unscoped**: pick a name like `cache-poisoning-pwn-demo-<random>`. Check availability with `npm view <name>` (returns 404 if free).
2. **Scoped**: `@<your-npm-username>/cache-poisoning-pwn-demo`. Scoped names are unique per scope; you just need to own the scope (i.e. have an npm account with that username).

The current `package.json` uses `cache-poisoning-pwn-demo` unscoped. If that's taken, edit `name` in `package.json` and `package-lock.json` accordingly.

## 1. Create an npm account (if you don't have one)

```bash
npm adduser
```

Follow the email verification. Make sure 2FA is enabled (`npm profile enable-2fa auth-and-writes`).

## 2. Update package metadata

```bash
# Inside this repo:
node -e "
  const fs = require('fs');
  const pkg = require('./package.json');
  pkg.name = 'YOUR-PACKAGE-NAME';          // edit
  pkg.repository.url = 'git+https://github.com/YOUR-USER/gh-actions-demo-cache-poisoning.git';
  pkg.homepage = 'https://github.com/YOUR-USER/gh-actions-demo-cache-poisoning';
  fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
"
```

Or just edit by hand.

## 3. Publish the clean baseline (v0.1.0) manually

**Important: publish from a clean working tree.** If you have run the local attack simulation (`node attack/simulate-attack.js`), your `node_modules/is-number/index.js` is poisoned. Publishing in that state would bundle the payload into v0.1.0 itself — every consumer would get pwned by v0.1.0, not just by the later v0.1.1. The whole demo arc depends on v0.1.0 being clean.

The safe way:

```bash
./publish-clean.sh
```

This script wipes `node_modules` and `dist`, reinstalls clean dependencies, sanity-checks `dist/postinstall.js` for the demo-payload marker, then runs `npm publish`. It asks for confirmation before publishing.

If you want to do it manually:

```bash
rm -rf node_modules dist
npm install              # rebuilds dist/ via prepare hook
grep -q 'supply-chain-demo' dist/postinstall.js && echo "ABORT: poisoned" || npm publish --access public
```

**2FA prompt**: npm requires a one-time code from your authenticator app when publishing (assuming you enabled `auth-and-writes` 2FA, which is recommended). The CLI will prompt:
```
This operation requires a one-time password.
Enter OTP: ______
```
Open your authenticator app, type the 6 digits, hit enter. If using `--otp=` on the command line, the code is valid for ~30 seconds and one use only.

Verify on `https://www.npmjs.com/package/<your-package-name>` — should show v0.1.0. Run `npm install <package>` from a scratch directory and confirm only the harmless "thanks for installing" message prints. **No calculator.**

## 4. Configure npm trusted publishing (OIDC)

This is what lets the GitHub release workflow publish without a static `NPM_TOKEN`.

1. Go to `https://www.npmjs.com/package/<your-package-name>/access`.
2. Scroll to "Trusted Publisher" section.
3. Click "Add trusted publisher".
4. Fill in:
   - **Publisher**: GitHub Actions
   - **Repository**: `<your-user>/gh-actions-demo-cache-poisoning`
   - **Workflow filename**: `vulnerable-release.yml`
   - **Environment**: leave blank (the vulnerable workflow doesn't use environments)
5. Save.

From this point, any workflow run that:
- runs in the configured repo,
- runs the configured workflow file,
- has `id-token: write` permission,
- runs `npm publish --provenance`

…can publish to this package with no static token.

## 5. Push this repo to GitHub

```bash
gh repo create gh-actions-demo-cache-poisoning --private --source=. --push
```

(Or: create privately on GitHub UI, then `git remote add origin ... && git push -u origin main`.)

## 6. Set up the attacker fork (required for the live demo)

You need a **second GitHub account** — one that isn't the maintainer account. GitHub won't let an account fork its own repo, and the attack mechanic depends on the PR sitting in the "fork PR" trust slot (which is what makes `pull_request_target` interesting — it runs in base trust context and sees the maintainer's secrets). Any existing personal account works; a brand-new throwaway also works but new accounts sometimes get flagged on first PR.

From the attacker account:

1. Visit the maintainer repo on GitHub and click **Fork**. Keep the default name.
2. Clone the fork locally to a separate path from the maintainer checkout:
   ```bash
   git clone https://github.com/<attacker-account>/gh-actions-demo-cache-poisoning /tmp/attacker-fork
   ```
3. The demo flow runs `attack/fork-changes/apply-attack.sh --push` from inside the fork checkout. It mints a fresh timestamped branch per run, so the same fork is reused across demos without PR-conflict pain.

Re-fork only if you delete the fork or rotate to a new attacker account.

## 7. Verify

- `npm install <your-package>` from any directory: prints the "thanks for installing" message; no calculator. v0.1.0 is clean.
- Workflow runs visible in the GitHub Actions tab.

You're ready to run [DEMO-SCRIPT.md](DEMO-SCRIPT.md).

---

## Cleanup after the demo

```bash
npm unpublish <your-package> --force         # while still under 72 hours
# or unpublish specific versions:
npm unpublish <your-package>@0.1.1
```

npm allows unpublish within 72 hours of original publish, OR for packages with no dependents. Plan accordingly.

Also delete or archive the GitHub repo if you don't want it findable.
