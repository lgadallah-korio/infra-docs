# Audit Findings Response: Critical Items
<!-- Source: audit_findings_risk_prioritization.xlsx -->
<!-- Date: 2026-03-26 -->

This document summarises the nine Critical-rated findings from the audit
findings spreadsheet and provides infrastructure-specific context and
recommended remediation steps for each. Findings are grouped by the two
themes that the audit identified: Change Management and Identity & Access
Management.

---

## Theme 1: Change Management

**Findings:** F-004, F-022, F-023, F-024

These four findings share a root cause: no formal risk classification or
impact assessment sits on top of the existing technical promotion pipeline.
The pipeline itself is sound; what is missing is a documented governance
layer on top of it.

### What already exists (leverage this)

- The `dev -> test -> platform -> staging -> prod` promotion pipeline is
  already a de facto change control mechanism for application code. It
  needs to be formalised, not replaced.
- The sub-environment pipeline (`configure -> preview -> validate -> accept
  -> my`) maps directly onto the client validation lifecycle and serves as
  the GxP stage gate. What is missing is a documented classification
  decision at the *entry* of each promotion.
- GitOps via ArgoCD means every application change is a git commit, giving
  an existing audit trail.

### F-022 / F-023 — Risk classification layer on the existing pipeline

**Gap:** SOP-IT-002 does not distinguish between GxP-impacting and
non-GxP changes, has no emergency change path, and the scope review in
Section 6 does not require GxP, validation, security, data integrity, or
RTO/RPO impact assessments. No Change Advisory Board (CAB) is defined.

**Recommended steps:**

1. Define a change taxonomy and apply it as a required field in PR
   templates for the repos that govern production state:
   `argocd`, `kubernetes-manifests`, `terraform-infra`,
   `presto-besto-manifesto`.

   | Category | Examples | Review required |
   |---|---|---|
   | GxP-impacting | NGINX routing changes; any service deployed to `validate`/`accept`/`my`; Terraform touching Atlas or Key Vault | CAB sign-off + validation impact assessment |
   | Infrastructure | AKS, Terraform, ArgoCD bootstrap | Peer review + security impact assessment |
   | Emergency | Security hotfix, critical production outage | Expedited oral CAB approval; written follow-up within 24 hours |
   | Non-GxP | `dev`/`test` only; observability; tooling | Standard peer review |

2. NGINX routing changes warrant special attention: a misconfigured
   routing rule silently sends a client to the wrong service version.
   Any PR touching NGINX config in production must require explicit CAB
   sign-off regardless of other classification.

3. Establish a CAB with representatives from DevOps, Engineering, Client
   Services, and (for GxP-impacting changes) QA/Regulatory. Define quorum
   and an async approval path for non-business-hours emergency changes.

### F-004 — Third-party change control

**Gap:** No risk-based change control process exists for third-party
systems.

**Recommended steps:**

1. Enumerate the third-party systems with GxP relevance and assign an
   internal owner responsible for monitoring vendor-initiated changes:

   | System | GxP relevance | Owner |
   |---|---|---|
   | Azure Entra B2C | High (auth, MFA) | DevOps |
   | MongoDB Atlas | High (clinical data) | DevOps |
   | Cloudflare | Medium (WAF, DNS) | DevOps |
   | Twingate | Medium (network access) | DevOps |
   | GitHub Actions | Medium (CI/CD pipeline integrity) | DevOps |
   | ArgoCD | Medium (deployment pipeline) | DevOps |
   | Azure AKS | Medium (compute platform) | DevOps |
   | Datadog / PagerDuty | Low (observability) | DevOps |

2. For each high-relevance system, define: (a) how Korio is notified of
   vendor-initiated changes, (b) what validation/regression testing is
   required before accepting an update, and (c) what the rollback path is
   if an update causes a regression.

3. Define an expedited emergency path for vendor-side incidents (e.g., an
   Atlas-forced maintenance window): oral CAB approval acceptable, followed
   by written documentation within 24 hours.

### F-024 — Rollback strategy

**Gap:** No rollback plan is required before production deployment.

