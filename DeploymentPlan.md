# Three-Phase Cloud Platform Deployment Plan

---

## Phase 1: Manual Bootstrap (ClickOps / CLI) of Tooling & Identities

*Goal:* Establish minimum foundation so Terraform and GitOps can take
over as soon as possible.

### Establish Azure Entra tenant and define directory structure

#### Directory Structure for Microsoft Entra ID (Azure AD)

- Tenants: Is this a single-tenant or multi-tenant (e.g.,
  dev/test/prod split)?
- Management Groups: Used to apply policies across multiple
  subscriptions
- Subscriptions: How are workloads segmented? (e.g., by environment,
  team, business unit)
- Entra Groups: Logical user/group/app structure (e.g.,
  `devops-admins`, `ci-agents`, `app-readers`)
- Role Assignment Structure: Define access patterns: (prefer
  group-based RBAC over individual assignments)
- Naming Conventions (e.g. `rg-<env>-<app>`, `sub-<team>-<env>`,
  `kv-<region>-<env>`)

#### Directory Structure for Git Repos and Terraform Projects

- Enable separation of concerns between
  infrastructure/application/security domains
- Support modular state, pipelines, and team ownership
- Scale easily to new environments or components

#### Outputs

- Entra AD: Diagram or list of tenants, groups, subscriptions
- Terraform: A standardized folder structure and naming convention
- GitHub: Repo layout for infra vs app, with team access defined
- Secrets: Plan for secret scoping and naming across environments
- Backends: Mapping of each project to a unique backend key

### Register Terraform backends (e.g. Azure Storage + state locking)

In a modular, multi-repo infrastructure setup (like this), each
Terraform repository or logical project should have its own state
file.

- Isolation and Scope Control: Each state file should track only the
  resources managed by that repo. This reduces the blast radius of a
  terraform apply and makes plans faster and more understandable.
- Parallelism: Separate state files allow safe concurrent execution of
  Terraform runs.
- Shared state would force serialization or risk race conditions.
- Separation of Responsibilities: Infra and App teams may own
  different modules (e.g., `networking`, `aks`, `app`). Separate state
  files allow independent workstreams and pipeline scopes.
- Security: State files can contain sensitive info (e.g., secret IDs,
  connection strings). Granular state files allow you to lock down
  access more precisely.

#### Outputs

- Remote backend storage provisioned: Typically an Azure Storage
  Account created specifically to hold .tfstate files.
- Backend container or bucket created: In Azure: a blob container
  (e.g., tfstate) created to store state files, often separated by
  environment or project using path prefixes.
- State locking mechanism configured: For Azure: blob leases provide
  locking by default.
- Access control for backend: Roles (e.g., Storage Blob Data
  Contributor) assigned to Terraform users or service principals to
  control read/write access to state.
- State encryption at rest and in transit: Ensured by storage backend
  configuration — SSE (Server-Side Encryption), TLS enforcement, etc.
- Backend configuration template committed: Each Terraform repo
  contains a standardized backend.tf (or integrated in main.tf)
  pointing to the correct backend with correct naming and key.
- Naming and directory conventions defined: Agreed-upon structure for
  organizing state keys by project and environment (e.g.,
  network/dev/terraform.tfstate).
- Remote backend initialized and verified: Terraform init successfully
  completed and remote backend fully functional for at least one test
  project.

### Create GitHub organization/repositories for infrastructure and application code

The creation of GitHub repositories could be accelerated by using the repo template feature.

#### Outputs

- GitHub Organization(s): One or more GitHub orgs (e.g., `acme-infra`,
  `acme-app`) to logically separate infra/app ownership or
  public/private concerns.
- Repository structure: A clear and agreed-upon directory and
  repository layout
- Repository naming conventions: Consistent repository names (e.g.,
  `terraform-network`, `infra-aks`, `app-userservice`) with environmental or
  regional suffixes if needed.
- Team permissions: GitHub teams (e.g., `infra-admins`, `app-developers`)
  created and assigned roles per repo (read/write/admin).
