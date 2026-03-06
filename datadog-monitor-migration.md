# Datadog Monitor Migration Notes

This document captures analysis of what it would take to replace Azure Monitor
Prometheus alert rules with Datadog monitors, as a prerequisite for removing
the Azure Monitor Workspace and Grafana stack from prod/prod3/staging/staging3.

## Context

Alerting currently flows through two mechanisms:

1. **Azure Monitor Prometheus rule groups** (`app-monitor/azure_alerts.tf`) —
   fires KubeContainerWaiting, KubePodUnhealthy, and RabbitMQ alerts, routing
   to PagerDuty via Azure Monitor action group webhooks.
2. **MongoDB Atlas alerts** (`env-monitor/atlas_alerts.tf`) — fires HOST_DOWN
   and connection threshold alerts, routing to PagerDuty and Microsoft Teams.

The Azure Monitor alert rules depend on the Azure Monitor Workspace (managed
Prometheus) being present. Removing that workspace (as part of a broader
Azure Monitor / Grafana decommission) requires rebuilding these rules as
Datadog monitors first.

MongoDB Atlas alerts are independent of Azure Monitor and do not need to
change.

## Where Datadog Monitors Would Live

Datadog monitors are org-level resources, not per-environment. The `org/`
workspace already has the Datadog provider configured (it manages
`datadog_logs_index`). A new `org/datadog_monitors.tf` is the natural home.

Unlike `app-monitor/azure_alerts.tf` — which runs once per environment
workspace and scopes PromQL queries to that environment's namespaces — Datadog
monitors use tag filters (`kube_cluster_name`, `kube_namespace`) to scope
by environment within a single monitor definition covering all alert
environments (prod, prod3, staging, staging3).

## KubeContainerWaiting and KubePodUnhealthy

### Metric availability

Both alerts use kube-state-metrics. The DatadogAgent CR in all manifests has
`kubeStateMetricsCore.enabled: true`, so the Cluster Agent already collects
these metrics cluster-wide. Importantly, `kubeStateMetricsCore` is NOT subject
to the `DD_CONTAINER_INCLUDE/EXCLUDE` namespace filtering — those env vars only
affect the Node Agent's direct container monitoring. Coverage across all
sub-environment namespaces (configure, preview, validate, accept, my) is
therefore already present.

### Metric name mapping

| Azure PromQL metric | Datadog metric |
|---|---|
| `kube_pod_container_status_waiting_reason` | `kubernetes_state.container.status_report.count.waiting` |
| `kube_pod_status_phase` | `kubernetes_state.pod.status_phase` |

### Example Terraform

```hcl
resource "datadog_monitor" "kube_container_waiting" {
  name    = "KubeContainerWaiting - {{kube_cluster_name.name}} {{kube_namespace.name}}"
  type    = "metric alert"
  message = <<-EOT
    Pod {{pod_name.name}} in {{kube_namespace.name}} is stuck in {{reason.name}} state.
    @pagerduty-vozni-prod-apps @pagerduty-vozni-staging-apps
  EOT

  query = <<-EOT
    max(last_10m):max:kubernetes_state.container.status_report.count.waiting{
      kube_cluster_name IN (vozni-prod-aks, vozni-prod3-aks, vozni-staging-aks, vozni-staging3-aks),
      reason IN (errimagepull, imagepullbackoff, createcontainerconfigerror, crashloopbackoff)
    } by {kube_cluster_name, kube_namespace, pod_name, reason} >= 1
  EOT

  monitor_thresholds {
    critical = 1
  }

  notify_no_data      = false
  require_full_window = false
  priority            = 1
}

resource "datadog_monitor" "kube_pod_unhealthy" {
  name    = "KubePodUnhealthy - {{kube_cluster_name.name}} {{kube_namespace.name}}"
  type    = "metric alert"
  message = <<-EOT
    Pod {{pod_name.name}} in {{kube_namespace.name}} is in {{phase.name}} state.
    @pagerduty-vozni-prod-apps @pagerduty-vozni-staging-apps
  EOT

  query = <<-EOT
    max(last_5m):max:kubernetes_state.pod.status_phase{
      kube_cluster_name IN (vozni-prod-aks, vozni-prod3-aks, vozni-staging-aks, vozni-staging3-aks),
      phase IN (pending, unknown, failed)
    } by {kube_cluster_name, kube_namespace, pod_name, phase} >= 1
  EOT

  monitor_thresholds {
    critical = 1
  }

  notify_no_data      = false
  require_full_window = false
  priority            = 1
}
```

## RabbitMQ Alerts

### Prerequisite: Prometheus scraping is not enabled

The current Azure Monitor rules scrape raw Prometheus metrics from RabbitMQ
pods (port 15692). In all DatadogAgent manifests, `prometheusScrape.enabled:
false`, so these metrics are not currently in Datadog. They must be enabled
before any RabbitMQ monitors can be written.

### Option A: Enable Prometheus scraping (recommended)

Lower effort. Keeps the same metric semantics. Required for
RabbitmqUnroutableMessages in any case (the management API integration does
not expose unroutable message counters).

1. Set `prometheusScrape.enabled: true` in the DatadogAgent manifests
   (`env/modules/datadog_agent/manifests/datadog-agent-{staging,prod,prod3}.yaml`).
