# Audit Findings Response: Medium Risk Items
<!-- Source: audit_findings_risk_prioritization.xlsx -->
<!-- Date: 2026-03-26 -->

This document covers the Medium-rated findings from the audit findings
spreadsheet, with infrastructure-specific context and recommended
remediation steps. All Medium findings are rated P3 (60-120 days).
Findings are grouped by workstream.

---

## Theme 1: Business Continuity and Disaster Recovery

**Findings:** F-020, F-034, F-036, F-046, F-047, F-048, F-049, F-051,
F-052, F-053, F-054

Most of these findings (F-034, F-036, F-046, F-048, F-049, F-051, F-052,
F-053, F-054) are gaps in WI-IT-002 (Service Recovery) specifically. They
can largely be addressed in a single revision of that document rather than
as separate workstreams. F-020 is a gap in SOP-IT-001.

### F-020 — SOP-IT-001 backup documentation incomplete (P3)

**Gap:** SOP-IT-001 states that restore requests go to the "Software
Architect" but does not define backup schedules, verification, restore
testing, or documentation requirements. MongoDB backup is not
distinguished from other backup types.

**Infrastructure context:**

MongoDB Atlas handles its own backups (PITR and scheduled snapshots per
cluster). The finding notes that the restore testing script needs to be
formally validated and automated. The intent is a weekly automated restore
test to start.

**Recommended steps:**

1. Update SOP-IT-001 to describe the MongoDB Atlas backup model
   explicitly: PITR-enabled per sub-environment cluster for prod/staging,
   snapshot-based for dev/test/platform. Document the retention windows.
   Note that Atlas is a managed service and Korio relies on Atlas's
   built-in backup infrastructure rather than running its own backup
   agent -- explain this explicitly so client auditors understand the
   model.

2. Formalise the restore testing procedure:
   - The testing script referenced in the finding should be documented,
     version-controlled, and executed in a non-production Atlas cluster
     to avoid impact on live data.
   - Once validated, configure the script to run on an automated schedule
     (weekly as a starting cadence) via a GitHub Actions workflow or a
     cron-triggered Azure function.
   - The script output (success/failure, timestamp, cluster tested,
     data spot-check result) constitutes the restore test evidence.
     Define where this evidence is retained (see F-034 / F-048 below).

3. Replace "Software Architect" with the current role responsible for
   restore requests (see F-012 in the High findings response for the
   general SOP role alignment issue).

4. The SOP should note that vendor-managed backups (Atlas, Microsoft 365
   for SharePoint) provide a baseline, but Korio bears responsibility for
   testing recoverability, not the vendor.

### WI-IT-002 Revision: Addressing F-034, F-036, F-046, F-048, F-049, F-051, F-052, F-053, F-054 in a single pass

WI-IT-002 (Service Recovery) currently describes technical recovery steps
but is missing the surrounding governance elements that make it a
complete, auditable procedure. The nine findings below map to nine
distinct gaps in the document. Rather than addressing each as a separate
workstream, a single revision of WI-IT-002 should incorporate all of
them.

#### F-046 / F-053 — No invocation criteria, declaration authority, or escalation matrix

**Gap:** WI-IT-002 does not say when to invoke the procedure, who
declares a recovery event, or define an escalation path.

**Recommended steps:**

1. Add an "Invocation" section at the front of WI-IT-002 that references
   the formal disaster declaration criteria to be defined in SOP-IT-003
   (see F-029 in the High findings response). The work instruction should
   not duplicate the criteria -- it should reference the SOP.
2. Define the escalation matrix for recovery events. This can be a simple
   table of roles with maximum hold times before escalation. Suggested
   structure:

   | Level | Role | Max hold time before escalating |
   |---|---|---|
   | 1 | On-call engineer (PagerDuty primary) | 15 minutes |
   | 2 | DevOps Lead | 30 minutes |
   | 3 | CTO / COO | Immediately if data loss confirmed or validated sub-env affected |

3. Cross-reference this escalation matrix in SOP-IT-003's RACI (see
   F-036 below).

#### F-036 — No formal RACI matrix for DR execution

**Gap:** Roles in SOP-IT-003 are described at a high level without a
RACI.

**Recommended steps:**

1. Add a RACI matrix to SOP-IT-003 covering the key activities:
   disaster detection, disaster declaration, recovery execution, client
   communication, validation/QA sign-off, and post-mortem. Suggested
   roles:

   | Activity | Incident Commander | Technical Lead (DevOps) | Communications Lead | QA / Compliance |
   |---|---|---|---|---|
   | Declare disaster | A | R | I | I |
   | Execute recovery steps (WI-IT-002) | I | R | I | I |
   | Client notification | A | I | R | C |
   | Post-recovery checklist sign-off | I | R | I | A |
   | QA approval before resuming production | I | I | I | R/A |
   | Post-mortem documentation | A | R | I | C |

   Assign current named roles (not individuals) to each column and
   cross-reference WI-IT-002.

