# infra-docs

Reference documentation for Korio Clinical's DevOps infrastructure.

## How to use this documentation

Start with **Theory of Operation** if you are new to the platform —
it explains the business constraint that shapes every architectural
decision, and builds up the key concepts (path-based version
isolation, reverse proxy, service-to-service routing) from first
principles.

The **topic guides** are reference documents for specific domains.
Read them when you need to understand or operate a particular part of
the system. They assume familiarity with the core concepts in Theory
of Operation.

The **runbooks** are step-by-step procedures for specific operational
tasks. Use them when you need to carry out a known action (add a
database, enable a sub-environment, diagnose a sync failure, etc.).

---

## Conceptual Primer

| Document | What it covers |
|---|---|
| [Theory of Operation](theory-of-operation.md) | The business constraint (client acceptance freeze), path-based version isolation, TCP/IP and DNS in Kubernetes, the reverse proxy pattern, the two NGINX gateways (external/internal), the full request lifecycle from login to API response, shared vs. versioned services, and how the toolchain keeps configs consistent |

---

## Topic Guides

| Document | What it covers |
|---|---|
| [Application Stack](application-stack.md) | NGINX location block structure, end-to-end request flow, korioctl CLI, dagger-presto CI pipeline, ArgoCD ApplicationSet layout, Helm chart architecture, presto-besto-manifesto interface, Docker local dev environment, microservice deployment lifecycle, CI workflows, Azure B2C integration |
| [Infrastructure](infrastructure.md) | Terraform workspace layout, external dependencies not in IaC (Cloudflare, B2C, MongoDB Atlas, Twingate), AKS cluster bootstrap sequence, sub-environment configuration and provisioning checklist, MongoDB Atlas credential management |
| [Observability](observability.md) | Datadog agent deployment and per-environment config, ArgoCD and MongoDB integrations, Azure Monitor (managed Prometheus, Container Insights, Log Analytics), Grafana dashboards and RBAC, Prometheus alert rules, Atlas alerts, PagerDuty escalation, log sampling and cost control, Terraform workspace layout |
| [SFTP](sftp.md) | sftp-server-docker and sftp-acl-init-go architecture, Azure Workload Identity (UAMI/FIC/DLDP), Kustomize deployment structure, pod container chain, CI workflows, adding a new SFTP integration |

---

## In-Progress and Planning Documents

| Document | What it covers |
|---|---|
| [IdP Migration](idp-migration.md) | Current Azure B2C architecture, functional and compliance requirements for a replacement IdP, candidate provider evaluation, components requiring change at migration |
| [Datadog Monitor Migration Notes](datadog-monitor-migration.md) | Migration from Azure Monitor to Datadog: metric name mappings, RabbitMQ alert options, PagerDuty wiring, readiness summary, decommission sequence |
| [Deployment Plan](DeploymentPlan.md) | Three-phase cloud platform deployment plan: Phase 1 manual bootstrap (ClickOps/CLI), Phase 2 manual Terraform, Phase 3 automated GitOps pipeline |

---

## Runbooks

Step-by-step procedures for specific operational tasks.

| Runbook | What it covers |
|---|---|
| [Add Atlas Database](runbooks/add-atlas-database.md) | Adding a new MongoDB Atlas database (integration) via Terraform |
| [ArgoCD Sync Failures](runbooks/argocd-sync-failures.md) | Diagnosing and resolving ArgoCD application sync failures |
| [Atlas Credential Reconciliation](runbooks/atlas-credential-reconciliation.md) | Reconciling MongoDB Atlas database credentials with Key Vault |
| [Datadog Diagnostics](runbooks/datadog-diagnostics.md) | Diagnosing Datadog agent and integration issues |
| [Enable Prod Validate](runbooks/enable-prod-validate.md) | Enabling the `validate` sub-environment in production |
| [Pod Health Troubleshooting](runbooks/pod-health-troubleshooting.md) | Diagnosing and recovering unhealthy or stuck pods |
| [Validate Sub-env Config](runbooks/validate-subenv-config.md) | Validating sub-environment configuration before promotion |
| [Add SFTP Folders](runbooks/AddSFTPFoldersRunbook.pdf) | Adding new folders to an SFTP integration (PDF) |

---

## Audit

Responses to audit findings, grouped by severity.

| Document | What it covers |
|---|---|
| [Critical Findings Response](audit/critical-findings-response.md) | Responses to critical audit findings: change management (risk classification, rollback strategy), identity and access management (RBAC, MFA, secrets) |
| [High Findings Response](audit/high-findings-response.md) | Responses to high-risk audit findings: business continuity and DR, monitoring and incident management, SOP governance, asset inventory |
| [Medium Findings Response](audit/medium-findings-response.md) | Responses to medium-risk audit findings |

---

## PDF Runbooks

Legacy operational procedures in PDF format.

- [Add SFTP Folders](AddSFTPFolders.pdf)
- [How To Fix Stuck SFTP Outbound Queues](HowToFixStuckSFTPOutboundQueues.pdf)
- [Promote SFTP Between Environments](PromoteSFTPBetweenEnvs.pdf)