2. Add autodiscovery annotations to the RabbitMQ pods or services:

```yaml
annotations:
  ad.datadoghq.com/rabbitmq.checks: |
    {
      "openmetrics": {
        "instances": [{
          "openmetrics_endpoint": "http://%%host%%:15692/metrics",
          "namespace": "rabbitmq",
          "metrics": [".*"]
        }]
      }
    }
```

Metrics arrive in Datadog with a `rabbitmq.` prefix matching the Prometheus
metric names (e.g., `rabbitmq.queue.messages.unacked`).

### Option B: Datadog RabbitMQ integration (management API)

Higher effort, richer data, but does not cover unroutable message counters.
Requires configuring a cluster check in the DatadogAgent CR that connects to
the RabbitMQ management API on each RabbitMQ instance. Not recommended as the
sole approach given the unroutable messages gap.

### Metric name mapping (Prometheus scraping path)

| Azure PromQL metric | Datadog metric |
|---|---|
| `rabbitmq_channel_messages_unroutable_returned_total` | `rabbitmq.channel.messages.unroutable_returned.count` |
| `rabbitmq_channel_messages_unroutable_dropped_total` | `rabbitmq.channel.messages.unroutable_dropped.count` |
| `rabbitmq_connections` | `rabbitmq.connections` |
| `rabbitmq_queue_messages_unacked` | `rabbitmq.queue.messages.unacked` |
| `rabbitmq_queues` | `rabbitmq.queue.count` |
| `rabbitmq_consumers` | `rabbitmq.queue.consumers` |
| `rabbitmq_process_resident_memory_bytes` | `rabbitmq.node.mem_used` |
| `rabbitmq_resident_memory_limit_bytes` | `rabbitmq.node.mem_limit` |

### Example Terraform (one alert shown)

```hcl
resource "datadog_monitor" "rabbitmq_unack_messages" {
  name    = "RabbitmqUnackMessages - {{kube_cluster_name.name}} {{kubernetes_namespace.name}}"
  type    = "metric alert"
  message = <<-EOT
    RabbitMQ queue {{queue.name}} in {{kubernetes_namespace.name}} has unacknowledged messages.
    @pagerduty-vozni-prod-rabbitmq @pagerduty-vozni-staging-rabbitmq
  EOT

  query = <<-EOT
    sum(last_5m):sum:rabbitmq.queue.messages.unacked{
      kube_cluster_name IN (vozni-prod-aks, vozni-prod3-aks, vozni-staging-aks, vozni-staging3-aks)
    } by {kube_cluster_name, kubernetes_namespace, queue} >= 1
  EOT

  monitor_thresholds {
    critical = 1
  }

  notify_no_data      = false
  require_full_window = false
  priority            = 1
}
```

## PagerDuty Wiring

Currently Azure Monitor action groups POST directly to PagerDuty webhook URLs
via `pagerduty_service_integration.azure_apps` and `azure_rabbitmq` in
`app-monitor/azure_alerts.tf`. The existing `pagerduty_service` resources
(`apps`, `rabbitmq`) can be reused — only the integration changes.

Add a Datadog `pagerduty_service_integration` alongside the existing Azure one
for each service, then reference it in monitor messages using
`@pagerduty-<service-name>`. The `pagerduty_service` resources and escalation
policies in `app-monitor/pagerduty.tf` remain unchanged.

## Migration Readiness Summary

| Alert | Metrics in Datadog today? | Effort |
|---|---|---|
| KubeContainerWaiting | Yes (kubeStateMetricsCore) | Low — write monitors |
| KubePodUnhealthy | Yes (kubeStateMetricsCore) | Low — write monitors |
| RabbitmqUnroutableMessages | No — requires Prometheus scraping | Medium-High |
| RabbitmqTooManyConnections | No — requires Prometheus scraping | Medium |
| RabbitmqUnackMessages | No — requires Prometheus scraping | Medium |
| RabbitmqTooManyQueues | No — requires Prometheus scraping | Medium |
| RabbitmqNoConsumers | No — requires Prometheus scraping | Medium |
| RabbitmqMemoryHigh | No — requires Prometheus scraping | Medium |

The Kube alerts are ready to implement now. All RabbitMQ alerts are blocked on
enabling Prometheus scraping in the DatadogAgent manifests first.

## Broader Decommission Sequence

Once all Datadog monitors are in place and validated:

1. Remove `azurerm_monitor_data_collection_rule_association.logs_dcra`
2. Remove `azurerm_monitor_data_collection_rule.logs_dcr`
3. Remove `azurerm_monitor_data_collection_endpoint.logs_dce`
4. Remove `azurerm_log_analytics_solution.container_insights`
5. Remove `azurerm_log_analytics_workspace.main`
6. Remove `helm_release.grafana` (after confirming Datadog dashboards are sufficient)
7. Remove the three recording rule groups (`aks_node_recording`, `aks_kubernetes_recording`, `aks_ux_recording`)
8. Remove `azurerm_monitor_data_collection_rule_association.dcra`
9. Remove `azurerm_monitor_data_collection_rule.dcr` (prometheus)
10. Remove `azurerm_monitor_data_collection_endpoint.dce`
11. Remove `azurerm_monitor_workspace.main`
12. Remove the `app-monitor` workspace entirely (Azure alert rules + Azure PagerDuty integrations replaced by Datadog)
