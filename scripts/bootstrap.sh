#!/usr/bin/env bash
# GREENFIELD: create a new DX project wired with the sf-devops framework.
# Usage: scripts/bootstrap.sh <target-dir> <project-name>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_ROOT="$(dirname "$HERE")"
source "$HERE/_copy-template.sh"

target="${1:?usage: bootstrap.sh <target-dir> <project-name>}"
name="${2:?project name required}"

command -v sf  >/dev/null || { echo "sf CLI required" >&2; exit 1; }
command -v git >/dev/null || { echo "git required" >&2; exit 1; }

echo "==> Creating DX project '$name' in '$target'"
mkdir -p "$target"
if [[ ! -f "$target/sfdx-project.json" ]]; then
  sf project generate --name "$name" --output-dir "$target" --template standard
  # sf creates <target>/<name>; flatten if needed
  if [[ -d "$target/$name" && ! -f "$target/sfdx-project.json" ]]; then
    shopt -s dotglob; mv "$target/$name"/* "$target/"; rmdir "$target/$name"; shopt -u dotglob
  fi
fi

echo "==> Installing framework payload (greenfield / overwrite)"
copy_template "$FW_ROOT/template" "$target"
chmod +x "$target"/scripts/*.sh 2>/dev/null || true

echo "==> Setting project name in config"
( cd "$target" && tmp="$(mktemp)" && sed "s/name: CHANGE_ME/name: $name/" config/.sf-devops.yml > "$tmp" && mv "$tmp" config/.sf-devops.yml )

echo "==> Initializing git (production + uat + integration)"
cd "$target"
if [[ ! -d .git ]]; then
  git init -q
  git checkout -q -b production
  git add -A && git commit -q -m "chore: scaffold sf-devops framework"
  git branch uat
  git checkout -q -b integration        # default working branch; feature/* forks from here
fi

cat <<EOF

Done. Next:
  1. Edit config/.sf-devops.yml (devhub.alias, sandbox types, approvers).
  2. Edit config/.sfdx-hardis.yml (installedPackages, branch/org mapping) — the engine config.
  3. Authenticate the Dev Hub:      sf org login web --set-default-dev-hub --alias DevHub
  4. Verify prerequisites:          bash scripts/preflight.sh
  5. Spin a scratch org:            sf hardis:scratch:create   (or: sf org create scratch -f config/project-scratch-def.json -a dev -d -y 7)
  6. Seed data (optional):          bash scripts/seed-data.sh dev
  7. Set config/branches/.sfdx-hardis.<branch>.yml targetUsername for integration/uat/production orgs.
  8. Authenticate one org per branch locally (aliases = config/.sf-devops.yml orgAlias: int/uat/prod).
  9. Configure GitHub CI (secrets + Environments + branch protection) BEFORE pushing uat/production:
       gh auth login && bash scripts/gh-setup.sh
     Then push. (First push to production would otherwise trigger a prod deploy with no reviewer gate.)
EOF
