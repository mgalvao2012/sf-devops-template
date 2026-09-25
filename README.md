# sf-devops-template

Reusable, config-driven CI/CD framework for Salesforce DX projects. One framework, many
projects: per-project variability lives in a config file, not in forked pipelines. The
orchestration engine is **sfdx-hardis** (native workflows, pinned/versioned engine image);
the framework adds only a thin policy overlay on top.

- **Architecture & decisions:** [DEVOPS-PLAN.md](DEVOPS-PLAN.md)
- **Step-by-step how-to:** [IMPLEMENTATION.md](IMPLEMENTATION.md)

## What it is

Not a per-project pipeline — three things:

1. **A template repo** — branching model, folder layout, quality configs (MegaLinter /
   Code Analyzer, ESLint, Prettier, secret scan), and a project config file.
2. **Self-contained CI workflows** — the sfdx-hardis native workflows are copied into each
   project. Behaviour lives in the pinned **sfdx-hardis engine image** and in config, not in
   the YAML — the shared, upgradable component is the engine, not a cross-repo reusable workflow.
3. **A per-project config** ([template/config/.sf-devops.yml](template/config/.sf-devops.yml)) —
   the only thing that changes between projects. The engine reads it plus
   [template/config/.sfdx-hardis.yml](template/config/.sfdx-hardis.yml) and adapts.

Every "some projects have X, others don't" question is answered the same way: declare it in
config, the engine branches on it.

## Repo layout

```
sf-devops/
├── DEVOPS-PLAN.md              # architecture & decisions
├── IMPLEMENTATION.md           # implementation guide
├── scripts/                    # framework tooling (run to onboard a project)
│   ├── bootstrap.sh            #   greenfield — new project
│   ├── adopt.sh                #   brownfield — existing DX project (git-guarded)
│   └── _copy-template.sh
└── template/                   # PAYLOAD copied into each project
    ├── config/
    │   ├── .sf-devops.yml       #   policy overlay (approvers, sandbox type, seeding)
    │   ├── .sfdx-hardis.yml     #   ENGINE config (deploy, delta, packages, major branches)
    │   ├── branches/            #   per-branch org mapping: integration / uat / production
    │   └── project-scratch-def.json
    ├── data/sfdmu/export.json   #   anonymized seed plan (SFDMU)
    ├── scripts/                 #   runtime scripts (preflight, seed-data, gh-setup, validate, lib)
    └── .github/workflows/       #   check-deploy + mega-linter (PR Gate A), process-deploy (deploy on merge)
```

## Prerequisites

```bash
npm i -g @salesforce/cli
sf plugins install sfdx-hardis sfdmu code-analyzer
brew install yq

# Dev Hub MUST be enabled in the org first (Setup > Dev Hub > Enable), then:
sf org login web --set-default-dev-hub --alias DevHub
```

The framework **verifies** the Dev Hub in preflight; it does not enable it. Enabling is a
one-time manual org action.

## Onboarding a project

Two adoption paths.

**Greenfield (new project):**

```bash
bash scripts/bootstrap.sh ../acme-crm acme-crm
```

Generates the DX project, copies the payload, sets the project name, and inits git with the
major branches `production` / `uat` / `integration`.

**Brownfield (existing project):** requires a clean git working tree.

```bash
bash scripts/adopt.sh ../legacy-project
```

Framework files overwrite in place; git is the safety net — review `git diff` and revert what
you don't want. Baseline the org's metadata into git before the first delta deploy.

After either path:

1. Fill [config/.sf-devops.yml](template/config/.sf-devops.yml) (name, `devhub.alias`,
   sandbox types, approvers) and [config/.sfdx-hardis.yml](template/config/.sfdx-hardis.yml)
   (`installedPackages`, branch/org mapping).
2. `bash scripts/preflight.sh` — confirms Dev Hub + approvers.
3. Set the auth-URL secrets and run `bash scripts/gh-setup.sh` (see [IMPLEMENTATION.md §1](IMPLEMENTATION.md)).

## Branching model

Each major branch maps 1:1 to an org; merging into it deploys there.

- `feature/<work-item>` — one feature, short-lived; branch from `integration`.
- `integration` → Integration sandbox. Features merge here first.
- `uat` → UAT sandbox. PR from `integration`; gated by the `uat` Environment reviewers + acceptance sign-off.
- `production` → Production org. PR from `uat`; gated by the `production` Environment reviewers. Tagged per release.
- `hotfix/<id>` — branch from `production`, deploy fast, merge back to `production` → `uat` → `integration`.

No direct commits to major branches; everything via PR.

## Pipeline gates

| Trigger | Workflow | Gate |
|---|---|---|
| PR → major branch | `check-deploy.yml` | Deployability: delta + check-only smart deploy against target org + impacted Apex tests + Jest |
| PR → major branch | `mega-linter.yml` | Quality: Code Analyzer (PMD) + ESLint + Prettier + secret scan + copy-paste detection |
| Merge → `integration` | `process-deploy.yml` | Deploy to Integration + full regression |
| Merge → `uat` | `process-deploy.yml` | Required-reviewer gate + deploy to UAT + regression |
| Merge → `production` | `process-deploy.yml` | Required-reviewer gate + smart deploy (Quick Deploy) + smoke tests |

## CI setup notes

- **Auth:** auth-URL everywhere (`SFDX_AUTH_URL_<BRANCH>`, repo-level secrets); JWT + Connected
  App is the prod-grade hardening option. `gh-setup.sh` applies repo secrets, Environments +
  required reviewers, branch protection, and `SFDX_HARDIS_QUICK_DEPLOY` in one idempotent pass.
- **Sequencing:** configure Environments + branch protection **before** pushing `uat`/`production`
  — a push to a major branch triggers `process-deploy.yml` immediately. `gh-setup.sh` enforces
  the safe order.
- **Required status checks are job names,** not workflow names: `Check-only Deployment to Major
  Org` and `MegaLinter`.
- **Delta deploys are on** (`useDeltaDeployment: true`): a merge into a major branch deploys only the
  PR's changed metadata (major↔major promotions stay full). The repo ships **no static `package.xml`** —
  both deploy workflows generate a base manifest from `force-app` on every run, so delta never drops a
  metadata type or crashes on a missing manifest. Requires a healthy `feature → PR → merge` topology;
  never merge the target branch back into a feature before its PR (see [CLAUDE.md](CLAUDE.md) Gotchas).
- Environment required-reviewers need a public repo **or** GitHub Pro/Team/Enterprise; `gh-team:`
  approvers require a GitHub organization (use `gh-user:<login>` on a personal account).

## Tooling stack

GitHub Actions · sfdx-hardis (engine) · Salesforce Code Analyzer · ESLint · Prettier · Jest ·
gitleaks · SFDMU (anonymized data seeding).
