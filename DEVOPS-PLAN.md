# Salesforce DevOps Framework — Reference Plan

> Reusable, config-driven CI/CD for Salesforce projects (team of N developers).
> One framework, many projects: per-project variability lives in a config file, not in forked pipelines.
> Status: design. Revisit each decision against org constraints before implementing.

---

## 0. Reusable framework architecture

The framework is **not** a per-project pipeline. It is:

1. **A template repo** (`sf-devops`) — branching model, folder layout, quality configs (MegaLinter / Code Analyzer, ESLint, Prettier, secret scan), and a project config file.
2. **Self-contained CI workflows** — the sfdx-hardis native workflows (`check-deploy.yml`, `mega-linter.yml`, `process-deploy.yml`) are copied into each project. Behaviour lives in the **sfdx-hardis engine image** (pinned, versioned) and in config, not in the YAML — so the shared, upgradable component is the engine, not a cross-repo reusable workflow. *(Trade-off: a workflow-YAML change does not auto-propagate to existing projects; re-run `adopt.sh` or re-copy the template to pick up structural changes.)*
3. **A per-project config file** (`config/.sf-devops.yml`) — the only thing that changes between projects. The engine reads it (plus `config/.sfdx-hardis.yml`) and adapts.

**All the "some projects have X, others don't" questions are answered the same way: declare it in config, the engine branches on it.**

Two files, clean separation of concerns:

```yaml
# config/.sf-devops.yml — POLICY OVERLAY (what the framework enforces on top of hardis)
project:
  name: acme-crm
devhub:
  required: true                 # preflight fails fast if Dev Hub not reachable
  alias: DevHub
scratchOrg:
  definitionFile: config/project-scratch-def.json
environments:
  uat:
    sandboxType: Full            # Full | Partial  → drives seeding volume + perf tests
    approvers: [gh-team:acme-qa] # designated team/person (GH Environment reviewers)
  production:
    approvers: [gh-team:acme-release-managers]
dataSeeding:
  configDir: data/sfdmu          # SFDMU export.json + anonymization rules
  targets: [scratch, sandbox-after-refresh]
```

```yaml
# config/.sfdx-hardis.yml — ENGINE (sfdx-hardis owns deploy/delta/packages/branches)
developmentBranch: integration
installedPackages: []            # empty => nothing installed; else hardis installs automatically
majorBranches: [integration, uat, production]
# per-branch org mapping in config/branches/.sfdx-hardis.<branch>.yml
```

### How each variability point is handled

| Point | Mechanism |
|---|---|
| **Dev Hub must be enabled first** | `devhub.required: true` → **preflight job** runs `sf org list --json` / `sf limits api display` against the Dev Hub and **fails fast** with a clear message before any scratch-org step. Enabling Dev Hub is a one-time manual org action, documented in the setup runbook — the framework verifies, it doesn't enable. |
| **Full vs Partial sandbox** | `environments.uat.sandboxType`. The pipeline branches: **Partial** → functional regression only, lighter SFDMU seed; **Full** → adds performance/volume tests, larger seed, and a stricter refresh cadence. Same pipeline, config-selected path. |
| **Managed packages or not** | `installedPackages` in `config/.sfdx-hardis.yml`. **Empty → nothing installed.** Non-empty → sfdx-hardis installs each dependency into new scratch orgs and sandboxes automatically during scratch create / deploy. |
| **UAT / prod approval** | `approvers` map to **GitHub Environment required reviewers** (+ `CODEOWNERS`). The designated team/person is named per project in config; the framework enforces the gate mechanism. No approver in config = pipeline refuses to promote (fail-closed). |
| **Data seeding (SFDMU)** | `dataSeeding` → SFDMU step runs after scratch-org create and after sandbox refresh. See §5.1. |

---

## 1. Foundational decisions (settle these first)

| Decision | Recommendation | Why |
|---|---|---|
| Source of truth | **Git, source-tracked** | Org is a deployment target, never the master. |
| Dev environments | **Scratch orgs** (Dev Hub) per developer/feature | Reproducible from source; disposable; kills config drift. Fall back to Developer sandboxes only if a feature can't be captured as source. |
| Packaging model | **Org-based (metadata) to start → migrate to 2GP unlocked packages** as modules stabilize | Metadata deploys are simpler to bootstrap; packages give versioning + dependency mgmt once the codebase modularizes. Don't force packages on day 1. |
| Access model | **Permission-set-first, profiles minimal** | Profiles are merge-hostile and env-coupled. |
| Config that can't live in source | Documented per-env runbook: Connected Apps/secrets, Named Credentials, Remote Site/CORS, some Flow activations | Prevents "works in UAT, missing in prod" surprises. |
| Env-specific values | **Custom Metadata Types / Custom Settings**, values set per env | Same metadata promotes; values differ. Never hardcode endpoints. |