- Repo initialization: Each repo contains the initial `README`, `license`,
  `.gitignore`, and optionally bootstrapped scaffolding (e.g., Terraform
  backend config, ArgoCD app manifests).
- CODEOWNERS files: Repo-specific or global `CODEOWNERS` to enforce
  review policies and ownership boundaries.
- Branch protection rules: Enforced on `main`, production, or release
  branches to prevent force pushes, require PR reviews, and trigger CI
  pipelines.
- GitHub Actions configured: Initial CI/CD workflow files committed or
  referenced via reusable workflows (e.g., Terraform validate/plan,
  ArgoCD sync, Helm lint).
- Repo secrets/environments: Encrypted GitHub Secrets or Environments
  set up to support workflows (e.g., `ARM_CLIENT_ID`, `GITHUB_TOKEN`,
  `DOCKER_REGISTRY_TOKEN`).
- Contribution and governance docs (Optional): `CONTRIBUTING.md`,
  `SECURITY.md`, and documentation on how to safely use the repos.

### Create initial RBAC model (Terraform access, GitHub secrets)

#### Terraform Access Model (Azure RBAC + Backend Access)

- Create Azure AD groups for roles like terraform-admins,
  terraform-developers, read-only-auditors
- Assign RBAC roles (Contributor, Reader, User Access Admin) to those
  groups on:
    - management groups
    - subscriptions
    - resource groups
- Create Service Principals or Managed Identities for automation
  (e.g., CI/CD pipelines)
- Grant automation identities appropriate roles (e.g., Contributor on
  rg-terraform-state, Reader on secrets)
- Set up Terraform state backend access:
    - Storage Account Contributor to read/write state
    - Blob Storage Data Contributor (if using RBAC)
    - Optionally: access to DB table for Terraform state file locking

#### GitHub Secrets & Role Separation for Automation

GitHub-based automation (e.g., GitHub Actions running Terraform) will
need credentials, secrets, and environment-level guardrails.

- Define GitHub Teams for infrastructure, application, security, and
  map repository-level access (admin/write/read)
- Store secrets in GitHub Actions (per repo or org):
    - `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_SUBSCRIPTION_ID`
    - `TF_BACKEND_ACCESS_KEY`
    - Optional: use OIDC instead of secrets for secure federation
- Enable environments in GitHub Actions (e.g., dev, prod) and
  configure:
    - Deployment approvals
    - Environment-specific secrets
- Grant workflow permissions for jobs to read/write secrets, approve
  deployments, or trigger jobs
- (Optional) Create shared GitHub workflows and apply fine-grained
  access controls using reusable workflows

#### Outputs

- Azure AD groups with scoped role assignments: Least-privilege access to infrastructure
- Automation identities (Service Principals or Workload Identity): Terraform CLI, pipelines, ArgoCD
- Terraform backend access controls: Secure and auditable state access
- GitHub secrets configured: CI/CD runs can authenticate securely
- GitHub environment policies: Prevent unauthorized production deployments


### Define policies for Git, Terraform, and CI/CD usage

#### Git Policies

- Enforce branch protection rules:
    - Require PR reviews
    - Require status checks (tests, terraform plan)
    - Disallow force pushes and deletions
- Require signed commits or GPG verification (optional but good for
  security)
