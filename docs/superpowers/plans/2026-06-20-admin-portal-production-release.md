# Omnichannel Admin Portal Production Release Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely deploy and verify the Omnichannel Admin Portal in the production environment with automated staging E2E gatekeeping.

**Architecture:** Deploys the built adapter images to the staging VM via a GitHub Pull Request workflow, validates routes and APIs using Playwright, and then merges to main to deploy to the production VM.

**Tech Stack:** GitHub Actions, Playwright, Terraform, Bash, Docker, Fastify

---

### Task 1: Pre-Merge Local Validation

Verify the local code state, compile typescript services, and run integration tests.

**Files:**
- Modify: `middleware/tsconfig.json`
- Modify: `onboarding/tests/15-admin-portal.spec.ts`

- [x] **Step 1.1: Verify TypeScript Compilation and Build**
  Build the middleware adapter locally to verify copy scripts and TypeScript compilation.
  *Run:*
  ```bash
  cd middleware && npm run build
  ```
  *Expected Output:* Successful compilation with `dist/public/index.html` created.

- [x] **Step 1.2: Execute Typecheck**
  Ensure all files are type-safe.
  *Run:*
  ```bash
  cd middleware && npm run typecheck
  ```
  *Expected Output:* Command completes successfully with `exit code 0` and no type errors.

- [x] **Step 1.3: Run Playwright Admin Portal E2E tests**
  Execute the unit mock test suite locally.
  *Run:*
  ```bash
  cd onboarding && npx playwright test tests/15-admin-portal.spec.ts
  ```
  *Expected Output:* `8 passed` in terminal logs.

- [x] **Step 1.4: Commit any leftover workspace files**
  Commit all changes to ensure a clean branch state.
  *Run:*
  ```bash
  git status
  ```
  *Expected Output:* `nothing to commit, working tree clean` (if not clean, run `git add .` and `git commit`).

---

### Task 2: Push Branch and Open Pull Request

Publish the feature branch to trigger the staging deployment pipeline.

**Files:**
- Modify: `.github/workflows/deploy.yml`

- [ ] **Step 2.1: Push the local branch to GitHub**
  Push `feat/admin-portal` to the origin remote repository.
  *Run:*
  ```bash
  git push origin feat/admin-portal
  ```
  *Expected Output:* Branch pushed to `origin/feat/admin-portal`.

- [ ] **Step 2.2: Open a Pull Request targeting main**
  Instruct the user or use GitHub CLI to open a Pull Request targeting `main`.
  *Run:*
  ```bash
  gh pr create --title "feat(admin-portal): implement omnichannel admin portal" --body "Implements visual admin portal, routing, provisioning, and e2e playwright verification tests."
  ```
  *Expected Output:* Pull Request URL generated.

---

### Task 3: Staging Deployment and Automated Verification

Monitor and audit the staging pipeline.

**Files:**
- Modify: `.github/workflows/deploy.yml`

- [ ] **Step 3.1: Monitor GitHub Actions run**
  Watch the GitHub Actions workflow run for the pull request.
  *Run:*
  ```bash
  gh run watch
  ```
  *Expected Output:* Job `build-images` succeeds, followed by `tenant` (applying terraform/compose configuration to the staging VM), and `validate` runs successfully.

- [ ] **Step 3.2: Verify Playwright matrix validation outputs**
  Verify that the tests passed against the staging URL.
  *Run:* Check run summary logs for the `validate` job.
  *Expected Output:* All tests (including `15-admin-portal.spec.ts`) complete successfully.

---

### Task 4: Staging Manual Smoke Audit

Manually verify basic authentication and aesthetics in the staging environment.

**Files:**
- Create: `onboarding/tests/15-admin-portal.spec.ts`

- [ ] **Step 4.1: Access Staging Auth Gate**
  Open the staging browser page at `https://middleware-stg.nexaduo.com/admin` without credentials.
  *Expected Output:* Browser displays basic authentication prompt (returns `401 Unauthorized` raw).

- [ ] **Step 4.2: Login and Verify Landing UI**
  Login using `admin` username and the staging `ADMIN_PASSWORD` (retrieved from GCP Secret Manager).
  *Expected Output:* Landing page is loaded with "Selecione o Tenant de Destino" and shows the dynamic environment cards.

- [ ] **Step 4.3: Verify Dashboard & Table Rendering**
  Click on a tenant card (e.g., `/admin/nexaduo`).
  *Expected Output:* Dashboard page renders with:
  * Glassmorphism dark mode styles.
  * Tenant active accounts table loaded dynamically.
  * Provisioning form with fields: Account Name, Email, Admin Name, Subdomain, Dify Key, App Type.

---

### Task 5: Production Deployment and Verification

Merge to main to deploy changes to the production VM.

**Files:**
- Modify: `infrastructure/terraform/envs/production/tenant/main.tf`

- [ ] **Step 5.1: Merge the Pull Request**
  Merge the approved staging pull request on GitHub to trigger production deployment.
  *Run:*
  ```bash
  gh pr merge --merge --auto
  ```
  *Expected Output:* PR merged to `main` branch.

- [ ] **Step 5.2: Monitor Production pipeline run**
  Monitor the `push` event workflow run on `main`.
  *Run:*
  ```bash
  gh run watch
  ```
  *Expected Output:* Image publication, production Terraform apply, and production Playwright validation complete with exit code 0.

- [ ] **Step 5.3: Verify Production Admin Portal**
  Open `https://middleware.nexaduo.com/admin` in the browser and authenticate.
  *Expected Output:* Portal renders production tenants, handles provisioning requests, and checks connection states correctly.
