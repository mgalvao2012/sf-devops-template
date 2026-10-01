# sf-devops-template — Implementation Guide

Step-by-step to stand up the framework. Two adoption paths:
- **A. Greenfield** — brand-new project.
- **B. Brownfield** — existing/ongoing DX project (git-guarded overwrite; clean tree required).

Design rationale lives in [DEVOPS-PLAN.md](DEVOPS-PLAN.md). This is the how-to.

---

## Repo layout

```
sf-devops/                     # the framework repo (central, published once)
├── DEVOPS-PLAN.md             # architecture & decisions
├── IMPLEMENTATION.md          # this guide
├── scripts/                   # framework tooling (run to onboard a project)
│   ├── bootstrap.sh           #   greenfield
│   ├── adopt.sh               #   brownfield (overwrites in place; git tracks changes)
│   └── _copy-template.sh
└── template/                  # PAYLOAD copied into each project
    ├── config/
    │   ├── .sf-devops.yml     #   policy overlay (approvers, sandbox type, seeding)
    │   ├── .sfdx-hardis.yml   #   ENGINE config (deploy, delta, packages, major branches)
    │   ├── branches/          #   per-branch org mapping: integration / uat / production
    │   └── project-scratch-def.json
    ├── data/sfdmu/export.json #   anonymized seed plan
    ├── scripts/               #   runtime scripts (preflight, seed-data, gh-setup, lib)
    └── .github/workflows/     #   check-deploy + mega-linter (PR Gate A), auto-merge (green→integration), process-deploy (deploy on merge)
```

---

## 0. Prerequisites (one-time, per person/machine)

```bash
# CLI + plugins (sfdx-hardis is the engine; it uses sfdx-git-delta under the hood)
npm i -g @salesforce/cli
sf plugins install sfdx-hardis sfdmu code-analyzer
brew install yq            # config parsing used by the scripts

# Dev Hub — MUST be enabled in the org first (Setup > Dev Hub > Enable), then:
sf org login web --set-default-dev-hub --alias DevHub
```
> The framework **verifies** the Dev Hub in preflight; it does not enable it. Enabling is a manual org action.

Publish the framework once so teams onboard from a known version: push this repo to
`your-org/sf-devops` and tag it (`git tag v1 && git push --tags`). Each project gets a
**self-contained copy** of the workflows (no cross-repo reusable-workflow reference); the
shared, versioned component is the sfdx-hardis engine image pinned in those workflows.

---

## A. Greenfield (new project)

```bash
# from the sf-devops framework repo:
bash scripts/bootstrap.sh ../acme-crm acme-crm
```
This: generates the DX project, copies the payload, sets the project name, and inits git with the major branches `production` + `uat` + `integration`.

Then:
1. **Edit `../acme-crm/config/.sf-devops.yml`** — `devhub.alias`, `environments.*.sandboxType`, `environments.*.approvers`.
2. **Edit `../acme-crm/config/.sfdx-hardis.yml`** — `installedPackages` (managed-package deps), branch/org mapping. This is the engine config.
3. `cd ../acme-crm && bash scripts/preflight.sh` — confirms Dev Hub + approvers.
4. Create a scratch org and start building:
   ```bash
   sf hardis:scratch:create             # installs packages from .sfdx-hardis.yml automatically
   bash scripts/seed-data.sh dev        # SFDMU anonymized seed (via hardis)
   sf project deploy start -o dev
   ```
5. Push to GitHub → **§1 CI setup**.

---

## B. Brownfield (existing project)

```bash
# from the sf-devops framework repo, pointing at the existing project:
bash scripts/adopt.sh ../legacy-project
```
Requires a **clean git working tree** (the script fails otherwise). Framework files overwrite in place; git is the safety net — review every change in `git diff` and revert with `git checkout` what you don't want. It also creates the `integration`/`uat`/`production` branches from your current branch.

Then:
1. **Review the `git diff`** — reconcile framework defaults with your existing configs (eslint/prettier/gitignore); keep what you need.
2. **Fill `config/.sf-devops.yml`** (overlay) and **`config/.sfdx-hardis.yml`** (engine: packages, branch/org map).
3. **Baseline the source** — before the first delta deploy, ensure the org's current metadata is fully in git:
   ```bash
   sf project retrieve start --manifest package.xml   # or use sfdx-hardis backup
   git add -A && git commit -m "chore: baseline metadata before sf-devops"
   ```
