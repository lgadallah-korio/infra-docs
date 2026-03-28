# Audit Findings Response: High Risk Items
<!-- Source: audit_findings_risk_prioritization.xlsx -->
<!-- Date: 2026-03-26 -->

This document covers the High-rated findings from the audit findings
spreadsheet, with infrastructure-specific context and recommended
remediation steps. Findings are grouped by workstream. P2 (30-60 day)
items precede P3 (60-120 day) items within each theme.

---

## Theme 1: Business Continuity and Disaster Recovery

**Findings:** F-010, F-028, F-029, F-030, F-031, F-032, F-033, F-035, F-045, F-047, F-050

### Infrastructure context

The platform's DR profile is shaped by several architectural facts:

- AKS clusters run in Azure US East. MongoDB Atlas clusters are hosted on
  Azure and connected via Private Link. There is no multi-region or
  active-active configuration documented.
- For production and staging, each sub-environment has its own dedicated
  Atlas cluster (`vozni-{env}-{subenv}`). Dev, test, and platform share a
  single cluster per environment. Atlas provides built-in replica sets
  (node-level HA) and Point-in-Time Recovery (PITR) with scheduled
  snapshots.
- AKS cluster infrastructure is fully reproducible via Terraform
  (`terraform-infra/env/`). A full cluster rebuild from scratch is
  possible but takes O(30-60 minutes) and requires all prerequisites
  (Key Vault secrets, TLS certs, GitHub App credentials) to be in place.
- SFTP data is persisted on Azure managed disks (per sub-env) and mirrored
  to Azure Data Lake Storage.
- Regulated study documentation lives in SharePoint (not in Azure or
  Atlas).
- GitOps means that application workload state is fully recoverable from
  git: ArgoCD re-syncs all services onto a freshly rebuilt cluster without
  manual intervention. The cluster state itself is the gap, not the
  application config.

### F-010 / F-033 — Backup schedule and restore testing (P2)

**Gap:** Backup schedule is now defined in SOP-IT-001 but restore testing
has not been validated or automated. SOP-IT-003 does not point to
SOP-IT-001 for backup details.

**Recommended steps:**

1. For MongoDB Atlas: confirm that PITR and scheduled snapshot retention
   are configured per environment in Atlas project settings. Document the
   retention window (e.g. 7 days PITR, 30-day snapshot retention) as the
   formal backup schedule in SOP-IT-001.
2. Define a restore test procedure and cadence (at minimum: annual for
   prod; semi-annual recommended). The test should demonstrate restoring
   an Atlas cluster to a known-good timestamp, verifying data integrity,
   and confirming that the sub-environment's Key Vault MongoDB URI is
   re-synced after restore (this is a manual step -- see
   `infrastructure.md`, MongoDB Atlas Credential Management).
3. For AKS: persistent volumes (SFTP disks) should have snapshot policies
   defined in Azure. Confirm these are in place or add them via Terraform
   (`terraform-infra/app/sftp_disk_storage.tf`).
4. Update SOP-IT-003 to reference SOP-IT-001 for backup schedule details
   rather than duplicating them.
5. Define where restore test evidence is stored and retained (see F-016
   / F-044 below).

### F-028 / F-045 — RTO and RPO not realistically defined per system (P2)

**Gap:** RTO (30 minutes) and RPO (15 minutes) are defined in WI-IT-002
but are not in the SOP, not justified against architecture, and likely
unachievable for infrastructure-level events.

**Realistic RTO/RPO estimates by system tier (to inform the SOP update):**

