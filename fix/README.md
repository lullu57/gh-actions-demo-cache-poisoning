# The fix, line by line

Two files change. Both diffs are small. The conceptual change is large.

## Change 1: `bundle-size.yml`

### `pull_request_target` → `pull_request`

```diff
-on:
-  pull_request_target:
-    branches: [main]
+on:
+  pull_request:
+    branches: [main]
```

Fork PRs now run in the **fork's** trust context. `GITHUB_TOKEN` is read-only. Repo secrets are not exposed. Cache writes still happen, but they're scoped to PR runs (see next change) and not visible to release runs.

**What you lose:** the workflow can no longer post comments on the PR using `GITHUB_TOKEN`, because fork-context `GITHUB_TOKEN` is read-only. *Workaround:* upload the bundle-size as an artifact, and have a *separate* `workflow_run` trigger workflow (which runs in the base repo's trust context but only sees the artifact, not PR code) post the comment.

### Cache key scoped by event

```diff
-key: node-modules-${{ hashFiles('**/package-lock.json') }}
+key: node-modules-pr-${{ hashFiles('**/package-lock.json') }}
```

Prefixing the cache key with `pr-` means PR-triggered runs and `main`-triggered runs use disjoint cache keys. Even if you re-enable `pull_request_target` later for some reason, a poisoned PR cache cannot match a release cache key.

**What you lose:** slightly worse cache hit rate on the very first release after a long quiet period. Negligible.

## Change 2: `release.yml`

### Cache key prefix

```diff
-key: node-modules-${{ hashFiles('**/package-lock.json') }}
+key: node-modules-release-${{ hashFiles('**/package-lock.json') }}
```

Symmetric to the bundle-size change. The release workflow only restores caches written by other release workflow runs.

### `npm ci --ignore-scripts` during install

```diff
-      - name: Install (if cache miss) or verify cached
-        run: npm install
+      - name: Install dependencies (no lifecycle scripts)
+        run: npm ci --ignore-scripts
```

`npm install` triggers `postinstall`, `preinstall`, and `install` lifecycle hooks for every dependency in the tree. Even a fully-trusted lockfile cannot stop one of those scripts from being malicious — the script runs whatever the *registry* served for that package version, and a compromise of any maintainer of any transitive dep gives the attacker code execution here.

`npm ci --ignore-scripts` disables all lifecycle hooks during install. Dependencies are still installed; only their auto-run scripts are blocked.

**What you lose:** packages that genuinely need a postinstall step (e.g. native compilation) won't be set up correctly via this command. For those packages you should either pre-build them (use prebuilt binaries), or move their install to a separate, lower-privilege job whose output is consumed via artifact.

### Split build from publish

```diff
-jobs:
-  publish:
-    runs-on: ubuntu-latest
-    permissions:
-      contents: read
-      id-token: write
+jobs:
+  build:
+    runs-on: ubuntu-latest
+    permissions:
+      contents: read
+  publish:
+    needs: build
+    runs-on: ubuntu-latest
+    permissions:
+      contents: read
+      id-token: write
```

The original workflow runs `npm install`, `npm build`, and `npm publish` all in one job that has `id-token: write`. Any code execution during install or build can mint a publish token.

The safe version runs install + build in a job with **no** `id-token: write`. The build's output (the `dist/` directory) is uploaded as an artifact. A second job downloads the artifact and publishes it. The publish job has `id-token: write` but does no `npm install` and no `npm run build` — its only attack surface is the actions it uses, which should be SHA-pinned (mutable action tags are a separate attack class documented in a companion demo).

**What you lose:** workflow runs are slightly longer due to artifact upload/download. ~30 seconds. Worth it.

## Why each of these matters independently

You could apply any one of these three fixes and meaningfully reduce risk. Together they're defense-in-depth:

1. **Trigger fix (`pull_request_target` → `pull_request`).** Removes the privileged context from the PR workflow entirely. This alone defeats the TanStack attack as published.
2. **Cache scoping.** Even if a future maintainer re-introduces a privileged PR workflow, the caches can't cross-pollinate.
3. **`--ignore-scripts` + split publish.** Even if a *non-PR* compromise plants malicious code (e.g. a compromised dependency), it doesn't run with publish authority.

The TanStack incident chained three failures. The fix chain matches the attack chain.