4. **Reconcile branching** — adopt `integration`/`uat`/`production`; move active feature work onto `feature/*` off `integration`. Set `targetUsername` in each `config/branches/.sfdx-hardis.<branch>.yml`.
5. `bash scripts/preflight.sh` → **§1 CI setup**.

---

## 1. CI setup (GitHub, one-time per project)

> **Automated path:** once the orgs are authenticated locally (aliases matching `environments.*.orgAlias` in `.sf-devops.yml` — `int`/`uat`/`prod` by default) and `gh` is logged in, run **`bash scripts/gh-setup.sh`** from the project. It applies steps 1, 3, 4 and 5 below in one idempotent pass (repo secrets, Environments + required reviewers, per-branch branch protection, `SFDX_HARDIS_QUICK_DEPLOY`, and auto-merge). To wire auto-merge in the same run, pass the PAT via env — it is piped into `gh`, never printed: **`AUTOMERGE_PAT=<token> bash scripts/gh-setup.sh`**. The manual steps that follow document what it does / how to do it by hand.

> **Sequencing.** A push to a major branch triggers `process-deploy.yml` immediately, so gates must exist first. `gh-setup.sh` enforces the safe order itself: it creates the repo (pushing only the current branch), sets secrets + Environments (with required reviewers), and **only then** pushes `uat`/`production` and applies branch protection — so the deploy triggered by that push already lands on the reviewer gate. Pass `--no-push` to keep `uat`/`production` local and protect them on a later re-run.

1. **Auth URLs as secrets.** The `check-deploy.yml` and `process-deploy.yml` workflows authenticate via `sf hardis:auth:login`, which reads the **auth-URL method first**: it looks for `SFDX_AUTH_URL_<BRANCH>` where `<BRANCH>` is the target major branch name **uppercased** (`integration` → `SFDX_AUTH_URL_INTEGRATION`). The secret suffix must match the branch name exactly, or auth falls through.

   First authenticate & alias one org per major branch — the alias must equal the branch's `orgAlias` in `.sf-devops.yml` (defaults `int`/`uat`/`prod`), which is what `gh-setup.sh` reads to source each secret. (In CI the workflow re-aliases the org as `ORG_ALIAS = <branch>` from the auth URL; the local alias only matters for extracting the secret.)
   ```bash
   sf org login web --alias integration  --instance-url https://test.salesforce.com   # Integration
   sf org login web --alias uat  --instance-url https://test.salesforce.com   # UAT
   sf org login web --alias prod --instance-url https://login.salesforce.com  # Production
   ```
   Then export each auth URL **straight into a GitHub secret — never echo it to the terminal** (it is a full credential containing a long-lived refresh token; current sf CLI redacts it in `org display` output by default):
   ```bash
   sf org auth show-sfdx-auth-url --target-org integration --no-prompt --json | jq -er '.result.sfdxAuthUrl' | gh secret set SFDX_AUTH_URL_INTEGRATION
   sf org auth show-sfdx-auth-url --target-org uat  --no-prompt --json | jq -er '.result.sfdxAuthUrl' | gh secret set SFDX_AUTH_URL_UAT
   sf org auth show-sfdx-auth-url --target-org prod --no-prompt --json | jq -er '.result.sfdxAuthUrl' | gh secret set SFDX_AUTH_URL_PRODUCTION
   ```
   > **Repo-level, not Environment-scoped.** These secrets are set at repo level on purpose: `check-deploy.yml` validates on PRs and has no `environment:` context, so it cannot read Environment-scoped secrets — scoping `SFDX_AUTH_URL_UAT`/`_PRODUCTION` to an Environment would break the PR check against those orgs. The deploy gate is enforced by Environments + required reviewers + deployment-branch-policies (§1.4), not by secret scoping. Forked PRs never receive repo secrets; use a dedicated least-privilege integration user so a same-repo PR can't abuse them.
   > Fallback if that subcommand isn't in your CLI: `SF_TEMP_SHOW_SECRETS=true sf org display --verbose --json -o <alias> | jq -r '.result.sfdxAuthUrl' | gh secret set <NAME>`. Note this forces the secret into the JSON — keep it in the pipe, never let it hit the log.
   > `null` / `[REDACTED]` means the alias doesn't exist yet, or the value is redacted — use the command above, don't print it to screen.
   > **Security trade-off:** the auth URL embeds a **non-expiring refresh token** with the full permissions of the authenticating user. Use a **dedicated least-privilege integration user** per org (never a personal admin), and rotate/revoke it periodically. For production, JWT + Connected App is the stronger option (short-lived tokens, revoke by cert, IP-scoping) — swap `SFDX_AUTH_URL_<BRANCH>` for `SFDX_CLIENT_ID_<BRANCH>` + `SFDX_CLIENT_KEY_<BRANCH>` and `hardis:auth:login` picks it up automatically.