| System | Recovery scenario | Realistic RTO | Realistic RPO | Notes |
|---|---|---|---|---|
| MongoDB Atlas (prod, per-sub-env cluster) | Node failure | ~5 min | 0 (replica set auto-failover) | Atlas HA handles this automatically |
| MongoDB Atlas (prod) | Cluster-level disaster, PITR restore | 30-60 min | 15 min (PITR granularity) | Requires Key Vault re-sync post-restore |
| MongoDB Atlas (dev/test, shared cluster) | Cluster restore | 30-60 min | 1 hr (snapshot) | Lower RPO requirement acceptable |
| AKS cluster | Full cluster rebuild from Terraform | 45-90 min | N/A (stateless; state is in git and Atlas) | Dependent on Key Vault secrets and TLS certs being intact |
| Application workloads (pods) | Pod/node failure | 2-5 min | N/A (stateless) | ArgoCD self-heal restarts pods automatically |
| SFTP managed disks | Disk failure | 15-30 min (snapshot restore) | 24 hr (daily snapshot) or 15 min (if continuous backup enabled) | Verify snapshot policy is configured |
| SharePoint | Microsoft-managed | Per Microsoft SLA | Per Microsoft SLA | Korio-controlled RPO not applicable; document Microsoft's SLA |
| GitHub / GitHub Actions | GitHub outage | N/A (external) | N/A | Deployments blocked but no data loss; document as a known constraint |
| Cloudflare | Cloudflare outage | N/A (external) | N/A | No inbound traffic; document as a known constraint |

Move these targets from WI-IT-002 into SOP-IT-003, with a justification
column that references the architectural basis for each target.

### F-029 — Disaster declaration criteria and authority not defined (P3)

**Gap:** No formal criteria for declaring a disaster or authority to do so.

**Recommended steps:**

1. Define quantitative declaration triggers, for example:
   - Atlas cluster unavailable for > 15 minutes with no auto-recovery
   - AKS cluster unresponsive and no ETA from Azure
   - Data confirmed lost beyond RPO threshold
   - Multiple sub-environments simultaneously degraded
2. Define named decision authority (role, not individual) and a backup
   authority when the primary is unavailable.
3. Define a simple escalation chain: on-call engineer -> DevOps lead ->
   CTO/COO, with maximum time at each level before escalating.

### F-030 / F-047 — No QA approval before declaring service restoration (P2)

**Gap:** Services may resume without documented engineering validation or
QA approval that the system is in a controlled state.

**Recommended steps:**

1. Define a post-recovery checklist in WI-IT-002. For production, this
   must include:
   - All AKS pods passing health/readiness probes
   - ArgoCD reporting all applications Healthy and Synced
   - Atlas cluster connectivity confirmed from at least one pod in each
     active sub-environment
   - Key Vault ExternalSecrets all in Ready state
   - Smoke test or sanity check per validated sub-environment (define
     what this test is)
2. Define who signs off on each checklist item (Engineering) and who
   provides final QA approval before production traffic is restored.
3. For validated sub-environments (`validate`, `accept`, `my`), require
   a documented validation impact assessment as part of recovery sign-off
   (see also F-031 below).

### F-031 — No linkage to validation lifecycle after DR restoration (P3)

**Gap:** SOP-IT-003 does not require a validation impact assessment after
restoring validated systems.

**Recommended steps:**

1. Add a post-recovery step to SOP-IT-003 that requires a validation
   impact assessment when production sub-environments have been restored.
2. The assessment should determine whether the restored state constitutes
   a GxP-impacting change (e.g., if an Atlas PITR restore rolled back
   clinical data, that is not just a technical recovery -- it may require
   a CAPA and regulatory notification). Reference the Master Validation
   Plan and the change classification taxonomy defined in response to
   F-022/F-023 (see Critical findings response).
3. QA sign-off from F-030 above must occur after the validation impact
   assessment is complete, not before.

### F-032 — No DR plan for non-production environments (P2)

**Gap:** Dev and test are explicitly out of scope of the DR plan but
losing them disrupts the development and validation pipeline.

**Recommended steps:**

1. Define a lightweight DR addendum for dev, test, and platform
   environments. These do not require the same rigour as prod but should
   document: recovery priority, RTO/RPO (looser -- e.g., 4-hour RTO,
   24-hour RPO acceptable), and who is responsible.
2. Note that dev/test share a single Atlas cluster (`vozni-dev`,
   `vozni-test`) rather than per-sub-env clusters -- a single cluster
   failure takes out the entire dev or test environment simultaneously.
   This is a higher-blast-radius event than the equivalent prod failure.