#### F-049 — Recovery steps assume backups are available without verification

**Gap:** WI-IT-002 assumes Atlas PITR and AKS persistent volume snapshots
are available at the point of need, without requiring any pre-event
verification.

**Recommended steps:**

1. Add a pre-recovery assumption check step at the start of the recovery
   procedure: before initiating restore, confirm that the target PITR
   timestamp or snapshot exists in Atlas and that AKS persistent volume
   snapshots are within the expected retention window.
2. This check is the operational manifestation of the automated restore
   testing defined in F-020 / F-033 (High findings): if the weekly
   automated test passes, you have recent evidence that backups are
   available. WI-IT-002 should reference this automated test cadence as
   the mechanism that validates the backup assumption.
3. If the pre-recovery check fails (e.g., PITR is unavailable), define
   the fallback: escalate immediately to DevOps Lead; contact Atlas
   support; document the failure.

#### F-048 / F-034 — No defined storage or retention for recovery evidence and DR records

**Gap:** WI-IT-002 does not define where recovery logs, evidence, or
restoration artefacts must be stored. SOP-IT-003 does not define retention
requirements for DR tests, events, or post-mortems.

**Recommended steps:**

1. Define a single location for all DR and recovery records. Given the
   existing tooling, either a dedicated Confluence space or a SharePoint
   folder is appropriate. The location must be access-controlled and
   maintain edit history.
2. Define the required artefacts for each recovery event:
   - Timeline log (start time, each action taken with timestamp, recovery
     complete time)
   - Atlas restore confirmation (timestamp restored to, verification
     result, Key Vault re-sync confirmation)
   - Post-recovery checklist (from F-030 / F-047 in the High findings
     response)
   - Client communication log (who was notified, when, and by whom)
   - QA sign-off record
3. Define the retention period in SOP-IT-003. Align with quality
   management retention requirements. A reasonable baseline for GxP
   recovery records: the life of the affected system plus 2 years, or
   the applicable regulatory minimum (whichever is longer).
4. For DR test records (annual or more frequent exercises): retain
   indefinitely as evidence of ongoing DR readiness.

#### F-051 — No communication responsibilities during recovery events

**Gap:** WI-IT-002 does not define internal or client communication
during recovery.

**Recommended steps:**

1. Add a "Communications" section to WI-IT-002 that references the
   timelines and approval workflow to be defined in SOP-IT-003 (see
   F-035 in the High findings response). The work instruction should
   reference, not duplicate, the communication plan.
2. At minimum, WI-IT-002 should specify: who is responsible for
   notifying the Communications Lead when a recovery event is declared
   (typically the Incident Commander), and what information must be
   included in the handoff (affected sub-environments, initial impact
   assessment, estimated recovery time).

#### F-052 — "Resume Procedure" lacks approval criteria before resuming operations

**Gap:** WI-IT-002 states to deploy services and ensure functionality
but does not define acceptance criteria or authorisation before resuming.

**Recommended steps:**

1. Replace the current "Resume Procedure" section with a structured
   sign-off checklist (consistent with the post-recovery checklist
   defined for F-030 / F-047 in the High findings response). The
   checklist should be a required artefact before declaring restoration
   complete.
2. Add a formal authorisation step: Engineering sign-off that the
   checklist is complete, followed by QA approval for any validated
   sub-environment. The QA approval record becomes part of the recovery
   evidence (see F-048 above).

#### F-054 — No post-recovery review or post-mortem requirement

**Gap:** WI-IT-002 does not require a post-mortem following service
restoration.

**Recommended steps:**

1. Add a mandatory post-mortem step to WI-IT-002 for any event that
   reached a disaster declaration. The post-mortem should be completed
   within 5 business days of recovery and must include:
   - Timeline of the event from detection to resolution
   - Root cause (or "root cause under investigation" if not yet
     confirmed)
   - Actions taken during recovery and their effectiveness
   - Identified gaps (process, tooling, or documentation)
   - Action items with owners and due dates
2. Define the trigger for escalating a post-mortem finding to a CAPA:
   any systemic issue, any data integrity concern, any finding that a
   documented procedure was not followed or was insufficient.
3. Post-mortem records are retained per F-034 / F-048 above.

---

## Theme 2: Change Management and Maintenance

**Findings:** F-008, F-009, F-027

### F-008 — Infrastructure maintenance process not formally defined (P3)

**Gap:** The Master Validation Plan requires a formal infrastructure
maintenance process but none is documented. The finding notes that a CCB
exists, tickets are raised, assessments are done, and validation is
executed -- but there is no automated smoke testing to verify that routine
maintenance (e.g., AKS node pool updates, Atlas minor version upgrades,
Helm chart bumps) has not broken anything.