> **Important:** The statement "rollback = git revert + ArgoCD sync" is
> only accurate for code-only changes. It does not apply when MongoDB data
> has been modified by the new version of the code. These are fundamentally
> different scenarios and must be treated separately in the SOP.

#### Code rollback vs. data rollback

A `git revert` + ArgoCD sync rolls back the *running container image*. It
does nothing to MongoDB. The risk depends on what the deployed code did
during its runtime window:

| Scenario | Description | Rollback viability |
|---|---|---|
| A: Code only | Pure logic change; no schema or data effect | Git revert + ArgoCD sync. Works. |
| B: Additive schema | New optional fields written; old code ignores them (schemaless) | Code rollback works; documents are in mixed state. Usually survivable. |
| C: Destructive schema / data migration | Field renamed, document restructured, data migrated | Code rollback alone makes things worse. Requires Atlas PITR + cluster restore + redeploy + Key Vault re-sync. Planned downtime required. |
| D: Irreversible business event | Patient randomised, supply shipment triggered, audit trail entry written | No technical rollback. Requires a compensating transaction and regulatory documentation. |

Scenario D is particularly relevant for an IRT platform: many clinical
trial operations are intentionally irreversible. Regulatory requirements
may actively prohibit rolling back certain records.

#### Atlas PITR constraints

Atlas Point-in-Time Recovery (PITR) is available on production clusters
but has significant constraints:

- Restores the **entire cluster** -- a single-database or
  single-collection restore is not possible.
- For production, each sub-environment has its own Atlas cluster
  (`vozni-prod-{subenv}`). A PITR on `vozni-prod-validate` rolls back
  *all* services using that cluster, not just the one service being
  reverted.
- Restore requires downtime or provisioning a new cluster from the
  snapshot (O(minutes to tens of minutes) depending on data volume).
- After any Atlas restore, the MongoDB connection URI in the
  sub-environment's Azure Key Vault must be manually verified and
  re-synced if necessary (see `infrastructure.md` -- MongoDB Atlas
  Credential Management). This is a silent failure mode: if the Key Vault
  URI is out of sync with the restored cluster's credentials, every pod
  connecting to MongoDB will fail without any warning from Terraform or
  ArgoCD.

#### Recommended rollback procedure by change category

Each change request must declare its category before approval. The
category determines the required rollback plan:

**Category A/B (code-only or additive schema):**
1. Record the current ArgoCD application revision (commit SHA) in the
   change ticket before deployment.
2. Rollback: `git revert <commit>` on the relevant branch; ArgoCD
   auto-syncs within polling interval or on next webhook event.
3. Verify: confirm all affected pods are Running and passing health checks.

**Category C (destructive schema / data migration):**
1. Record the Atlas PITR timestamp (UTC) immediately before deployment
   begins. Store this in the change ticket.
2. Rollback requires planned downtime. Steps:
   a. Scale down all services that connect to the affected Atlas cluster.
   b. Initiate Atlas PITR restore to the recorded timestamp.
   c. After restore completes, verify Key Vault URI is consistent with
      the restored cluster's credentials. Re-sync if needed
      (see `infrastructure.md`).
   d. Redeploy the previous container image via git revert + ArgoCD sync.
   e. Scale services back up. Verify connectivity and pod health.
3. Estimated RTO: 30-60+ minutes. Must be declared in the change ticket
   and communicated to affected clients.

**Category D (irreversible business event):**
1. No technical rollback. Document the compensating transaction procedure
   specific to the operation (e.g., how to record a correction to a
   randomisation event).
2. Notify QA/Regulatory. Regulatory documentation required.

#### Forward-compatible schema changes (long-term)

The most effective way to reduce reliance on Category C rollbacks is to
enforce the **expand-contract (parallel change) pattern** as a development
standard:

1. **Expand**: Deploy new code that reads both old and new schema shapes
   and writes the new shape. Old code continues to function correctly on
   the same database.
2. **Migrate**: Background job or lazy-on-read migration moves existing
   documents to the new shape.
3. **Contract**: Remove old schema support after the rollback window has
   elapsed and stability is confirmed.

This pattern is also the prerequisite for any future blue-green deployment
capability: if old and new code can both read the current schema, traffic
can be cut over at the NGINX routing layer without a database operation.

---

## Theme 2: Identity and Access Management

