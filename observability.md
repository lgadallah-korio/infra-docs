# Observability

## Stack Overview

Korio uses three complementary layers for observability:

1. **Datadog** — primary platform for APM, log aggregation, infrastructure
   metrics, and integrations with ArgoCD and MongoDB Atlas.
2. **Azure Monitor** — native cloud layer providing managed Prometheus metrics,
   Container Insights for AKS, and a Log Analytics workspace. Serves as a
   cost-effective baseline and feeds Grafana.
3. **Grafana** — visualization layer connected to Azure Monitor and Prometheus,
   with pre-built dashboards for Kubernetes, NGINX, and RabbitMQ.

Alerting flows through **Azure Monitor Prometheus alert rules** for
infrastructure/application conditions and **MongoDB Atlas alerts** for
database events, both routing to **PagerDuty** for on-call notification.

All monitoring infrastructure is managed as Terraform in `terraform-infra/`,
split across four workspaces: `env/` (Datadog agent, Grafana, Azure Monitor),
`env-monitor/` (MongoDB alerts), `app-monitor/` (application and RabbitMQ
alert rules), and `org/` (PagerDuty services, global Datadog log indexing).

---

## Datadog

### Agent Deployment

Datadog is deployed to each AKS cluster via the Datadog Operator using a
Terraform Helm release defined in `terraform-infra/env/azure_datadog.tf`. The
module lives at `terraform-infra/env/modules/datadog_agent/`.

The deployment consists of two components:

- **Cluster Agent** — runs as a Deployment, handles cluster-level checks
  (Kubernetes state, external service integrations via cluster checks, admission
  controller). Runs 1 replica on non-prod environments, 2 replicas on
  prod/staging for HA.
- **Node Agent** — runs as a DaemonSet on every AKS node, collecting container
  logs, host metrics, and per-pod telemetry.

Datadog credentials (`datadog_api_key`, `datadog_app_key`) are passed as
Terraform variables (`TF_VAR_*`) at apply time and are never stored in state
unencrypted. Per-service credentials (MongoDB user/password, Atlas hostname)
are sourced from Azure Key Vault at runtime via ExternalSecrets.

### Per-Environment Configuration

Feature flags vary by environment. The canonical config lives in
`locals.datadog.config` inside `azure_datadog.tf`:

| Environment | APM | Live Containers | NPM | Cluster Agent Replicas |
|---|---|---|---|---|
| sandbox / dev / test / platform / platform3 | off | no | no | 1 |
| staging / staging3 | on | no | yes | 2 |
| prod / prod3 | on | yes | yes | 2 |

APM is disabled in lower environments to avoid noise and unnecessary cost.
Network Performance Monitoring (NPM) is only meaningful in production-like
environments where real traffic flows.

### Integrations

**ArgoCD** (`terraform-infra/env/helm/datadog-argocd.tpl.yaml`)

Configured via Datadog autodiscovery. The Cluster Agent scrapes metrics from
three ArgoCD endpoints:

- `argocd-application-controller:8082/metrics`
- `argocd-repo-server:8084/metrics`
- `argocd-server:8083/metrics`

Logs are tagged with `source:argocd`. The agent manifest includes processing
rules to suppress routine reconciliation and manifest-processing log lines,
which would otherwise dominate the log volume.

**MongoDB Atlas** (`terraform-infra/env/helm/datadog-mongodb.tpl.yaml`)

Configured as a Cluster Check (runs once per cluster, not per node), connecting
to Atlas via the Private Link endpoint. Database Monitoring (DBM) is enabled.
Credentials come from Key Vault secrets (`mongodb-atlas-host`,
`mongodb-datadog-user`, `mongodb-datadog-password`). Collected metric groups
include `metrics.commands`, `tcmalloc`, `top`, `collection`, and
`collections_indexes_stats`, with database autodiscovery enabled.

### Log Collection and Filtering

The Node Agent collects logs from all containers (`containerCollectAll: true`)
with automatic multiline detection enabled. NGINX ingress logs (both external
and internal gateways) are collected with explicit autodiscovery annotations
and tagged with `ingress_type:external/internal` for filtering in Datadog.

**Agent-level noise reduction** — Processing rules in the DatadogAgent manifest
exclude or suppress:

- `GET /api-docs/ 200` hits (API documentation endpoint polling)
- Internal IP connection reset/closed events
- SSH key exchange messages
- Uptime-Kuma health check requests
- ArgoCD reconciliation, manifest processing, and operational log lines

**Index-level sampling** (`terraform-infra/org/azure_datadog_logs.tf`) —
A priority-ordered set of exclusion filters on the main Datadog log index
controls what is retained and at what rate. Higher-volume, lower-signal logs
are sampled aggressively:

| Filter | Exclusion rate |
|---|---|
| API docs | 100% (never indexed) |
| Azure containerservice | 99% |
| SFTP errors | 99% |
| Azure warnings | 80% |
| General warnings | 70% |
| Status notice | 50% |
| Status info | 95% |
| Status ok | 99% |

This tiered approach keeps ingestion costs predictable while preserving
visibility into errors and warnings.

### OTLP / OpenTelemetry

The Node Agent's OTLP gRPC receiver is enabled on all environments. This
allows microservices instrumented with OpenTelemetry SDKs to emit traces and
metrics to the local agent without a separate collector sidecar.

---

## Azure Monitor

Configured in `terraform-infra/env/azure_monitoring.tf`, Azure Monitor
provides the native cloud observability layer alongside Datadog.

**Log Analytics Workspace** — One workspace per environment, with log
retention set to 30 days for dev/test and 60 days for staging and production.
SKU: PerGB2018.

**Azure Monitor Workspace (Managed Prometheus)** — Collects Prometheus metrics
from the AKS cluster without requiring a self-hosted Prometheus installation.
Feeds directly into Grafana as a data source.

**Container Insights** — Native AKS container monitoring solution, integrated
with the Log Analytics workspace. Provides pod/node/container views in the
Azure portal.

**Data Collection Rules** — Two DCRs handle the collection pipeline:

- `prometheus-dcr`: streams `Microsoft-PrometheusMetrics` from the cluster.
  Collection interval is 5 minutes for prod, 10 minutes for dev/test.
- `logs-dcr`: streams `Microsoft-ContainerInsights-Group-Default` with
  ContainerLogV2 format enabled.

**Prometheus Recording Rules** — Pre-aggregated metrics are defined in three
groups to support dashboarding at scale without query-time fanout:

- *AKS Node Recording Rules*: CPU count, CPU/memory utilization per node
- *AKS Kubernetes Recording Rules*: container CPU/memory usage, pod phase counts
- *AKS UX Recording Rules*: UI-optimized summaries for pods, nodes, and
  controllers (used by Grafana dashboards)

---

## Grafana

Grafana is deployed via Helm (`grafana/grafana v8.6.0`) into the `grafana`
namespace by Terraform (`terraform-infra/env/helm.tf`,
`terraform-infra/env/helm/grafana.tpl.yaml`).

### Authentication and RBAC

Access is controlled via GitHub OAuth through Dex (org: `korio-clinical`).
Team membership determines the Grafana role:

| GitHub team | Grafana role |
|---|---|
| devops | GrafanaAdmin |
| dev-leads (prod) / developers (non-prod) | Editor |
| All other org members | Viewer |

Azure Workload Identity (UAMI) is used for the Grafana service account to
authenticate against Azure Monitor without static credentials.

### Data Sources

| Source | Type |
|---|---|
| Azure Monitor | `grafana-azure-monitor-datasource` (Workload Identity auth) |
| Prometheus | Azure Monitor managed Prometheus endpoint |

### Pre-built Dashboards

Dashboards are provisioned from the `dotdc/grafana-dashboards-kubernetes`
collection plus community dashboards for NGINX and RabbitMQ:

- Kubernetes: global view, namespaces, nodes, pods
- Kubernetes system: API server, CoreDNS
- NGINX Ingress Controller
- RabbitMQ

---

## Alerting

### Prometheus Alert Rules

Defined in `terraform-infra/app-monitor/azure_alerts.tf` as Azure Monitor
Prometheus rule groups.

**Application alerts** (`azurerm_monitor_alert_prometheus_rule_group.apps`):

| Alert | Condition | Severity | For |
|---|---|---|---|
| KubeContainerWaiting | Container stuck in waiting (ErrImagePull, ImagePullBackOff, etc.) | 1 | 10m |
| KubePodUnhealthy | Pod in Pending / Unknown / Failed phase | 1 | 5m |

