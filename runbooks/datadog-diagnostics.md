# Runbook: Diagnosing Datadog Integration Issues

This runbook covers how to diagnose and resolve common Datadog issues on
AKS clusters managed by the Datadog Operator, including missing metrics,
broken integration dashboards, and failed autodiscovery checks.

---

## Background

### Deployment architecture

Datadog is deployed to each AKS cluster via the Datadog Operator using
Terraform (`terraform-infra/env/azure_datadog.tf`, module at
`terraform-infra/env/modules/datadog_agent/`). The stack has three
components:

- **Datadog Operator** — a Helm release (`datadog-operator`) in the
  `datadog` namespace. Reconciles `DatadogAgent` CRs into DaemonSets and
  Deployments.
- **Node Agent** — a DaemonSet with one pod per AKS node. Collects
  container logs, host metrics, and runs autodiscovery checks.
- **Cluster Agent** — a Deployment (1 replica on staging, 2 on prod/prod3).
  Handles cluster-level checks (Kubernetes state, external integrations,
  admission controller).

### Operator v2 label scheme

The Datadog Operator v2 (`datadoghq.com/v2alpha1`) uses different pod
labels than the legacy Helm-based deployment. Use these selectors:

```bash
# Node Agent pods
kubectl get pods -n datadog -l agent.datadoghq.com/component=agent

# Cluster Agent pods
kubectl get pods -n datadog -l agent.datadoghq.com/component=cluster-agent

# Operator pod
kubectl get pods -n datadog -l app.kubernetes.io/name=datadog-operator
```

The legacy selectors `app=datadog` and `app=datadog-cluster-agent` do
**not** match Operator v2 pods.

### Container include/exclude filtering

The node agent is configured with `DD_CONTAINER_INCLUDE` /
`DD_CONTAINER_EXCLUDE` environment variables that act as an allowlist.
**Excluded containers are skipped for everything: logs, metrics, AND
check autodiscovery.** If a namespace is not in `DD_CONTAINER_INCLUDE`,
the agent will not run any checks against pods in that namespace, even if
those pods have valid `ad.datadoghq.com/` annotations.

The `datadog` namespace itself must be in the include list for the Operator
pod's built-in openmetrics check to be discovered.

### Autodiscovery and `configcheck`

The agent discovers checks via pod annotations (`ad.datadoghq.com/<container>.*`).
The `agent configcheck` command shows what checks the agent on a specific
node has resolved via autodiscovery. It only shows checks for containers
running on **that agent's own node** — always run it on the agent pod that
shares a node with the target pod.

---

## Orientation checks

Run these first to establish baseline health.

```bash
# All Datadog pods and their status
kubectl get pods -n datadog -o wide

# DatadogAgent CR status
kubectl get datadogagent -n datadog
kubectl describe datadogagent datadog -n datadog

# ExternalSecret sync status (API/app keys from Key Vault)
kubectl get externalsecret -n datadog
```

A healthy deployment shows:
- Operator pod: `Running` (1/1)
- Node Agent pods: `Running` (all containers ready) on every node
- Cluster Agent pod(s): `Running`
- ExternalSecret: `SecretSynced / True`

---

## Verify metrics are flowing

A flat or missing metric in the Datadog UI does not necessarily mean the
agent is down. Always verify with a targeted query first.

```bash
# In Datadog Metrics Explorer:
# Wrong: sum:datadog.agent.running{*}
# This shows the metric VALUE (always 1 per agent), not a count of agents.

# Correct: break down by host to see one series per reporting agent
sum:datadog.agent.running{*} by {host}
```

Each reporting node agent produces one series. If the number of series
matches your node count, all agents are healthy.

Also check agent connectivity directly:

```bash
kubectl exec -n datadog \
  $(kubectl get pod -n datadog -l agent.datadoghq.com/component=agent \
    -o name | head -1) \
  -- agent diagnose --include connectivity-datadog 2>/dev/null
```