**Infrastructure context:**

The biggest surface area for routine maintenance in this platform is:
- AKS node pool OS updates and Kubernetes minor version upgrades (Azure
  manages the major upgrade path; node pool upgrades are triggered
  manually or automatically via maintenance windows)
- MongoDB Atlas minor version upgrades (Atlas can auto-upgrade; ensure
  this is controlled and not happening silently in prod)
- Helm chart version bumps for ArgoCD, Datadog, External Secrets Operator,
  and other in-cluster components managed by `terraform-infra/env/`
- Container base image updates for services that track a `latest`-style
  tag (these should be pinned per the version-pinning approach documented
  in the platform architecture)

**Recommended steps:**

1. Define a maintenance classification within the change taxonomy from
   F-022 / F-023 (Critical findings). Routine maintenance should be its
   own sub-category with a lighter-weight review path than a functional
   change, but still requiring pre/post verification steps.

2. For automated smoke testing after maintenance events: define a minimal
   suite of post-deployment checks that verify the platform is functioning
   correctly. This aligns with the ArgoCD self-heal / health check
   framework already in place. At minimum:
   - All ArgoCD applications report Healthy and Synced
   - A defined set of Kubernetes readiness probes pass in all active
     sub-environments
   - MongoDB connectivity confirmed from at least one pod per
     sub-environment
   - NGINX routing: a synthetic request to a known endpoint per client
     returns the expected response code

3. Document Atlas auto-upgrade settings in each environment's Terraform
   workspace. Confirm that auto-upgrade is disabled for prod Atlas clusters
   (or that notifications are configured so upgrades go through the
   maintenance change process before applying).

4. For AKS maintenance windows: configure Azure Planned Maintenance for
   each prod/staging cluster to restrict node updates to defined windows
   (e.g., weekend nights), and document this as part of the maintenance
   process.

### F-009 — Periodic system review process not defined (P3)

**Gap:** No defined process for periodic review of validated system state,
user access, and audit trails. The finding notes the intent to automate
as much of this as possible.

**Infrastructure context:**

Several periodic review activities are already partially automated or
have existing tooling that could support them:
- ArgoCD provides continuous drift detection against the desired git state
  -- this is an automated audit trail for application configuration.
- Atlas audit logging captures data access events per cluster.
- Terraform state drift detection (`terraform plan` with no changes
  expected) can serve as a configuration audit for infrastructure.
- Datadog and Azure Monitor already capture logs and metrics; the gap is
  a defined review process on top of them.
- Access reviews are partially addressed by WI-IT-004 (monthly service
  account reviews) -- see F-016 in the High findings response.

**Recommended steps:**

1. Define the periodic review scope and cadence:

   | Review type | Cadence | Tool / source of truth | Evidence artefact |
   |---|---|---|---|
   | Access review (all systems) | Quarterly for GxP-critical; annual otherwise | RBAC matrix (see F-002 in Critical findings) | Signed review record |
   | Audit trail integrity (Atlas) | Monthly automated check | Atlas audit log export | Automated report + exception log |
   | Configuration drift (infrastructure) | Weekly automated | `terraform plan` (zero-diff expected); ArgoCD sync status | CI job pass/fail log |
   | Validated sub-environment state | Each deployment to `validate` or above | ArgoCD sync + post-deployment checklist | Deployment record |
   | Security health check | Semi-annual | Defined in F-018 (High findings) | Health check record |

2. For the Atlas audit trail review: define what the automated check
   is looking for (e.g., unexpected admin operations, connections from
   IPs outside the Private Link range, schema drops). Define the
   exception-handling path when unexpected events are detected.

3. Define the escalation path when drift is detected (e.g., ArgoCD
   reports an application is OutOfSync outside a planned change window):
   who investigates, what the maximum investigation time is before
   escalating, and whether an unexpected drift event triggers a CAPA.

### F-027 — No post-deployment monitoring requirement in SOP-IT-002 (P3)

**Gap:** SOP-IT-002 does not require post-deployment monitoring or
verification before a change is considered closed.

**Infrastructure context:**

The GitOps pipeline already provides a natural post-deployment monitoring
window: after an ArgoCD sync, the application health status is
continuously reported. PagerDuty on-call alerting means that a
post-deployment failure will surface quickly if it triggers a defined
alert condition. The gap is that this is not formally documented as a
required step before change closure.

**Recommended steps:**

1. Add a post-deployment monitoring step to SOP-IT-002. For GxP-critical
   changes, define a minimum monitoring window (e.g., 24 hours for prod
   deployments, 4 hours for staging) during which the change owner is
   responsible for monitoring for anomalies.