Both alerts auto-resolve after 15 minutes if the condition clears.

**RabbitMQ alerts** (`azurerm_monitor_alert_prometheus_rule_group.rabbitmq`):

| Alert | Condition | Severity | For |
|---|---|---|---|
| RabbitmqUnroutableMessages | Messages returned or dropped on a channel | 1 | 5m |
| RabbitmqTooManyConnections | >1000 connections to a node | 2 | 3m |
| RabbitmqUnackMessages | Unacknowledged messages on a queue | 1 | 5m |
| RabbitmqTooManyQueues | >300 queues on the instance | 2 | 3m |
| RabbitmqNoConsumers | <1 active consumer | 3 | 5m |
| RabbitmqMemoryHigh | >80% memory utilization | 2 | 5m |

### MongoDB Atlas Alerts

Defined in `terraform-infra/env-monitor/atlas_alerts.tf`.

| Alert | Type | Threshold |
|---|---|---|
| HOST_DOWN | Event | — |
| CONNECTIONS_PERCENT | Metric | >80% |

Notifications go to both a Microsoft Teams webhook and PagerDuty.

### PagerDuty

PagerDuty integration is split across three Terraform workspaces:

- `terraform-infra/app-monitor/pagerduty.tf` — apps and RabbitMQ services
- `terraform-infra/env-monitor/pagerduty.tf` — MongoDB service
- `terraform-infra/org/pagerduty.tf` — org-level services (Azure Defender)

**Services:** `apps`, `rabbitmq`, `mongo`, `defender`

**Escalation policy:**

- Layer 1: jlight + lgadallah (on-call rotation), 30-minute delay for prod /
  60-minute delay for non-prod
- Layer 2: lgadallah only (apps escalation path)

**Incident urgency:** severity-based for customer-facing environments; low
urgency for non-prod. This means prod pages wake people up; non-prod alerts
queue for business hours.

---

## Terraform Workspace Layout

```
terraform-infra/
├── env/                    # Per-environment: Datadog agent, Grafana, Azure Monitor,
│   │                       #   Log Analytics, managed Prometheus, Container Insights
│   ├── azure_datadog.tf
│   ├── azure_monitoring.tf
│   ├── helm.tf             # Grafana Helm release
│   └── helm/
│       ├── grafana.tpl.yaml
│       ├── datadog-argocd.tpl.yaml
│       └── datadog-mongodb.tpl.yaml
├── env-monitor/            # MongoDB Atlas alerts, PagerDuty mongo service
│   ├── atlas_alerts.tf
│   └── pagerduty.tf
├── app-monitor/            # Prometheus alert rules (apps, RabbitMQ),
│   │                       #   PagerDuty apps/rabbitmq services
│   ├── azure_alerts.tf
│   └── pagerduty.tf
└── org/                    # Org-wide: PagerDuty org config + Defender service,
    │                       #   Datadog log index and sampling filters
    ├── pagerduty.tf
    └── azure_datadog_logs.tf
```

---

## Troubleshooting

```bash
# Check Datadog pods
kubectl get pods -n datadog

# Node Agent logs
kubectl logs -n datadog -l app=datadog

# Cluster Agent logs
kubectl logs -n datadog -l app=datadog-cluster-agent

# Verify metrics are flowing (look for your cluster under Infrastructure → Containers in Datadog UI)
# Tags to check: env:<environment>, cluster_name:<cluster>
```

**MongoDB check not reporting:**
1. Verify Key Vault secrets `mongodb-atlas-host`, `mongodb-datadog-user`, `mongodb-datadog-password` are set
2. Verify the PrivateLink connection is active
3. Confirm the Datadog MongoDB user has the `clusterMonitor` role in Atlas

**Metrics missing from Grafana:**
1. Check Azure Monitor Workspace is receiving data (Azure portal → Monitor → Managed Prometheus)
2. Verify Grafana's Workload Identity UAMI has `Monitoring Reader` on the Azure Monitor Workspace
3. Confirm the DCR association between the AKS cluster and `prometheus-dce` is active

For detailed setup and customization options see
`terraform-infra/env/DATADOG_TERRAFORM_INTEGRATION.md` and
`terraform-infra/env/DATADOG_QUICK_REFERENCE.md`.