**Findings:** F-002, F-003, F-013, F-014, F-015

### F-002 — RBAC matrix

**Gap:** No formal RBAC matrix exists. Access provisioning outside RBAC
is not governed by a defined process.

**Recommended steps:**

1. Build the RBAC matrix across all systems. Minimum surface area to
   document:

   | System | Current state | Gap / action |
   |---|---|---|
   | ArgoCD | Terraform-defined: `devops-team` Entra group = admin; `Engineering` / `ClientServices` = `role:user` | `role:user` has exec terminal access to production pods. Disable exec in prod or restrict to `role:admin` only. |
   | Azure (AKS, Key Vault, subscriptions) | Azure RBAC, partially managed by Terraform | Audit which identities have `Key Vault Secrets User` or higher on prod Key Vaults. Developer interactive access to prod Key Vaults should be removed. |
   | MongoDB Atlas | One DB user per sub-env (Terraform-managed); admin/integration users are manual | No Terraform tracking of admin users; no documented review process. Enumerate and document. |
   | GitHub | Org teams control ArgoCD access and CI/CD triggers | Audit `korio-clinical:devops` and `deploy-{env}` team membership. Remove anyone who does not operationally require prod access. |
   | Cloudflare | Unknown | Enumerate account members and roles. |
   | Twingate | Unknown | Enumerate who has access to which private subnets. |
   | Datadog | Unknown | Enumerate roles and API key owners. |
   | PagerDuty | Unknown | Enumerate admin accounts. |

2. ArgoCD exec terminal (`role:user` can exec into pods) is the highest
   near-term risk. It effectively gives all members of the `Engineering`
   and `ClientServices` Entra groups shell access to running production
   containers. This should be addressed immediately by setting
   `server.exec.enabled: false` in the ArgoCD Helm values for the prod
   environment, or by restricting exec to `role:admin`.

3. Define exception handling (access outside the matrix), provisioning and
   deprovisioning procedures, and a periodic review cadence (at minimum
   annually; quarterly recommended for prod access).

### F-003 / F-013 — MFA

**Gap:** MFA requirements are not formally defined or consistently
implemented. The SOP documents MFA as a "shall" / "should" requirement
but it is not enforced across all systems. A prior client audit identified
this gap.

**Context:** Azure Entra B2C handles *end-user* MFA for application
logins. The audit gap is *staff* MFA for administrative access to the
platform itself. These are separate concerns.

F-013 notes a planned migration away from B2C. The `idp-migration.md`
document records MFA (TOTP preferred) as a hard functional requirement
(F-4) for the replacement IdP. The migration is the right long-term fix,
but an interim state must be documented for the audit.

**Recommended steps:**

1. **GitHub (immediate):** Enforce MFA at the `korio-clinical` org level
   for all members. This is a single org setting and cascades to ArgoCD's
   GitHub SSO connector.

2. **Azure Entra (staff accounts):** Enable a Conditional Access policy
   requiring MFA for all Azure portal logins and Entra-authenticated
   service logins (ArgoCD's Microsoft connector, developer workstation
   logins).

3. **MongoDB Atlas:** Enforce MFA on Atlas UI logins for all admin users
   via Atlas organisation settings.

4. **Other SaaS:** Enforce MFA on Cloudflare, Datadog, PagerDuty, and
   Twingate admin accounts. Document the current state of each.

5. **SOP update (F-013):** Update the SOP to accurately reflect the
   *current* implemented state (B2C MFA enabled for end users; staff MFA
   at GitHub and Entra enforced as of this remediation). Reference the
   IdP migration plan as a time-bound item with a target date, not as an
   aspirational goal.

### F-014 — Access approval, review, and secrets management

**Gap:** Access approval and review processes are not clearly defined.
Who approves, who reviews, and where evidence is stored are all
unspecified. The majority of developers currently have production access.
Secrets management controls are insufficient. Non-DevOps staff can grant
system access.

**Recommended steps:**