3. AKS cluster rebuilds for dev/test follow the same Terraform path as
   prod -- the DR runbook can reference the same procedure with relaxed
   time targets.

### F-033 — Backup verification and restore testing frequency not defined (P2)

Addressed jointly with F-010 above. Additional note: SOP-IT-003 should
explicitly cross-reference SOP-IT-001 for backup schedule and testing
frequency rather than leaving it undefined in the DR SOP.

### F-035 — Communication plan lacks escalation timelines and approval workflow (P3)

**Gap:** No defined timelines or approvals for client-facing communications
during incidents.

**Recommended steps:**

1. Define communication triggers and maximum timelines:
   - Initial client notification: within X hours of confirmed incident
     affecting a client's sub-environment
   - Status updates: every X hours during active incident
   - Resolution notification: within X hours of service restoration
2. Define who drafts and who approves client-facing communications (at
   minimum: DevOps lead drafts, COO/CTO approves before sending).
3. Define which incidents require proactive client notification vs.
   post-incident summary only.

### F-050 — SharePoint RTO/RPO listed as TBD (P2)

**Gap:** SharePoint contains regulated study documentation but has no
defined recovery objectives.

**Recommended steps:**

1. SharePoint is a Microsoft-managed SaaS. Korio's DR obligation here is
   to: (a) document Microsoft's native backup and restore SLA as the
   baseline, (b) determine whether Korio maintains its own SharePoint
   backups (e.g. via Microsoft 365 Backup or a third-party tool), and
   (c) define the acceptable RPO for regulated documents stored there.
2. Assign a named owner responsible for SharePoint recovery and define
   the restore procedure (who submits the restore request, how long it
   takes, how restored content is verified).
3. Set formal RTO/RPO targets in WI-IT-002 and SOP-IT-003 based on the
   above.

---

## Theme 2: Monitoring and Incident Management

**Findings:** F-005, F-011, F-018, F-021

### Infrastructure context

The observability stack is technically mature: Datadog (primary APM and
log aggregation, all prod and staging environments), Azure Monitor
(managed Prometheus, Container Insights), Grafana (dashboards), and
PagerDuty (on-call alerting). MongoDB Atlas alerts route to Microsoft
Teams. All monitoring infrastructure is managed by Terraform
(`terraform-infra/`).

The gap here is not in the technical tooling but in the documented
processes that sit on top of it: what is monitored, how alerts are
handled, how incidents are escalated, and how findings feed into CAPA.

### F-005 — Monitoring and alerting process not formally defined (P2)

**Gap:** The Master Validation Plan identifies this as needing definition,
including tool qualification. Korio is in the middle of a transition
from Azure Monitor to Datadog as the primary observability platform.

**Recommended steps:**

1. Document the monitoring scope -- which systems are monitored, by which
   tool, and what is covered:

   | System | Tool | Coverage |
   |---|---|---|
   | AKS pods / containers | Datadog Node Agent (prod/staging), Azure Container Insights (all envs) | Logs, metrics, APM (prod/staging only) |
   | AKS cluster state | Datadog Cluster Agent | Kubernetes state metrics |
   | NGINX routing | Datadog / Azure Prometheus | Request rates, error rates, latency |
   | MongoDB Atlas | Datadog Cluster Check + Atlas native alerts | Query performance, replication lag, connection counts |
   | ArgoCD | Datadog (autodiscovery) + Azure Prometheus | Sync status, health, error rates |
   | Infrastructure alerts | Azure Monitor Prometheus rules + PagerDuty | CPU, memory, pod restarts, etc. |
   | Security / access events | Not fully defined -- see F-018 | Gap |

2. For GxP qualification: define whether Datadog and PagerDuty require
   formal qualification (GAMP5 Category 1 -- commercially available
   software used as-is) or are treated as supporting infrastructure.
   Document this decision.
3. Define the alert-handling workflow: alert fires -> PagerDuty on-call
   notified -> acknowledgment SLA -> investigation -> resolution ->
   incident ticket opened (if threshold met).
4. Define which alert conditions require a clinical/GxP impact assessment
   (e.g., a MongoDB Atlas data integrity alert is different from a pod
   OOMKill alert).