---

## 2. Environment topology

```
Scratch orgs (ephemeral, per feature)
        │  push/pull source-tracked
        ▼
[ CI validation org ]  ← spun per PR, or persistent CI scratch org
        │
        ▼
   integration branch ──► deploy to  Integration sandbox (Developer/Dev Pro)
        │
        ▼
   uat branch ─────────► deploy to  UAT sandbox (Full or Partial*)
        │                          (+ human acceptance sign-off)
        ▼
   production branch ──► deploy to  Production org (gated by required reviewers)
```

\* **Partial Copy** = sampled data, size caps — fine for functional UAT. Use **Full sandbox** when you need prod-like data volume / performance testing. Define **refresh cadence** (e.g. Full refreshed each release, seeded post-refresh) and a **post-refresh seeding script** (anonymized test data).

### 2.1 Scratch orgs — constraints & developer workflow rules

Developers work in a **scratch org per feature** (not persistent Developer Edition orgs). Consequences:

**Dev Hub allocation limits** (edition-dependent — confirm per Dev Hub; raisable via the Scratch Org add-on):

| Dev Hub edition | Active | Daily creations |
|---|---|---|
| Developer Edition / Trailhead Playground | ~3 | ~6 |
| Enterprise | ~40 | ~80 |
| Unlimited / Performance | ~100 | ~200 |

"Daily" resets every 24h and **deleting an org does not refund the daily count**; "active" is the concurrent ceiling.

**Structural restrictions:**
- **Ephemeral, max 30-day lifespan** (default 7). Expired = gone, no recovery.
- **Not a data/metadata copy** — empty shell built from `project-scratch-def.json`; must deploy source + install packages + seed data (SFDMU) each time.
- **Small limits** (~200 MB data / ~50 MB file) and reduced governor headroom → can mask limits you'd hit in prod. Not prod-like — this is *why* the UAT sandbox stage still exists.
- **Feature-gated:** every capability must be declared in the scratch def; some features and managed packages are unsupported in scratch orgs.
- **2GP:** requires `Enable Unlocked and 2GP Packages` on the Dev Hub + a linked namespace.

**Work-in-progress rules (mid-feature, bug not finished, end of day):**
- **The scratch org is not storage** — source of truth is local files + git. Un-pulled/uncommitted work is **lost** if the org expires or the machine dies; scratch orgs are never backed up.
- **Committing is not mandatory to keep working**, but commit/push WIP to your `feature/*` branch **daily as a backup**. A plain push to a feature branch triggers **no gate** (`check-deploy.yml` runs only on a PR to a major branch, not on feature-branch pushes), so WIP pushes are safe.
- **Across days:** stay on the same feature branch and the same scratch org (lives up to 30 days). Before expiry, `sf hardis:work:save` (pulls + cleans + stages) or `sf project retrieve start` to get changes into local source, then commit.
- A **reviewed** commit only matters when you open the PR to `integration`.

**`git checkout` is not a daily ritual:**
- `git checkout integration && git pull` runs **once at the start of a new feature** (to branch from latest). On an ongoing feature you just stay on your branch; the scratch org is not recreated daily.
- Optionally merge/rebase `integration` into your feature branch periodically to stay current — as-needed, not mandatory.
- The only recurring daily habit worth enforcing: **pull scratch-org changes to local and commit/push** — for safety, not because a gate requires it.

**Fallback:** if a Dev Hub has no/limited scratch allocation, use Developer sandboxes for dev instead — see §1.

---

## 3. Branching model (sfdx-hardis major-branch convention)

Each major branch maps 1:1 to an org (`config/branches/.sfdx-hardis.<branch>.yml`); merging into it deploys there.

- `feature/<work-item>` — one feature, short-lived. Branch from `integration`.
- `integration` — integration branch → Integration sandbox. **Features merge here first** so cross-feature conflicts surface before UAT (fixes the "feature → UAT directly" gap).
- `uat` — → UAT sandbox. PR from `integration`; merge gated by the `uat` GitHub Environment reviewers + acceptance sign-off.
- `production` — mirrors prod → Production org. PR from `uat`; merge gated by the `production` Environment reviewers. Tagged per release (`vX.Y.Z`).
- `hotfix/<id>` — branch from `production`, deploy to prod fast, merge back to `production` → `uat` → `integration`.