- Define branching strategy (e.g., main, dev, feature/*)
- Create PR templates with checklists (e.g., risk review, policy
  compliance)
- Enforce `CODEOWNERS` per folder/module for RBAC-aligned review gates
- Define rules for Git submodules or monorepo structure (and enforce
  them)

#### Terraform Policies

- Enforce `terraform fmt` and `terraform validate` in PR pipelines
- Use tflint to check for:
    - Unused variables
    - Deprecated resources
    - Hardcoded secrets
    - Missing tags or naming conventions
- Use checkov, OPA, or Sentinel to enforce:
    - Environments don’t use public IPs without justification
    - Encryption is enabled on storage and databases
    - Only approved VM SKUs or regions are used
- Require manual approval or reviewer sign-off for high-impact
  changes:
    - Resource deletions
    - Production infra updates

#### CI/CD Policies (e.g., GitHub Actions)

- Require environment-based deployment approval gates:
    - Example: production environment requires manual approval
- Limit which identities (SPs or OIDC trust) can apply Terraform or
  deploy apps
- Store secrets only in secure GitHub Actions Environments, not global
  secrets
- Require workflow reviewers for production-related jobs
- Disallow untrusted or dynamic code execution (e.g., no `curl` |
  `bash`)
- Enable logging and audit trails for all workflows (review GitHub
  Actions logs, store externally if needed)
- Use reusable GitHub Actions workflows to centralize enforcement and
  reduce duplication

#### Outputs

- `.github/CODEOWNERS`: Ensures only authorized teams approve changes
- branch protection rules: Prevent direct pushes, enforce CI checks
- `tflint` / `checkov` configs: Enforce Terraform hygiene and security
- GitHub Action environments: Apply gated, policy-driven deployments
- PR template (`.github/PULL_REQUEST_TEMPLATE.md`): Enforce
  compliance, testing, and review documentation
- Optional: OPA/Policy-as-Code repo: Central policy definitions
  applied across workflows and clusters

### Set Up Initial GitHub Organization/Repos
   - Create GitHub org(s) (infra/app) and repos.
   - Define repo naming conventions and folder structures.
   - Set up initial README, .gitignore, and (optionally) initial backend.tf in each repo.
   - Define initial team permissions, CODEOWNERS, and branch protections.
   - Set up encrypted secrets/environments for CI/CD in each repo.

### Register and Configure Terraform Remote State Backend
   - Manually provision Azure Storage Account and Blob Container for state.
   - Configure access controls for Terraform users/service principals (Storage Blob Data Contributor, etc.).
   - Ensure encryption at rest/in transit.
   - Initialize remote state from a test repo: run `terraform init` for a sample backend.

### Create Initial RBAC Model for Terraform and Automation
   - Set up Azure AD groups for infra/app/automation roles.
   - Assign Contributor/Reader/User Access Admin as appropriate (scoped as narrowly as possible).
   - Create Service Principals or Managed Identities for manual Terraform runs and future CI/CD.
   - Store secrets (SP credentials, backend keys) in Key Vault and/or GitHub Secrets.
   - Define GitHub teams and repository access (admin/write/read).

### Define Git, Terraform, and CI/CD Policy Baseline
   - Enforce PR review and branch protection.
   - Define CODEOWNERS and policy-as-code.
   - Prepare Terraform linting, security, and PR check configs (e.g., tflint, checkov).
   - Write CONTRIBUTING.md and security docs.

---

## Phase 2: Manual IaC Deployment (Terraform applies by hand)

*Goal:* All subsequent resources created via code in Git, but run `terraform apply` manually as needed and in order. Can begin as soon as Phase 1 is done.

### Provision Resource Groups (IaC)
   - Use Terraform modules to create resource groups by environment/function.
   - Assign tags, budgets, RBAC, and link to management groups.
   - Apply Azure Policy definitions for governance.

### Provision Networking (IaC)
   - Define/provision VNets, subnets, NSGs, route tables, public/private IPs, private endpoints, DNS zones, peering.
   - Document topology, CIDR, and subnet strategies.

### Provision Identity and Access (IaC)
   - Create Managed Identities and Service Principals for AKS, ArgoCD, ESO, pipelines.
   - Assign RBAC for Terraform runners, AKS nodes, ArgoCD, etc.
   - Store credentials in Key Vault and GitHub Secrets as needed.
   - Assign/propagate Azure Policy, document naming conventions.

### Provision Secrets Management (IaC)
   - Deploy Key Vault(s), enable soft delete/purge protection.
   - Assign access (via MI or SP) for infra, ArgoCD, ESO.
   - Seed initial secrets (MongoDB, SendGrid, JWT, webhook secrets).
   - Document secret scope and naming; enable audit logging to Log Analytics.

### Provision Core Platform Services (IaC)
    - Provision AKS cluster(s), node pools, configure identity and networking.
    - Deploy ACR, restrict access, set retention.
    - Set up VPN/Twingate for internal-only access.
    - Validate that core platform is ready for observability and GitOps bootstrapping.

### Provision Storage & Data Layer (IaC)
    - Create MongoDB Atlas clusters, set up networking, peering, private endpoints.
    - Provision Azure Storage as needed (blobs, fileshares).
    - Store all credentials in Key Vault; sync secrets into AKS via ESO.
    - Set up connection/user scoping for all data endpoints.

### Provision Monitoring & Logging (IaC)
    - Deploy Log Analytics Workspaces, enable diagnostic settings on all key infra.
    - Deploy Prometheus, Grafana, Alertmanager (via Helm or ArgoCD, but initial config/manual apply).
    - Configure alerts (Prometheus, Azure Monitor), notification routing (PagerDuty, Teams).
    - Set up dashboards, logging standards, access controls.

### Bootstrap CI/CD & GitOps Tooling (initial)
    - Define initial GitHub Actions workflows for infra/app repos (but runs triggered manually or for validation only).
    - Optionally, deploy ArgoCD to AKS cluster (via Helm/manifest), but not yet fully automated.
    - Organize initial app manifests in Git (Helm/Kustomize), but sync manually.

---

## Phase 3: Automated CI/CD & GitOps (Full automation)

*Goal:* All further applies and deployments are automated—either via CI/CD pipeline triggers or GitOps controllers. Developers and SREs operate via PRs, code review, and automation. DR, redeployments, and ongoing changes are as code.

### Enable Full CI/CD Pipelines
    - GitHub Actions (or other CI/CD) is now trusted to `terraform plan/apply` infra repos (with approval gates for production).
    - App repos: automated builds, Docker image pushes, ArgoCD sync triggers.
    - All secrets/credentials injected securely via Key Vault, OIDC, GitHub Environments.

### Enable Full GitOps/ArgoCD Automation
    - ArgoCD is now the source of truth for all application workloads, dashboards, monitoring rules, and secrets injection (via ESO).
    - All updates to app configs and infra Helm charts are made via PR to Git.
    - ArgoCD synchronizes state to cluster automatically; manual intervention only for exceptions.

### Automated Ingress, DNS & Security Edge
    - Ingress controllers, TLS certs (cert-manager), DNS zones/records, Cloudflare WAF are all managed as code, with GitOps and CI/CD pipelines updating as needed.
    - All perimeter and internal routing/security changes are made as PRs to Git, reviewed and merged.

### Automated Application & Supporting Service Deployments
    - All microservices, SaaS integrations (RabbitMQ, SendGrid, Intercom, etc.), and supporting tools are deployed via Helm/Kustomize/ArgoCD, and secrets/config are managed through Key Vault and ESO.
    - All changes and updates are automated and auditable.

### Post-Deployment Validation (Automated or Assisted)
    - Automated smoke tests, platform validation, and monitoring/alert checks.
    - Security/access validation (e.g., SSO, RBAC, WAF, scanner results).
    - Team onboarding: assign access, validate dashboards, document hand-off.
    - Document, log, and sign off on deployment; prepare for operational handoff and DR runbook update.

---

## Summary Table: Phase Mapping

| Phase | Steps (from your plan)                    |
|-------|------------------------------------------|
| 1     | 11.2.0 (all substeps)                    |
| 2     | 11.2.1 – 11.2.6, 11.2.7 (initial), 11.2.8 (bootstrap), portions of 9–11 as needed |
| 3     | 11.2.7 (full automation), 11.2.8 (full), 11.2.9 – 11.2.12                    |

---

### Key Guidance for Transition

- **Move to Phase 2 (Manual IaC)** as soon as Terraform backend and minimum identities/secrets are in place.
- **Move to Phase 3 (Automation)** as soon as platform is validated and CI/CD & GitOps tools are deployed and tested.
- **Document exact “handoff” and criteria for each phase** in your BCDR plan or onboarding playbook.