2. **Pin the engine image.** Both workflows run in `ghcr.io/hardisgroupcom/sfdx-hardis-ubuntu:latest`. For reproducible CI, pin a version (e.g. `:v7.x`) in `check-deploy.yml` and `process-deploy.yml`. No reusable-workflow reference to wire — the sfdx-hardis engine is self-contained in the image.
3. **Branch protection** on `integration`, `uat`, `production`: require PR + review + the two Gate A status checks. The required check **contexts are the job names**, not the workflow names: **`Check-only Deployment to Major Org`** (from `check-deploy.yml`) **and** **`MegaLinter`** (from `mega-linter.yml`).
4. **Environments** (`Settings > Environments`): create `uat` and `production`, add **required reviewers** = the approvers named in `.sf-devops.yml`. `process-deploy.yml` binds `environment: ${{ github.ref_name }}`, so a merge to `uat`/`production` blocks on those reviewers before the deploy job runs. (`integration` gets an Environment with no reviewers — the deploy runs unblocked.) Set each Environment's **deployment-branch-policy** to its own branch so only that branch can consume it.
5. **Auto-merge** (for the `integration` fast path). Enable the repo setting and set the merge PAT:
   ```bash
   gh repo edit <owner/repo> --enable-auto-merge
   # PAT with repo+workflow scope — NOT GITHUB_TOKEN (its merge won't trigger process-deploy.yml):
   gh secret set AUTOMERGE_PAT --repo <owner/repo>   # paste the token when prompted; never echo it
   ```
   Branch protection on `integration` must require the deploy check with **0 approvals** (the relaxed profile `gh-setup.sh` applies to branches without approvers) — otherwise auto-merge sits pending forever. `MegaLinter` stays advisory on `integration` (not a required check), so auto-merge only waits on deployability. `uat`/`production` are unaffected: they keep both required checks + 1 review + strict.

---

## 2. Daily developer workflow (both paths)

