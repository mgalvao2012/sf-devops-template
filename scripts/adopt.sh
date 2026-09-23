#!/usr/bin/env bash
# BROWNFIELD: add the sf-devops framework to an EXISTING DX project.
# Framework files overwrite in place; git is the safety net — a clean working tree is
# required so every change is reviewable in `git diff` and revertible with `git checkout`.
# Usage: scripts/adopt.sh <existing-project-dir>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_ROOT="$(dirname "$HERE")"
source "$HERE/_copy-template.sh"

target="${1:?usage: adopt.sh <existing-project-dir>}"
[[ -f "$target/sfdx-project.json" ]] || { echo "No sfdx-project.json in '$target' — not a DX project. Use bootstrap.sh for greenfield." >&2; exit 1; }

echo "==> Requiring a clean git working tree (git is the safety net for overwrites)"
[[ -d "$target/.git" ]] || { echo "'$target' is not a git repo. Init git and commit first — the framework overwrites files and relies on git to review/revert them." >&2; exit 1; }
git -C "$target" diff --quiet && git -C "$target" diff --cached --quiet \
  || { echo "'$target' has uncommitted changes. Commit or stash first so framework overwrites are reviewable in 'git diff'." >&2; exit 1; }

echo "==> Installing framework payload (brownfield / overwrite)"
copy_template "$FW_ROOT/template" "$target"
chmod +x "$target"/scripts/*.sh 2>/dev/null || true

echo "==> Ensuring major branches exist (integration, uat, production)"
if [[ -d "$target/.git" ]]; then
  cur="$(git -C "$target" rev-parse --abbrev-ref HEAD)"
  for b in integration uat production; do
    git -C "$target" show-ref --verify --quiet "refs/heads/$b" \
      || { git -C "$target" branch "$b" "$cur"; echo "  created branch: $b (from $cur)"; }
  done
fi

cat <<EOF

Done. Review the working-tree diff before committing (git diff):
  1. Reconcile framework defaults with your existing configs (eslint/prettier/gitignore) — inspect the diff and keep what you need.
  2. Fill config/.sf-devops.yml (approvers, sandbox types) AND config/.sfdx-hardis.yml (installedPackages).
  3. Set config/branches/.sfdx-hardis.<branch>.yml targetUsername for int/uat/prod orgs.
  4. Reconcile branch model: feature/* forks from 'integration'; protect integration/uat/production.
  5. Verify prerequisites:   cd $target && bash scripts/preflight.sh
  6. Baseline: ensure current org metadata is fully represented in source (sf project retrieve start) before first delta deploy.
  7. Authenticate one org per branch locally (aliases = config/.sf-devops.yml orgAlias: int/uat/prod), then configure GitHub CI:
       gh auth login && bash scripts/gh-setup.sh   (secrets + Environments + required reviewers + branch protection, idempotent)
EOF