Rule: no direct commits to major branches; everything via PR.

---

## 4. Pipeline stages & gates

### Gate A — on every PR to a major branch (`integration`/`uat`/`production`) (fast, ephemeral)
Runs in CI (no manual org needed), split across two workflows:

**`check-deploy.yml` — deployability**
1. **Delta + check-only deploy** — `sf hardis:project:deploy:smart --check` computes the delta, simulates the deploy against the PR's target org, and runs **only impacted Apex tests** (delta-scoped) → must pass, coverage ≥ 75% (target 85% locally).
2. **LWC unit tests** — Jest (runs when a `test:unit` npm script exists).

**`mega-linter.yml` — code quality** (MegaLinter, Salesforce flavor)

3. **Static analysis** — Salesforce Code Analyzer (PMD + Graph Engine/DFA), fail on new criticals.
4. **Lint** — ESLint (LWC/Aura), Prettier check.
5. **Secrets scan** — gitleaks / secretlint.
6. **Copy-paste detection** — jscpd.

### Gate B — on merge to `integration`
- Smart deploy to **Integration sandbox**.
- **Full Apex regression suite** (all merged tests) — this is what your outline meant by "consolidate all pending features"; it's the regression run, not testing unbuilt features.
- Full Jest suite.

### Gate C — promote `integration` → `uat` → UAT sandbox
- `validateDeployRequest` (check-only) against UAT to catch env-specific failures early.
- Deploy to **UAT sandbox**.
- Full regression + smoke tests.
- **Human acceptance sign-off** (explicit approval gate) — the missing UAT owner.

### Gate D — promote to Production (manual, high-control)
- **Quick Deploy**: the PR's `check-deploy.yml` validate-only run produces a validated deployment ID (posted via PR comments); on merge, `process-deploy.yml` reuses it for a **Quick Deploy** (skips re-running tests, shortens the change window). sfdx-hardis does this automatically when PR comments are configured; `SFDX_HARDIS_QUICK_DEPLOY=false` forces a full deploy.
- Pre-flight checklist: target-org confirmation, destructive-change review, backout plan attached, approver sign-off.
- Post-deploy **smoke tests** + monitoring watch.

---

## 5. Destructive changes & rollback

- Destructive changes (`destructiveChanges.xml`) are **generated and reviewed as a separate, explicit step** — never bundled silently. Require named approval before prod.
- **No true rollback in Salesforce.** Backout = a pre-prepared *compensating deploy* (revert commit → re-deploy prior metadata). Data changes may be irreversible — call this out per release.
- Tag `production` before each prod deploy so the prior state is one `git checkout` away.

### 5.1 Data seeding with SFDMU (anonymized)

- **Tool:** SFDMU (`sfdx-hardis` wraps it, or `sf sfdmu run`). Per-project plan under `data/sfdmu/` (`export.json` + object CSVs/queries).
- **When it runs:** after **scratch-org create** (Gate A/dev) and after **sandbox refresh** (post-copy) — driven by `dataSeeding.targets`.
- **Anonymization:** SFDMU field mocking — `updateWithMockData: true` with `mockFields` (e.g. `Faker` patterns for name/email/phone, hash for external IDs). No production PII lands in lower envs. Keep the mock rules in the SFDMU config, versioned.
- **Volume by sandbox type:** Full → larger, relationship-complete dataset; Partial → trimmed dataset that respects Partial's row caps. Selected via the same `sandboxType` config.
- **Referential integrity:** SFDMU resolves lookups by external ID / `Where` — define stable external-ID fields per object to keep re-seeds idempotent.

---

## 6. Tooling stack