2. Define the success criteria for change closure:
   - ArgoCD reports all affected applications Healthy and Synced
   - No new PagerDuty alerts attributable to the change during the
     monitoring window
   - MongoDB Atlas metrics (connection counts, query latency, replication
     lag) are within normal baselines in the affected sub-environments
   - No unexpected patterns in Datadog APM traces for affected services
3. Define what constitutes a monitoring failure and triggers a rollback
   (per the rollback procedure from F-024 in the Critical findings
   response).
4. The monitoring window and results should be recorded in the change
   ticket as evidence of post-deployment verification.

---

## Theme 3: Identity and Access Management

**Findings:** F-017, F-019

### F-017 — No out-of-band account recovery path for locked-out users (P3)

**Gap:** SOP-IT-001 says locked-out users contact IT but does not define
how they do so when they cannot access corporate systems or email (e.g.,
a new joiner whose accounts are not yet provisioned, or a user locked
out of Entra entirely).

**Recommended steps:**

1. Define an out-of-band contact mechanism. The finding notes that new
   team members use personal email until systems are set up -- formalise
   this. Options:
   - A dedicated security or IT support alias hosted outside corporate
     Entra (e.g., a personal Microsoft account or a secondary email
     provider) that does not require Entra authentication to reach.
   - A direct phone number or Teams personal account for the on-call
     DevOps contact.
2. Document the identity verification steps required before an account
   is unlocked or reset. For Entra-managed accounts, the minimum should
   be: video call verification (face + government-issued ID for high-trust
   accounts), or manager attestation in writing.
3. Document who is authorised to perform account unlocks and resets, and
   require that every unlock event is logged with: requester identity,
   verification method used, who performed the action, and timestamp.
   This log is a security audit record and should be retained per quality
   management requirements.
4. Publish the out-of-band contact information in the employee onboarding
   pack and in SOP-IT-001.

### F-019 — User-managed endpoint security; no centrally enforced controls (P3)

**Gap:** SOP-IT-001 places responsibility for endpoint security on
individual remote users. This is flagged as a client objection risk.

**Note:** This finding is directly related to F-015 (Critical, P1) which
addresses contractor device management via Entra Conditional Access.
F-019 extends the same concern to all remote users (employees and
contractors). The Conditional Access policy recommended for F-015 is the
same mechanism that addresses F-019 -- the two remediations should be
implemented together.

**Recommended steps:**

1. Once the Conditional Access / MDM enforcement policy is in place for
   F-015, update SOP-IT-001 to reflect the centrally enforced control:
   "Endpoint security controls are enforced via Azure Entra Conditional
   Access. All users must access corporate systems from MDM-enrolled and
   compliant devices. Compliance is verified at authentication time, not
   by user self-attestation."
2. Define the minimum endpoint security baseline enforced by Intune MDM
   policy: disk encryption required (FileVault on macOS, BitLocker on
   Windows), OS patch level within N days of release, screen lock on
   idle, approved EDR agent installed (if applicable).
3. Define the exception path for users who cannot meet the MDM compliance
   requirement (e.g., a temporary device during hardware replacement).
   Exception must be approved by DevOps Lead, time-limited, documented,
   and access scoped to the minimum required during the exception window.
4. Update client-facing documentation to reference the Conditional Access
   enforcement, replacing the current self-managed language that raises
   audit objections.

---

## Summary: Suggested Remediation Priority

All findings are P3 (60-120 days). Sequencing by dependency and effort:

| Priority | Action | Finding(s) |
|---|---|---|
| 1 | Revise WI-IT-002 in a single pass to add invocation criteria, RACI reference, communication reference, evidence storage, resume checklist, and post-mortem requirement | F-036, F-046, F-048, F-049, F-051, F-052, F-053, F-054 |
| 2 | Update SOP-IT-001 backup section: document Atlas backup model, define restore test automation, replace "Software Architect" role | F-020 |
| 3 | Define DR record retention requirements and storage location in SOP-IT-003 | F-034 |
| 4 | Define out-of-band account recovery path and identity verification procedure | F-017 |
| 5 | Update SOP-IT-001 endpoint security language once Conditional Access (F-015) is in place | F-019 |
| 6 | Add post-deployment monitoring window and closure criteria to SOP-IT-002 | F-027 |
| 7 | Define infrastructure maintenance classification and post-maintenance smoke test suite | F-008 |
| 8 | Define periodic system review process with cadence, tooling, and evidence requirements | F-009 |

**Note on sequencing:** Items 1-3 are a natural continuation of the
BCP/DR package from the High findings (F-028, F-029, F-030, F-033,
F-035). They should be executed in the same workstream rather than as a
separate effort. Items 4-5 extend the IAM hardening work from the
Critical findings (F-014, F-015). Items 6-8 extend the change management
work from the Critical findings (F-022, F-023, F-024).