### F-011 — No documented incident notification distribution list (P2)

**Gap:** The SOP references notifying IT security personnel but no
distribution list or mechanism is defined. The finding notes a target
list: DevOps, QA, CEO, COO, CS Lead.

**Recommended steps:**

1. Create a dedicated security incident notification channel. Options
   (in order of preference for auditability):
   - A Microsoft Teams channel with a defined membership list and message
     logging
   - A shared security alias (e.g. `security@korioclinical.com`) with a
     documented membership list maintained in a controlled document
2. Document the distribution list in SOP-IT-001 or its referenced work
   instruction, including the mechanism for keeping it current (who
   updates it, how often it is reviewed).
3. Define a secondary notification path for when the primary channel is
   unavailable (e.g., the incident itself takes down Teams).

### F-018 — Security health checks undefined scope and undocumented (P2)

**Gap:** Semi-annual security health checks are required but which systems
are "critical" is not defined, and there is no documentation requirement
or CAPA linkage.

**Recommended steps:**

1. Define system criticality tiers, which will also feed F-001 and F-037
   (asset inventory). For security health checks, the relevant tier is
   "GxP-critical or security-critical":

   | Tier | Examples | Health check cadence |
   |---|---|---|
   | GxP-critical | AKS prod clusters, MongoDB Atlas prod clusters, Azure Key Vaults, Azure Entra B2C (or replacement IdP), NGINX routing config | Semi-annual minimum; annual formal review |
   | Security-critical | Cloudflare WAF, Twingate, GitHub org settings, ArgoCD RBAC | Annual |
   | Supporting | Datadog, PagerDuty, Grafana, Atlassian | Annual |

2. Define what a "health check" covers for each tier: configuration
   review, access review, alert coverage review, vulnerability scan
   results, etc.
3. Define where health check evidence is recorded (Confluence, SharePoint,
   or a designated quality record location) and the retention period.
4. Define explicitly when a health check finding triggers a CAPA (see
   F-021 below).

### F-021 — Missing CAPA and breach management linkage (P2)

**Gap:** SOPs covering monitoring and security incidents do not define
when findings escalate to CAPAs or how a potential data breach is
handled.

**Recommended steps:**

1. Define CAPA escalation triggers for security events, for example:
   - Confirmed unauthorized access to a validated system or clinical data
   - A security health check finding rated High or Critical
   - A recurring alert pattern indicating a systemic control failure
   - Any Atlas data integrity alert in a prod sub-environment
2. Create a standalone Breach Management SOP (referenced in the finding).
   Minimum content: breach detection criteria, containment steps,
   regulatory notification obligations (GDPR -- 72-hour notification
   window to supervisory authority for breaches involving PII/PHI),
   client notification criteria and timelines, and evidence preservation
   requirements.
3. Add cross-references from SOP-IT-001 (security incidents) to the
   Breach Management SOP and the CAPA SOP.

---

## Theme 3: SOP Governance and Role Alignment

**Findings:** F-012, F-016

### F-012 — SOP role names do not match current org structure (P2)