```bash
git checkout integration && git pull
sf hardis:work:new                       # REQUIRED FIRST: creates+switches to feature/<WI> and spins the scratch org
# (never commit while still on integration — hardis:work:new puts you on a feature branch)
bash scripts/seed-data.sh <scratch-alias> # or: sf hardis:org:data:import
# ...build, push source to scratch org, write Apex + Jest tests...
git add -p                               # review changes (avoid `git commit -am`, which auto-stages deletions)
git commit -m "feat: quote calc"
git push -u origin HEAD                  # pushes the current feature branch by its own name (no hardcoded name)
# Open PR -> integration. Gate A runs automatically; auto-merge.yml squash-merges the PR
# as soon as the deploy check is green (no reviewer needed on integration).
```
> If you accidentally committed on `integration`: `git branch feature/<WI>` → `git reset --hard HEAD~1` (only if integration isn't pushed) → `git checkout feature/<WI>` → `git push -u origin HEAD`.

---

## 3. Promotion & gates (what runs where)

| Trigger | Workflow | Gate |
|---|---|---|
| PR → `integration`/`uat`/`production` | `check-deploy.yml` | Gate A (deployability): delta + **check-only** smart deploy against the PR's target org + impacted Apex tests + Jest |
| PR → `integration`/`uat`/`production` | `mega-linter.yml` | Gate A (quality): Salesforce Code Analyzer (PMD) + ESLint + Prettier + secret scan + copy-paste detection |
| PR → `integration` | `auto-merge.yml` | Enables GitHub native auto-merge (squash); GitHub merges once the deploy check is green (integration has 0 required reviews) |
| Merge → `integration` | `process-deploy.yml` (integration) | Smart deploy to Integration + full regression |
| Merge `integration`→`uat` | `process-deploy.yml` (uat) | **Required-reviewer gate** (Environment `uat`), deploy to UAT, regression |
| Merge `uat`→`production` | `process-deploy.yml` (production) | **Required-reviewer gate** (Environment `production`), smart deploy, smoke tests |

> Both workflows authenticate the same way: `sf hardis:auth:login` reads `SFDX_AUTH_URL_<BRANCH>` for the target major branch. `check-deploy.yml` resolves the branch from the PR **base** (target); `process-deploy.yml` from the pushed branch.
> **Quick Deploy** is enabled: the PR `check-deploy.yml` validation produces a deployment ID (posted as a PR comment); on merge, `process-deploy.yml` reuses it to skip re-running tests. Set the repo variable `SFDX_HARDIS_QUICK_DEPLOY=false` to force a full deploy.
> **Auto-merge on green** (`auto-merge.yml`): on a PR into `integration` it turns on GitHub's native auto-merge; GitHub then squash-merges as soon as the required `Check-only Deployment to Major Org` check passes (integration has **0 required reviews**). It merges with **`AUTOMERGE_PAT` (a PAT with `repo`+`workflow` scope), never `GITHUB_TOKEN`** — a `GITHUB_TOKEN` merge does not trigger `process-deploy.yml`, so the deploy would silently not run. `gh-setup.sh` enables the repo "Allow auto-merge" setting and sets the secret; it also applies the **relaxed branch-protection profile** to any branch without approvers (integration): deploy check only, 0 reviews, non-strict — the gated `uat`/`production` keep both checks + 1 review + strict.
> **Delta deployment** (`useDeltaDeployment: true` in `.sfdx-hardis.yml`): a merge into a major branch deploys only the PR's committed metadata; major↔major promotions stay full. Two workflow steps make this safe and are already wired into `check-deploy.yml` / `process-deploy.yml`: (1) `git config --global --add safe.directory "$GITHUB_WORKSPACE"` — the sfdx-hardis container runs as a different user than the checkout owner, so git otherwise refuses the delta range with "dubious ownership"; (2) `sf project generate manifest --source-dir force-app --output-dir manifest --name package` — delta intersects the git delta with a base manifest, and this repo ships **no static `package.xml`** on purpose (a stale one silently drops omitted types; a missing one crashes delta with `ENOENT ./config/package.xml`), so the manifest is regenerated fresh every run. Delta also needs healthy branch topology — a feature that already contains the whole target yields an empty (no-op) delta; keep the `feature → PR → merge` flow.

---

## 4. Rollback & hotfix

- **Rollback:** no native rollback. Revert the merge commit on `production`, re-run the deploy of the prior state. Data changes may need a compensating SFDMU load. Tag `production` before every prod deploy.
- **Hotfix:** `git checkout -b hotfix/ID production` → PR to `production` → deploy → merge back to `uat` and `integration`.

---

## 5. Per-project onboarding checklist

- [ ] `config/.sf-devops.yml` filled (name, devhub.alias, sandbox types, approvers).
- [ ] `config/.sfdx-hardis.yml` filled (installedPackages); `config/branches/.sfdx-hardis.<branch>.yml` targetUsername set for `integration`/`uat`/`production`.
- [ ] Dev Hub authenticated; `preflight.sh` green.
- [ ] SFDMU plan reviewed in `data/sfdmu/` (anonymization rules + stable external IDs).
- [ ] `SFDX_AUTH_URL_INTEGRATION`/`_UAT`/`_PRODUCTION` secrets set (repo-level); engine image pinned in the workflows.
- [ ] `AUTOMERGE_PAT` secret set (PAT with `repo`+`workflow` scope) and repo "Allow auto-merge" enabled.
- [ ] `bash scripts/gh-setup.sh` run (or manual equivalent): per-branch branch protection — `uat`/`production` require `Check-only Deployment to Major Org` + `MegaLinter` + 1 review, `integration` requires the deploy check + 0 reviews; Environments `uat`/`production` with required reviewers; `SFDX_HARDIS_QUICK_DEPLOY` variable set; auto-merge enabled.
- [ ] (Brownfield) framework overwrites reconciled via `git diff`; source baselined against the org.
