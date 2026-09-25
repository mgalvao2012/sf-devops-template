# sf-devops-template — Project Notes

CI/CD framework for Salesforce DX projects. Engine is **sfdx-hardis** (native workflows,
not reusable). Auth is **auth-URL** everywhere (JWT as optional hardening). Major branches:
`integration` / `uat` / `production`; `feature/*` forks from `integration`.

`scripts/gh-setup.sh` (in `template/scripts/`, copied per project) configures GitHub via `gh`:
repo creation, repo-level auth secrets, Environments + required reviewers, branch protection,
`SFDX_HARDIS_QUICK_DEPLOY` variable. Idempotent.

## Gotchas

- **Environment required-reviewers/branch-policies need a public repo OR GitHub Pro/Team/Enterprise.**
  On a private repo in the free plan the API returns `HTTP 422 "billing plan supports the required
  reviewers protection rule"`. `gh-setup.sh` degrades to a bare environment + warning and exits 3.
  Fix: `gh repo edit <repo> --visibility public --accept-visibility-change-consequences` or upgrade.
- **`gh-team:` approvers require a GitHub organization.** Personal accounts have no teams — resolving
  `orgs/<user>/teams/<slug>` 404s. For a personal-account repo use `gh-user:<login>` in `.sf-devops.yml`.
- **`die` inside `$(...)` only kills the subshell, not the script.** Reviewer resolution must `return 1`
  + let the caller `die` in the parent, or `set -euo pipefail` won't abort and you get a downstream
  `jq --argjson` error on empty input. Same trap for any helper called in command substitution.
- **macOS ships bash 3.2 — no `mapfile`/`readarray`.** Use a `while IFS= read -r` loop with process
  substitution instead. Scripts run via `/usr/bin/env bash` hit 3.2 on stock macOS.
- **Auth-URL secrets are repo-level, not Environment-scoped.** `check-deploy.yml` validates on PRs with
  no `environment:` context, so it can't read Environment-scoped secrets; scoping `SFDX_AUTH_URL_UAT/_PRODUCTION`
  to an Environment breaks the PR check against those orgs. The deploy gate is enforced by Environment
  required reviewers, not secret scope. Forked PRs never receive repo secrets.
- **Required status-check contexts are JOB names, not workflow names.** Branch protection must require
  `Check-only Deployment to Major Org` (job in check-deploy.yml) and `MegaLinter` (job in mega-linter.yml),
  not the workflow `name:` values.
- **Pushing a major branch triggers `process-deploy.yml` immediately.** Configure Environments + branch
  protection (run `gh-setup.sh`) BEFORE pushing `uat`/`production`, or the first push deploys with no gate.
  `gh-setup.sh` pushes only the current branch on repo creation for this reason.
- **Delta deploy needs a fresh base manifest — this repo ships NO static `package.xml` on purpose.**
  `useDeltaDeployment: true` in `.sfdx-hardis.yml` makes the deployed set = base manifest ∩ git delta
  (`smart.js` → `this.packageXmlFile`). A stale static manifest would silently drop any type it omits
  (the ASA silent-drop bug); a *missing* one makes delta crash with `ENOENT ./config/package.xml` (full
  mode tolerates it, delta copies it before the empty-check). Both `check-deploy.yml` and `process-deploy.yml`
  therefore run `sf project generate manifest --source-dir force-app --output-dir manifest --name package`
  every run so base ⊇ delta and the deployed set equals the PR's changed metadata.
- **Delta needs healthy branch topology, config alone won't save you.** Delta is `sgd diff HEAD^..HEAD` on
  the merge commit. A feature branch that already contains the whole target produces an empty delta (no-op
  deploy). Keep the `feature → PR → merge` flow; never merge the target branch back into the feature before
  the PR. major↔major promotions stay full-deploy for safety.
- **sfdx-hardis container runs as a different user than the checkout owner → git "dubious ownership".** git
  refuses to operate on the workspace. Both deploy workflows run
  `git config --global --add safe.directory "$GITHUB_WORKSPACE"` as the first step before any git-backed
  hardis command (delta range, auth).