- **CI runner:** GitHub Actions.
- **Orchestration engine:** **sfdx-hardis** (decided). Owns delta deploys (`hardis:project:deploy:smart`), impacted-test selection, scratch orgs/pools, managed-package install (`installedPackages` in `.sfdx-hardis.yml`), branch/org mapping, monitoring, backup, and anonymized data import (`hardis:org:data:import`, wraps SFDMU). The framework adds only a thin policy overlay (`.sf-devops.yml`: approvers, sandbox type, seeding policy) on top.
- **Auth in CI:** sfdx **auth URL** per environment (`SFDX_AUTH_URL_<BRANCH>` in GH encrypted secrets, **repo-level** — the PR `check-deploy` job has no `environment:` context and cannot read Environment-scoped secrets, so scoping would break check-only against UAT/prod; the deploy gate is enforced by Environment required reviewers, not secret scope). Prod-grade hardening: switch to **JWT bearer flow + Connected App** per environment (`SFDX_CLIENT_ID_<BRANCH>` + `SFDX_CLIENT_KEY_<BRANCH>`) for short-lived tokens and cert-based revocation. `sfdx-hardis:auth:login` supports both, auth-URL first.
- **Quality:** Salesforce Code Analyzer, ESLint, Prettier, Jest, gitleaks.
- **Data seeding:** **SFDMU** (with anonymization mock rules), invoked via sfdx-hardis or `sf sfdmu run`.
- **Scratch org pooling** (sfdx-hardis or scratch-pool) to avoid daily active-scratch-org limits and cut Gate A latency.
- **Distribution:** framework shipped as a **template repo**; `bootstrap.sh`/`adopt.sh` copy self-contained sfdx-hardis workflows + a `.sf-devops.yml` config into each project (§0). The shared, versioned component is the pinned sfdx-hardis engine image, not a cross-repo reusable workflow.

---

## 7. DevOps Center (Summer '26) vs pure CI/CD on GitHub

| Dimension | **DevOps Center** | **CI/CD on GitHub (Actions + sfdx-hardis)** |
|---|---|---|
| Audience fit | Admins / low-code, click-based promotion | Senior devs, source-first ✅ (your case) |
| Gates (coverage, static analysis, lint, secrets) | ❌ No native commit gates; can't run PMD/Jest/custom checks in the flow | ✅ Fully customizable per-stage gates |
| Scratch orgs | ❌ Not part of the flow (sandbox-centric) | ✅ First-class |
| Delta deployments | Limited | ✅ `sfdx-git-delta`, granular |
| PR-based review | Weak — work items, not true PR-driven | ✅ Native PR reviews + branch protection |
| Extensibility / custom steps | ❌ Closed pipeline model | ✅ Any script/tool |
| Merge-conflict control | Abstracted away (less control) | ✅ Full git control |
| Package (2GP) support | Partial | ✅ Full |
| Setup cost | Low — clicks, managed by SF | Higher — you build/maintain workflows |
| Maintenance | Salesforce-managed | You own it |
| Cost | Free (in-org) | GH Actions minutes + scratch orgs |
| Maturity/roadmap | Still maturing; feature gaps | Industry-standard, battle-tested |

**Recommendation: pure CI/CD on GitHub (Actions + sfdx-hardis).**
Your requirements — commit-level gates for coverage/design-patterns, scratch-org dev, delta deploys, PR-based promotion — are exactly what DevOps Center *cannot* do natively. DevOps Center only wins for admin-heavy, low-code teams that want managed click-to-promote and will forgo real CI gates. A senior dev team should not accept that ceiling.

Hybrid option (rare): DevOps Center for admin/declarative streams + GitHub CI/CD for pro-code — only worth the split if you have a large low-code cohort that won't touch git.

---

## 8. Phased rollout

1. **Phase 0 — Foundation:** Dev Hub, scratch org definition, repo + branching (`integration`/`uat`/`production`), sfdx auth-URL secrets per env (JWT/Connected App as the prod-grade hardening option).
2. **Phase 1 — Gate A:** delta + Code Analyzer + Jest + scratch-org validate on PR.
3. **Phase 2 — Gate B/C:** integration + UAT deploys, full regression, acceptance sign-off.
4. **Phase 3 — Gate D:** prod quick-deploy flow, destructive-change review, backout runbook, tagging.
5. **Phase 4 — Hardening:** scratch org pools, monitoring/backup (sfdx-hardis), env-specific config via Custom Metadata, hotfix path.
6. **Phase 5 (optional):** migrate stable modules to 2GP unlocked packages.

---

## 9. Per-project onboarding checklist (fill `config/.sf-devops.yml`)

Resolved at the framework level — confirmed per project via config, not re-designed:

- [ ] **Dev Hub enabled** (manual, one-time) — preflight verifies; framework does not enable it.
- [ ] `environments.uat.sandboxType` set to **Full** or **Partial** (+ refresh window agreed).
- [ ] `packages.dependencies` listed (or empty — install step auto-skips).
- [ ] `approvers` named for UAT and Production (GitHub Environment reviewers + CODEOWNERS).
- [ ] SFDMU plan authored under `data/sfdmu/` with anonymization mock rules + stable external IDs.
- [ ] `packagingModel` chosen (`org` to start, `2gp` when modularized).