38/38 checks passing confirms the agent can reach Datadog and the API key
is valid.

---

## Diagnosing a missing integration dashboard

When an out-of-the-box Datadog integration dashboard shows "MISSING DATA"
or no metrics, work through these steps.

### Step 1: Confirm the correct agent node

Integration checks run on the node agent pod that shares a node with the
target pod. Using `head -1` to select an agent pod can silently pick the
wrong node.

```bash
# Find which node the target pod is on
TARGET_NODE=$(kubectl get pod -n <namespace> <pod-name> \
  -o jsonpath='{.spec.nodeName}')
echo "Target node: $TARGET_NODE"

# Find the agent on that node
kubectl get pod -n datadog -l agent.datadoghq.com/component=agent \
  --field-selector spec.nodeName=$TARGET_NODE -o name
```

Also check for stale completed pods — label selectors can match old
`Completed` pods from previous ReplicaSets, pointing you at the wrong node:

```bash
kubectl get pods -n datadog -l app.kubernetes.io/name=datadog-operator \
  -o wide
```

Look for a `Running` pod, not a `Completed` one. The ReplicaSet hash in
the pod name changes on each Helm upgrade.

### Step 2: Check autodiscovery annotations on the target pod

```bash
kubectl get pod -n <namespace> <pod-name> \
  -o jsonpath='{.metadata.annotations}' | jq .
```

Look for `ad.datadoghq.com/<container>.check_names`,
`ad.datadoghq.com/<container>.init_configs`, and
`ad.datadoghq.com/<container>.instances`. Note the exact container name
used as the annotation key prefix — it must match the actual container
name in the pod spec:

```bash
kubectl get pod -n <namespace> <pod-name> \
  -o jsonpath='{.spec.containers[*].name}'
```

A mismatch between the annotation key container name and the actual
container name means the check will never be discovered.

### Step 3: Confirm the namespace is in the include list

```bash
kubectl get pod -n datadog <agent-pod-name> \
  -o jsonpath='{.spec.containers[?(@.name=="agent")].env[?(@.name=="DD_CONTAINER_INCLUDE")].value}'
```

If the target pod's namespace is absent, the agent will not discover any
checks in that namespace regardless of annotations. Fix: add the namespace
to `DD_CONTAINER_INCLUDE` and `DD_CONTAINER_INCLUDE_METRICS` in the
relevant `datadog-agent-<env>.yaml` manifest and re-apply.

### Step 4: Verify the check is resolved by configcheck

Run on the agent pod that shares a node with the target:

```bash
kubectl exec -n datadog <agent-pod-on-target-node> \
  -- agent configcheck 2>/dev/null | grep -B 2 -A 25 "<check-keyword>"
```

A resolved check shows `Config for instance ID: <check>:<namespace>:<hash>`
with a concrete IP substituted for `%%host%%`. If the check is absent,
one of the earlier steps has the answer.

### Step 5: Check the check's runtime status

```bash
kubectl exec -n datadog <agent-pod> \
  -- agent status 2>/dev/null | grep -A 10 "<check-name>"
```

Look for `Status: OK`. `Status: Error` with a message points to a
connectivity or credentials problem at the check level.

---

## Datadog Operator integration dashboard

The "Datadog Operator" out-of-the-box dashboard requires the Operator's own
Prometheus metrics endpoint (port 8383) to be scraped. The Datadog Operator
Helm chart ships autodiscovery annotations on the Operator pod by default
(using container name `datadog-operator` and `prometheus_url`). These will
only be picked up if:

1. The `datadog` namespace is in `DD_CONTAINER_INCLUDE`
2. The agent is queried on the same node as the **running** Operator pod
   (not a stale `Completed` pod from a previous rollout)

Verify with:

```bash
# Confirm annotations exist on the running pod
kubectl get pod -n datadog \
  $(kubectl get pod -n datadog -l app.kubernetes.io/name=datadog-operator \
    --field-selector status.phase=Running -o name | head -1) \
  -o jsonpath='{.metadata.annotations}' | jq .

# Check metrics are flowing
# In Datadog Metrics Explorer:
sum:datadog.operator.controller_runtime_reconcile_total{*} by {controller}
```

---

## nginx ingress log collection on AKS (containerd)

The `extraConfd` log configs in the DatadogAgent manifest must use
`ad_identifiers` (image short name), not `type: docker`. The `type: docker`
source does not work on AKS because AKS uses the containerd runtime.

Correct config in `datadog-agent-<env>.yaml`:

```yaml
extraConfd:
  configDataMap:
    nginx_ingress_logs.yaml: |-
      ad_identifiers:
        - nginx-ingress-controller
      logs:
        - source: nginx-ingress-controller
          service: nginx-ingress
          tags:
            - component:ingress
            - cluster_name:<cluster>
            - team:devops
          log_processing_rules:
            - type: multi_line
              name: log_start_with_date_slash
              pattern: \d{4}/\d{2}/\d{2}
```

External vs internal NGINX controllers share the same image and therefore
the same `ad_identifiers` entry. Differentiate them at query time in Datadog
using the auto-tagged `kube_app_instance` label (`nginx` vs
`nginx-internal-0`).

---

## Azure integration tiles with no data

### "MISSING DATA" despite the sub-integration toggle being enabled

**"Azure Usage and Quotas"** — controlled by the **"Usage Metrics"**
checkbox in the Metric Collection tab of the Datadog Azure integration (not
one of the ~90 resource-type toggles). Description: "Collect metrics for
your usage of Azure APIs vs. their quotas". Enable it and data appears
within a few minutes.

**"Azure Data Lake Analytics" / "Azure Data Lake Store"** — both services
are deprecated/retired by Microsoft (Data Lake Analytics retired February
2024; Data Lake Store Gen1 also deprecated). If your subscription has no
resources of these types, the tile will always be empty. Verify in the
Azure Portal by searching for "Data Lake" resources.

**"Azure Network Interface"** — the "Azure Network" toggle covers this
resource type. Empty tiles typically mean Azure is not emitting NIC-level
metrics. AKS-managed NICs (attached to node pool VMs) are platform-managed
and cannot have diagnostic settings configured on them directly. NIC traffic
metrics for AKS workloads are better sourced from within the cluster via the
Datadog agent's network stats or Azure Monitor Container Insights.

### Checking Azure service principal permissions

If a toggle is enabled but an Azure integration tile has no data and the
resources exist, check the permissions on the service principal Datadog uses
to read Azure metrics. It needs at minimum the built-in **Reader** role
scoped at the subscription level. Find it in Azure Portal under
Azure AD → App registrations (search for `datadog` or `dd-`), then check
its role assignments under the subscription.

---

## Quick reference: useful commands

```bash
# All Datadog pods
kubectl get pods -n datadog -o wide

# Node Agent logs
kubectl logs -n datadog -l agent.datadoghq.com/component=agent

# Cluster Agent logs
kubectl logs -n datadog -l agent.datadoghq.com/component=cluster-agent

# Agent status (run on the relevant agent pod)
kubectl exec -n datadog <agent-pod> -- agent status 2>/dev/null

# Autodiscovery check resolution (run on the relevant agent pod)
kubectl exec -n datadog <agent-pod> -- agent configcheck 2>/dev/null

# Connectivity diagnostics
kubectl exec -n datadog <agent-pod> \
  -- agent diagnose --include connectivity-datadog 2>/dev/null

# Confirm env vars on an agent pod
kubectl get pod -n datadog <agent-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="agent")].env[?(@.name=="DD_CONTAINER_INCLUDE")].value}'

# ExternalSecret (API/app key) sync status
kubectl get externalsecret -n datadog
kubectl describe externalsecret datadog-credentials -n datadog
```
