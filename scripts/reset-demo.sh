#!/usr/bin/env bash
# Reset the cache-poisoning demo to a clean state, ready for the next live run.
#
# Run from the maintainer account (the one with gh auth + npm login as the
# package owner). This is the script you run BEFORE each demo, not after.
#
# What it does:
#   1. Evicts every GitHub Actions cache whose key starts with `nm-`. Required
#      because actions/cache@v4 only SAVES on a cache miss — if the key already
#      exists, the attacker PR's poisoned cache is silently dropped and the
#      release workflow restores the prior clean cache instead. (See the
#      DEMO-SCRIPT troubleshooting section for the long version.)
#   2. (Optional, --unpublish) Unpublishes every demo version EXCEPT v0.1.0
#      from npm so the audience-install moment publishes a freshly poisoned
#      version. npm allows unpublish within 72h of original publish OR for
#      packages with no dependents — both apply here.
#   3. Prints a one-line "ready" summary with the current package version.
#
# Usage:
#   bash scripts/reset-demo.sh                 # cache eviction only
#   bash scripts/reset-demo.sh --unpublish     # cache eviction + npm unpublish of >0.1.0
#   REPO=user/repo bash scripts/reset-demo.sh  # override target repo
#   PKG=my-package  bash scripts/reset-demo.sh # override npm package name

set -euo pipefail

REPO="${REPO:-lullu57/gh-actions-demo-cache-poisoning}"
PKG="${PKG:-cache-poisoning-pwn-demo}"
DO_UNPUBLISH=0

for arg in "$@"; do
  case "$arg" in
    --unpublish) DO_UNPUBLISH=1 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

echo "Resetting demo: repo=$REPO  pkg=$PKG"
echo

# 1. Evict caches.
echo "[1/3] Evicting Actions caches starting with 'nm-'…"
CACHES_JSON="$(gh -R "$REPO" cache list --json id,key,sizeInBytes 2>/dev/null || echo '[]')"
DELETED=0
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  gh -R "$REPO" cache delete "$id" >/dev/null
  DELETED=$((DELETED + 1))
done < <(echo "$CACHES_JSON" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    if c['key'].startswith('nm-'):
        print(c['id'])
")
echo "      removed $DELETED cache entrie(s)."
echo

# 2. Unpublish past poisoned versions.
if [[ "$DO_UNPUBLISH" -eq 1 ]]; then
  echo "[2/3] Unpublishing prior demo versions of $PKG (keeping v0.1.0)…"
  VERSIONS="$(npm view "$PKG" versions --json 2>/dev/null | python3 -c "
import sys, json
vs = json.load(sys.stdin)
if isinstance(vs, str):
    vs = [vs]
for v in vs:
    if v != '0.1.0':
        print(v)
" || echo)"
  if [[ -z "$VERSIONS" ]]; then
    echo "      no extra versions to unpublish."
  else
    echo "$VERSIONS" | while read -r v; do
      [[ -z "$v" ]] && continue
      echo "      npm unpublish $PKG@$v"
      npm unpublish "$PKG@$v" 2>&1 | sed 's/^/        /' || true
    done
  fi
  echo
else
  echo "[2/3] Skipping npm unpublish (pass --unpublish to enable)."
  echo
fi

# 3. Report.
echo "[3/3] Current state:"
CURRENT_VERSION="$(node -p "require('./package.json').version" 2>/dev/null || echo '?')"
NPM_LATEST="$(npm view "$PKG" version 2>/dev/null || echo 'unpublished')"
echo "      local package.json version:  $CURRENT_VERSION"
echo "      npm dist-tag latest:         $NPM_LATEST"
echo
echo "Ready. Next steps:"
echo "  - From the attacker fork: bash attack/fork-changes/apply-attack.sh --push"
echo "  - Open the PR. Watch bundle-size run. Close the PR."
echo "  - Push any commit to main of $REPO. Release workflow publishes v$(node -p "
    const v = require('./package.json').version.split('.');
    v[2] = String(parseInt(v[2], 10) + 1);
    v.join('.');
" 2>/dev/null || echo '0.1.X')."