**Gap:** SOP-IT-001 references roles ("Security Architect," "VP of Product
& Compliance," "Architect") that do not align with the current
organisation.

**Recommended steps:**

1. Conduct a pass through SOP-IT-001 to identify every named role and
   map it to either: (a) a current role/title, or (b) a functional
   designation (e.g., "DevOps Lead" rather than a person's name or a
   legacy title).
2. Where a role has no clear current equivalent, assign ownership to
   the closest existing function and document the mapping decision.
3. This review should be done in conjunction with the RBAC matrix work
   from F-002 (Critical findings) to ensure role names are consistent
   across SOPs and access controls.

### F-016 — Service account and non-expiring password review evidence not defined (P3)

**Gap:** Monthly reviews are now defined in WI-IT-004 but evidence
storage and retention are not specified.

**Recommended steps:**

1. WI-IT-004 should specify: where completed review records are stored
   (a named location in Confluence or SharePoint), the required content
   of each review record (date, reviewer, list of accounts reviewed,
   any findings and actions), and the retention period.
2. Define the list of service accounts and non-expiring passwords in scope
   for the monthly review. From the current infrastructure this includes:
   Atlas admin/integration users (manually managed), GitHub App credentials
   (stored in `vozni-common-secrets-kv`), Datadog API keys, Cloudflare API
   tokens, and any Azure service principal client secrets.
3. The MongoDB Key Vault gap (passwords managed by Terraform but URIs
   written manually -- see `infrastructure.md`) means Atlas sub-environment
   credentials are not naturally surfaced in a review. Consider whether
   these fall within scope and if so, how the review is performed.

---

## Theme 4: Asset Governance, Inventory, and Validation

**Findings:** F-001, F-006, F-007, F-037, F-038, F-039, F-040, F-041, F-042, F-043, F-044

These findings are closely related and can largely be addressed by a
single deliverable: a controlled asset inventory with criticality tiers.
Several findings (F-037, F-038, F-039, F-040) are all addressed by
creating and maintaining this inventory.

### Infrastructure context

The current infrastructure includes a broad set of assets, many of which
are not explicitly governed in any SOP. A starting point for the
inventory, organised by tier:

**GxP-critical (direct impact on clinical data or validated state):**
- MongoDB Atlas clusters (one per sub-env for prod/staging; shared for
  dev/test/platform)
- Azure Key Vaults (one per sub-env per environment)
- Azure AKS clusters (one per environment)
- Azure Entra B2C tenants (one per environment; or replacement IdP)
- NGINX routing configuration (in `kubernetes-manifests` repo)
- ArgoCD ApplicationSet YAMLs (in `argocd` repo)
- Azure Container Registry (stores all container images)

**Security-critical:**
- Cloudflare (WAF, DNS -- controls what traffic reaches the platform)
- Twingate (controls developer access to private subnets)
- GitHub (`korio-clinical` org -- controls CI/CD and GitOps)
- Azure Entra (staff identity and access)

**Supporting / operational:**
- Datadog, Azure Monitor, Grafana, PagerDuty (observability)
- SFTP managed disks and Azure Data Lake Storage
- SharePoint (regulated documentation)
- Atlassian Jira and Confluence (project management and documentation)
- Microsoft Teams

### F-001 / F-037 / F-039 — Asset inventory with criticality tiers and system of record (P2)

**Gap:** No formal infrastructure inventory with risk-based criticality
classification exists. No system of record is defined for asset
inventory.

**Recommended steps:**

1. Create a controlled asset inventory document (Confluence is a natural
   system of record given its use for other docs; SharePoint is an
   alternative if the quality team prefers a controlled document system).
   The inventory should capture for each asset: asset name, type,
   environment(s), criticality tier, business owner, technical owner,
   GxP relevance, validation status, and last review date.
2. Use the tier structure from F-018 above (GxP-critical,
   security-critical, supporting). Define the control requirements
   that apply at each tier (monitoring cadence, review frequency,
   change control category required, validation deliverables).
3. Terraform state is a partial source of truth for Azure and Atlas
   assets -- the inventory does not need to duplicate what Terraform
   manages, but it should reference it. Assets not in Terraform (B2C
   tenants, GitHub, Cloudflare, SaaS tools) need explicit entries.
4. Define access controls for the inventory itself: who can edit it,
   how changes are approved, and how the history is preserved.

### F-038 / F-043 — Review cadence and access review not defined for all asset types (P2)

**Gap:** Annual audits are defined for Platform and Corporate assets but
not for software licenses, user accounts, or all asset categories.
BSO access review frequency and documentation are undefined.

**Recommended steps:**

1. Define minimum review cadence per asset tier in the inventory SOP
   and in SOP-IT-004:
   - GxP-critical assets: quarterly access review; semi-annual
     configuration review
   - Security-critical assets: semi-annual access review; annual
     configuration review
   - Supporting assets: annual review of both
2. Software licenses: define an annual review to confirm all licenses
   are current, assigned, and within their permitted use scope.
3. User account reviews: align with the RBAC matrix process from F-002
   (Critical findings). Define who performs the review, what the
   acceptance criteria are, and where evidence is stored.

### F-040 — Cloud infrastructure not explicitly in inventory scope (P2)

**Gap:** SOP-IT-004 does not explicitly include cloud-hosted or third-party
SaaS assets in inventory scope.

**Recommended steps:**

1. Amend SOP-IT-004 to explicitly state that cloud infrastructure (AKS,
   Atlas, Azure Key Vault, ACR, Azure Data Lake) and third-party SaaS
   (Cloudflare, Twingate, Datadog, PagerDuty, GitHub, Atlassian,
   SharePoint) are within inventory scope.
2. For cloud infrastructure managed by Terraform, the SOP can reference
   Terraform state as the authoritative source and require that the human-
   readable inventory entry is updated whenever a Terraform workspace
   adds or removes a resource of a given type.

### F-042 — No reconciliation between asset inventory and change control (P2)

**Gap:** Changes that create, modify, or retire assets do not require
inventory updates.

**Recommended steps:**

1. Add an inventory reconciliation step to the change control PR template
   (see F-022/F-023 in the Critical findings response). For any change
   that provisions, modifies, or decommissions an asset (particularly
   Terraform changes), the change ticket must confirm whether the
   inventory needs updating and who is responsible.
2. This is particularly relevant for Terraform changes: a `terraform apply`
   that adds a new Atlas cluster, Key Vault, or AKS node pool creates new
   GxP-critical assets that must appear in the inventory.

### F-044 — No retention or storage location defined for inventory records (P2)

**Gap:** Retention period and storage location for inventory audits,
ownership assignments, and retirement documentation are not defined.

**Recommended steps:**

1. Define retention periods in SOP-IT-004, aligned with the quality
   management SOP. A common baseline for GxP records is the longer of:
   the life of the system plus 2 years, or the applicable regulatory
   retention requirement.
2. Define the storage location as part of the system of record decision
   (Confluence or SharePoint). Ensure the location is access-controlled
   and that edit history is preserved.

### F-041 — No risk assessment required before asset onboarding (P3)

**Gap:** SOP-IT-004 references acquisition via SOP-CO-002 but does not
require a risk or compliance assessment before placing an asset into
service.

**Recommended steps:**

1. Add an onboarding assessment step to SOP-IT-004. For GxP-relevant
   assets the assessment must include: GxP impact determination,
   validation requirements (GAMP5 category), security review, and
   data classification.
2. For cloud/SaaS assets this also means: confirming the vendor holds
   appropriate certifications (SOC 2 Type II minimum; ISO 27001
   preferred for clinical systems), reviewing the vendor's data
   processing agreement for GDPR compliance, and confirming the
   vendor's own DR capabilities meet Korio's RTO/RPO requirements.

---

## Theme 5: Validation Governance and Configuration Baselines

**Findings:** F-006, F-007, F-025, F-026

### F-006 — Infrastructure requirements not formally documented (P3)

**Gap:** Infrastructure requirements for validation traceability have not
been defined. The existing infrastructure documentation (`infrastructure.md`,
`application-stack.md`) provides technical description but is not a
formal validation deliverable.

**Recommended steps:**

1. Produce a formal Infrastructure Requirements Document (IRD) or
   equivalent, drawing from the existing technical docs as a starting
   point. The IRD should capture requirements in a traceable format
   (requirement ID, description, rationale, acceptance criteria) so
   they can be linked to test evidence.
2. The IRD is distinct from the technical docs in this repo -- the
   technical docs describe how the system is built; the IRD states what
   it is required to do in order to be fit for its GxP purpose.

### F-007 — No validation lifecycle defined for non-RTSM/non-product systems (P3)

**Gap:** No validation process exists for supporting systems
(infrastructure tools, monitoring, CI/CD). GAMP5 principles should apply.

**Recommended steps:**

1. Define a validation lifecycle for infrastructure and supporting
   systems. Under GAMP5, most of these are Category 1 (commercially
   available software used as-is) or Category 3 (configured
   infrastructure-as-code). The validation effort for Category 1 is
   primarily vendor assessment and configuration review; Category 3
   requires configuration testing.
2. For AKS, Atlas, ArgoCD, Datadog, and similar: document the GAMP5
   category, the rationale, and the validation deliverables required.
   Terraform state can serve as the configuration baseline (see F-025
   below).

### F-025 — No baseline configuration definitions referenced in SOP-IT-002 (P3)

**Gap:** SOP-IT-002 does not define or reference baseline configurations
that serve as the starting point for change impact assessment.

**Recommended steps:**

1. Terraform state is effectively the configuration baseline for all
   Azure and Atlas infrastructure managed by Terraform. Reference this
   explicitly in SOP-IT-002: the approved baseline configuration for
   infrastructure is the state represented in the Terraform workspaces
   at the point of last approval.
2. For application configuration (Helm values, ArgoCD ApplicationSet
   parameters, NGINX routing rules), the approved baseline is the
   `main` branch of the relevant repository at the point of last
   validated deployment.
3. Define how baseline deviations are detected (ArgoCD self-heal
   reports config drift; Terraform plan output shows infrastructure
   drift) and how they trigger a change control record.

### F-026 — SOP-IT-002 does not reference validation lifecycle or Master Validation Plan (P3)

**Gap:** Configuration management changes to validated systems may occur
without required validation documentation, traceability, or approved
testing.

**Recommended steps:**

1. Add a cross-reference from SOP-IT-002 to the Master Validation Plan.
   The change control process must invoke validation impact assessment
   when a change affects a GxP-critical or validated system (as defined
   by the criticality tiers in F-037/F-001 above).
2. Define testing requirements for GxP-impacting changes: acceptance
   criteria, who executes and witnesses tests, what evidence is produced,
   and where it is retained. For the sub-environment pipeline, the
   `validate` sub-environment is the designated validation stage --
   document this explicitly as the technical mechanism for executing
   validation test activities.
3. Define the release approval gate: what sign-offs are required before
   a change can be promoted from `validate` to `accept` (and then to
   `my`), and how those approvals are recorded.

---

## Summary: Suggested Remediation Priority

All findings are rated P2 (30-60 days) or P3 (60-120 days).

### P2 Items (30-60 days)

| Priority | Action | Finding(s) |
|---|---|---|
| 1 | Confirm Atlas backup/PITR configuration is in place; define restore test procedure | F-010, F-033 |
| 2 | Define realistic RTO/RPO per system, move into SOP-IT-003 | F-028, F-045, F-050 |
| 3 | Define post-recovery checklist with QA sign-off requirement | F-030, F-047 |
| 4 | Create and publish security incident distribution list | F-011 |
| 5 | Define monitoring scope and alert-handling workflow in SOP | F-005 |
| 6 | Define system criticality tiers; document in SOP-IT-001 | F-018 |
| 7 | Define CAPA triggers for security events; create Breach Management SOP | F-021 |
| 8 | Update SOP-IT-001 role names to match current org structure | F-012 |
| 9 | Create controlled asset inventory (Confluence or SharePoint) with criticality tiers | F-001, F-037, F-038, F-039, F-040, F-042, F-043, F-044 |
| 10 | Define DR plan addendum for dev/test environments | F-032 |

### P3 Items (60-120 days)

| Priority | Action | Finding(s) |
|---|---|---|
| 11 | Define disaster declaration criteria and decision authority | F-029 |
| 12 | Define client communication timelines and approval workflow | F-035 |
| 13 | Add validation lifecycle linkage to SOP-IT-003 (post-DR re-validation) | F-031 |
| 14 | Define configuration baselines and cross-reference in SOP-IT-002 | F-025 |
| 15 | Add validation lifecycle cross-reference to SOP-IT-002 | F-026 |
| 16 | Define evidence storage and retention for service account reviews | F-016 |
| 17 | Add pre-onboarding risk/compliance assessment to SOP-IT-004 | F-041 |
| 18 | Produce Infrastructure Requirements Document for validation traceability | F-006 |
| 19 | Define GAMP5-based validation lifecycle for non-product systems | F-007 |