1. **Immediate prod access reduction:**
   - Audit membership of: `devops-team` Entra group, `korio-clinical:devops`
     GitHub team, and `korio-clinical:deploy-prod` GitHub team. These grant
     ArgoCD admin and prod deployment rights respectively. Remove anyone
     who does not have an operational requirement.
   - Audit Azure RBAC `Owner` and `User Access Administrator` assignments
     at the subscription and resource group level. These are the identities
     that can grant further access. Restrict to a small, named set.

2. **Secrets management:**
   - The current path is: Azure Key Vault -> External Secrets Operator ->
     Kubernetes Secret -> pod environment variable. Key Vault access is the
     chokepoint.
   - Audit which Azure identities (users, service principals, managed
     identities) have `Key Vault Secrets User` or higher on prod Key Vaults.
   - Developer interactive access to prod Key Vaults should be removed.
     Access should flow through automated pipelines only.
   - "Manage through Prod Argo" (referenced in the finding) means restricting
     who can modify ArgoCD Application/ApplicationSet definitions in prod,
     which controls what secrets are mounted into pods. Tighten this to
     `role:admin` only.

3. **Access process documentation:**
   - Define: who can approve access requests (named roles, not individuals),
     required approval for each system tier, how approvals are evidenced
     (Jira ticket, email, etc.), and the deprovisioning trigger (offboarding,
     role change, contract end).
   - Define a periodic review cadence. At minimum: prod access reviewed
     quarterly; all other access reviewed annually.
   - Note: WI-IT-004 is referenced in the finding as already defining access
     reviews. Verify this work instruction is current and consistent with
     the steps above.

### F-015 — Contractor device management

**Gap:** SOP contradictions leave contractor device management undefined.
Contractors (Pogos) are not issued company laptops. MDM is not enforced as
a login condition. Client auditors have flagged this.

**Current state:**
- Contractors have read-only prod access.
- Pogos supplies and manages contractor laptops under their own MDM.
- Korio has Azure Intune MDM available but not enforced as a Conditional
  Access condition.

**Recommended steps:**

1. **Conditional Access (MDM enforcement):** Implement an Azure Entra
   Conditional Access policy requiring device compliance (MDM-enrolled and
   compliant) for all logins to Korio's Azure resources and
   Entra-authenticated services. This directly addresses the suggestion in
   the finding ("Can we change EntraID domain so people can't log in unless
   MDM is installed?").

2. **Contractor device path:** Two options for Pogos-managed devices:
   - Option A: Require Pogos to register contractor devices in Korio's
     Entra tenant as compliant B2B guest devices. Pogos attests compliance;
     Korio's Conditional Access policy then applies.
   - Option B: Define Pogos's own MDM attestation as an acceptable control
     by contract, and scope Conditional Access to exclude the Pogos guest
     account group with a documented compensating control.

3. **SOP update:** Resolve the contradiction between Sections 5.2.5 and
   5.3. Define a single, unambiguous policy for contractor devices that
   covers: device ownership, MDM requirement, what data can be accessed
   from non-corporate endpoints, and what happens if a contractor device is
   lost or stolen.

4. **Access scope review:** Review and reduce contractor permissions to
   the minimum required. Read-only prod access should be further scoped to
   specific namespaces or ArgoCD projects where possible.

---

## Summary: Suggested Remediation Priority

All findings are rated P1 (0-30 days). Sequencing by effort and blast
radius:

| Priority | Action | Finding(s) | Effort |
|---|---|---|---|
| 1 | Disable or restrict ArgoCD exec terminal in prod | F-002 | Low |
| 2 | Enforce MFA at GitHub org level | F-003, F-013 | Low |
| 3 | Audit and reduce prod access (ArgoCD admin, Key Vault, Atlas) | F-014 | Low-Medium |
| 4 | Add GxP impact classification field to PR templates | F-022, F-023 | Low |
| 5 | Document rollback procedure by change category (including Atlas PITR path) | F-024 | Medium |
| 6 | Draft RBAC matrix (initial enumeration across all systems) | F-002 | Medium |
| 7 | Enable Conditional Access / MDM enforcement for staff | F-015 | Medium |
| 8 | Define expand-contract schema change standard | F-024 | Medium (process) |
| 9 | Update SOP to reflect actual MFA implementation state and migration plan | F-013 | Low |
| 10 | Define CAB and formalise third-party change control | F-004, F-023 | Medium |
