# Runbook: Diagnose Unhealthy Pods in a Namespace

This runbook covers how to identify and interpret unhealthy pods in any AKS
namespace, determine whether a failure is active or a benign artifact of
rolling deployments, and gather the evidence needed to fix the underlying
cause.

It applies to any `{env}-{subenv}` namespace (e.g. `staging-preview`,
`prod-configure`) and is written around the Korio sub-environment pipeline
(`configure` -> `preview` -> `validate` -> `accept` -> `my`).

---

## Set variables before starting

```bash
export kenv="staging"        # environment (dev | test | platform | staging | prod | ...)
export sbenv="preview"       # sub-environment (configure | preview | validate | accept | my)
export svc="int-pci-node"    # service name (matches the pod label app=<svc>)
```

---

## Background

### What "unhealthy" actually means

`kubectl get pods` reports a `STATUS` column that conflates several distinct
situations. Not all non-`Running` statuses represent active problems:

| Status | Meaning | Usually a problem? |
|---|---|---|
| `Running` | Container is executing | Only if RESTARTS is elevated |
| `Completed` | Container exited with code 0 | No — expected after a rolling update replaces the pod |
| `Error` | Container exited with a non-zero code | Only if it is the *current* pod, not a superseded old RS replica |
| `CrashLoopBackOff` | Container is crashing repeatedly; kubelet is throttling restarts | Yes — always investigate |
| `ImagePullBackOff` / `ErrImagePull` | kubelet cannot pull the container image | Yes — always investigate |
| `ContainerStatusUnknown` | The node hosting the pod became unreachable | Yes if recent; stale ones may be orphaned from old node disruptions |
| `Pending` | Pod has not been scheduled onto a node yet | Yes — usually resource exhaustion or a missing ServiceAccount |
| `Terminating` | Pod is being deleted | Transient — only a problem if stuck for many minutes |

### Active failures vs. stale replicas

A crucial distinction before investigating any pod: Kubernetes does **not**
immediately garbage-collect old ReplicaSet pods when a rolling update
completes. A pod from a superseded ReplicaSet can linger in `Error` or
`Completed` status indefinitely while the new pod runs healthily alongside it.

**A pod is a stale replica (not actionable) if:**
- Its status is `Error` or `Completed`, AND
- Another pod for the same service is `Running` with a different pod name
  suffix (different ReplicaSet hash), AND
- The stale pod is significantly older than the running one

**A pod is an active failure (investigate) if:**
- Its status is `CrashLoopBackOff` or `ImagePullBackOff`, OR
- It is the only (or newest) pod for that service and it is not `Running`, OR
- A `Running` pod has an unusually high restart count

### Why ContainerStatusUnknown pods accumulate

When an AKS node becomes unreachable (evicted, drained, or fails), kubelet
can no longer report the status of pods running on it. Kubernetes marks those
pods `ContainerStatusUnknown` and creates replacement pods on healthy nodes.
The old pods are not auto-deleted because Kubernetes cannot confirm they
terminated cleanly. Over time — especially for services that crash frequently,
triggering repeated node-level interventions — dozens of orphaned
`ContainerStatusUnknown` pods can accumulate for a single deployment.

These orphaned pods do not consume real compute resources, but they clutter
the namespace and can mask the true replica count. They should be cleaned up
manually once the underlying crash cause is fixed (see Phase 6).

### Why ExternalSecret failures can hide behind Running pods

ExternalSecret failures are a common but non-obvious cause of pod instability.
When ESO cannot pull a secret from Key Vault, it stops refreshing the
Kubernetes Secret but does not delete the stale copy that already exists. A
pod may continue running on those stale credentials — appearing healthy in
`kubectl get pods` — until the next restart, at which point it will fail to
start because the secret is no longer being kept current.

This means a `SecretSyncedError` ExternalSecret is always worth fixing even
when the pod appears healthy, and is a likely explanation for pods with high
historical restart counts that have since stabilised.

---

## Phase 1: Get the full pod inventory

### Step 1a: Confirm the correct kubectl context is active

```bash
kubectl config get-contexts
# The active context is marked with *
# Switch context if needed:
kubectl config use-context "vozni-${kenv}-aks"
```

### Step 1b: List all pods in the target namespace

```bash
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks"
```

This gives you name, READY (containers ready / total), STATUS, RESTARTS, and
AGE for every pod. Scan for anything that is not `Running` or `Completed`.

When checking multiple namespaces at once, run them in parallel:

```bash
for ns in configure preview validate; do
  echo "=== $ns ===" && \
  kubectl get pods -n "$ns" --context "vozni-${kenv}-aks"
done
```

### Step 1c: Filter to unhealthy pods only

```bash
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep -Ev "Running|Completed"
```

> **Note:** This grep will also suppress `Terminating`. If you want to see
> those too, adjust to `grep -v "^NAME\|1/1.*Running\|2/2.*Running"` etc.

### Step 1d: Identify whether failures are active or stale

For each non-Running pod, check if there is a healthy Running counterpart:

```bash
# Replace <service-prefix> with the relevant service name fragment
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep "<service-prefix>"
```

If you see one `Running` pod (newer) alongside one or more `Error`/`Completed`
pods (older), the older ones are stale replicas and are not the cause of any
current problem. Focus investigation on `CrashLoopBackOff`, `ImagePullBackOff`,
`ContainerStatusUnknown`, and elevated RESTARTS on `Running` pods.

---

## Phase 2: Check ExternalSecret status

Run this check as a standard part of every health sweep — not only when pods
are visibly crashing. A `SecretSyncedError` ExternalSecret can leave a pod
apparently `Running` on stale credentials while silently broken (see
Background above).

### Step 2a: List ExternalSecrets in the namespace

```bash
kubectl get externalsecret -n "${sbenv}" --context "vozni-${kenv}-aks"
```

Look for any row where STATUS is `SecretSyncedError` or READY is `False`.

When checking multiple namespaces at once:

```bash
for ns in configure preview validate; do
  echo "=== $ns ===" && \
  kubectl get externalsecret -n "$ns" --context "vozni-${kenv}-aks"
done
```

### Step 2b: Get the specific missing secret name

```bash
kubectl describe externalsecret "${svc}" -n "${sbenv}" \
  --context "vozni-${kenv}-aks" \
  | grep -A 10 "Status\|Message\|Reason"
```

The Events section identifies the exact Key Vault key ESO cannot find:

```
Warning  UpdateFailed  ...  error retrieving secret at .data[N],
         key: <KEY-NAME>, err: Secret does not exist
```

### Step 2c: Check for related missing secrets

When one secret is missing, check whether sibling secrets in the same
ExternalSecret are also absent. Cross-reference the `externalSecret:` block
in presto-besto-manifesto against what exists in Key Vault:

```bash
# See what secrets the service expects (note: secret_name overrides the
# Key Vault key name; entries without secret_name use the env var name
# with underscores replaced by hyphens):
cat "presto-besto-manifesto/${kenv}/secrets/${svc}@any.yaml"

# List all secrets currently in Key Vault
# (requires Twingate connected to the ${kenv} network):
az keyvault secret list --vault-name "vozni-${kenv}-${sbenv}" \
  --query "[].name" -o tsv | sort
```

> **Note:** Key Vault is behind a private endpoint and requires Twingate to be
> connected to the target environment's network. If Twingate is unavailable,
> rely on ESO event messages (Step 2b) to identify missing keys one at a time —
> ESO stops at the first failure per sync cycle, so additional missing secrets
> will surface as earlier ones are resolved.

### Step 2d: Create the missing secrets in Key Vault

For sub-environments where the integration is mocked or disabled (`configure`,
`preview`, `validate`), a placeholder value is sufficient:

```bash
az keyvault secret set \
  --vault-name "vozni-${kenv}-${sbenv}" \
  --name "<KEY-NAME>" \
  --value "placeholder" \
  --output none
```

To create multiple missing secrets at once:

```bash
for secret_name in \
  "MISSING-SECRET-ONE" \
  "MISSING-SECRET-TWO"
do
  az keyvault secret set \
    --vault-name "vozni-${kenv}-${sbenv}" \
    --name "${secret_name}" \
    --value "placeholder" \
    --output none
  echo "Created: ${secret_name}"
done
```

> **Important:** Use placeholder values only in sub-environments where the
> integration is intentionally disabled or mocked. For `accept` and `my`
> sub-environments where integrations are live, use real credentials.

### Step 2e: Force ESO to re-sync

ESO polls Key Vault on a schedule (typically every hour). Force an immediate
re-sync without waiting:

```bash
kubectl annotate externalsecret "${svc}" -n "${sbenv}" \
  --context "vozni-${kenv}-aks" \
  force-sync="$(date +%s)" --overwrite
```

Confirm the ExternalSecret transitions to `Ready=True`:

```bash
kubectl get externalsecret "${svc}" -n "${sbenv}" \
  --context "vozni-${kenv}-aks"
# Expected: STATUS=SecretSynced, READY=True
```

If it is still `SecretSyncedError` after a minute, describe again (Step 2b) —
a different key may now be the blocking error.

---

## Phase 3: Describe the pod

`kubectl describe pod` is the first tool to use for any `CrashLoopBackOff`,
`ImagePullBackOff`, or `Pending` pod. It provides:

- **Container image** — the exact image URI the pod is trying to run
- **Environment variables and volume mounts** — useful for spotting
  misconfigured secrets or missing volume bindings
- **Conditions** — whether the pod is `Ready`, `Initialized`, `Scheduled`
- **Events** — the most useful section: a timestamped list of what Kubernetes
  and kubelet did to the pod, including scheduling decisions, image pulls, and
  restart back-off messages

```bash
# Describe a specific pod by name:
kubectl describe pod <pod-name> -n "${sbenv}" --context "vozni-${kenv}-aks"

# Or describe all pods matching a label (avoids needing the exact pod name):
kubectl describe pod -n "${sbenv}" --context "vozni-${kenv}-aks" \
  -l "app=${svc}"
```

Focus on the `Events:` section at the bottom. Key event patterns:

| Event message | What it means | Next step |
|---|---|---|
| `Successfully pulled image ... Back-off restarting` | Image pulled OK; crash is application-level | Phase 4 (get logs) |
| `Back-off pulling image` / `Failed to pull image` | Image does not exist or is inaccessible in registry | Phase 5 |
| `0/N nodes available: insufficient cpu` / `insufficient memory` | Cluster resource exhaustion | Phase 7 |
| `Error: secret ... not found` | Missing Kubernetes Secret (often from a failed ExternalSecret) | Phase 2 |
| `Successfully assigned ... to <node>` then nothing else | Pod scheduled but stuck ContainerCreating | Check for missing volumes or slow image pull |

---

## Phase 4: Read the container logs

Logs are the primary tool for diagnosing application-level crashes
(`CrashLoopBackOff` where the image pulled successfully).

### Step 4a: Get current logs

```bash
kubectl logs <pod-name> -n "${sbenv}" --context "vozni-${kenv}-aks" --tail=50
```

`--tail=50` limits output to the last 50 lines. Increase for more context, or
omit entirely for the full log.

If the pod has multiple containers (READY shows e.g. `2/2`), specify which
container you want:

```bash
kubectl logs <pod-name> -n "${sbenv}" --context "vozni-${kenv}-aks" \
  -c <container-name> --tail=50
```

### Step 4b: Get previous-container logs (for CrashLoopBackOff)

When a pod is actively in `CrashLoopBackOff`, the current container may be in
back-off and producing no new output. The `--previous` flag retrieves logs from
the *last terminated* container instance, which captured the actual crash:

```bash
kubectl logs --previous <pod-name> -n "${sbenv}" \
  --context "vozni-${kenv}-aks" --tail=50
```

> **Note:** `--previous` log data is retained on the node's filesystem and
> will be lost if the node is replaced or the log buffer is evicted. For pods
> that have been crashing for days or weeks, `--previous` may return
> `unable to retrieve container logs for containerd://...` — in that case, the
> crash history is gone and you must rely on the current container's logs
> or external log storage (Datadog).

### Step 4c: Common crash patterns to look for

**Mongoose `openUri()` on an active connection:**
```
MongooseError: Can't call `openUri()` on an active connection with
different connection strings. Make sure you aren't calling
`mongoose.connect()` multiple times.
```
Cause: Multiple async message handlers (e.g. from a RabbitMQ queue backlog)
are each calling `mongoose.connect()` concurrently. The first call opens the
connection; subsequent calls with a different DB URI hit this error.
Fix: Application code must check whether a connection to the target URI is
already open before calling `connect()`. Also drain the message queue to
eliminate the flood of concurrent messages triggering the race condition.

**Missing tenant database:**
```
Unable to find tenant database: <env>-<subenv>-<client>
TypeError: Cannot read properties of undefined (reading 'model')
```
Cause: The service is configured with an integration that references a MongoDB
tenant database that does not exist in this sub-environment. `connectTenantDB()`
returns `undefined` and the subsequent `conn.model()` call crashes.
Fix: Check whether the integration's `tenantDbConnectionString` environment
variable points to the correct sub-environment database. If the DB simply does
not exist yet, it needs to be provisioned; if the connection string is wrong
(e.g. pointing at `preview` while running in `configure`), correct the secret
in Azure Key Vault.

**Node.js uncaught exception / unhandled promise rejection:**
The last lines before the process exits will show the exception type, message,
and stack trace. The stack trace is the primary diagnostic: identify the file
and line number, then look at the source in the corresponding service repo at
the commit SHA shown in the image tag.

---

## Phase 5: Diagnose ImagePullBackOff

When a pod's Events show `Back-off pulling image` or `Failed to pull image`,
the container never starts, so there are no application logs to read. The
diagnosis is entirely from `describe pod` and the registry.

### Step 5a: Get the exact image reference

```bash
kubectl describe pod <pod-name> -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep -E "Image:|Failed to pull|Back-off"
```

Note the full image URI including the tag or SHA digest.

### Step 5b: Check whether the image exists in ACR

```bash
# List the most recent tags for the image repository:
az acr repository show-tags \
  --name korio \
  --repository <image-repo-name> \
  --orderby time_desc \
  --top 20 \
  -o tsv
```

If the tag or SHA is absent, the image was either:
- Never built (the CI pipeline for that commit failed or never ran), or
- Deleted from ACR by a retention/purge policy

### Step 5c: Determine the fix

| Situation | Fix |
|---|---|
| Image was deleted from ACR; the version is still needed | Re-trigger the CI pipeline for the relevant branch/commit to rebuild and push the image |
| Image was deleted; the version is superseded | Remove or update the deployment in `presto-besto-manifesto` to point to a valid image tag |
| Image was never built (CI failure) | Investigate the CI run for the service repo at that commit; fix and re-trigger |
| Tag exists in ACR but pod still fails | Check ACR pull credentials — the `imagePullSecret` on the pod, or the AKS kubelet managed identity's ACR role assignment |

---

## Phase 6: Clean up orphaned ContainerStatusUnknown pods

After fixing the underlying application crash, orphaned pods from unreachable
nodes will remain in `ContainerStatusUnknown`. They should be deleted once the
service is stable.

### Step 6a: Identify orphaned pods for a service

```bash
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep "${svc}" | grep -v Running
```

### Step 6b: Delete them

```bash
# Delete a single pod:
kubectl delete pod <pod-name> -n "${sbenv}" --context "vozni-${kenv}-aks"

# Delete all non-Running pods for a service at once:
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep "${svc}" | grep -v Running \
  | awk '{print $1}' \
  | xargs kubectl delete pod -n "${sbenv}" --context "vozni-${kenv}-aks"
```

> **Caution:** Do not delete pods in bulk across all services at once. Identify
> the specific service first and confirm the Running pod is healthy before
> deleting its failed counterparts.

---

## Phase 7: Diagnose elevated restart counts on Running pods

A pod in `Running` status with a high RESTARTS count is not currently crashing
but has been unstable. Determine whether the restarts are historical or ongoing.

### Step 7a: Check the age of the last restart

The RESTARTS column shows total restarts and (in some kubectl versions) the
time of the most recent restart in parentheses, e.g. `454 (14d ago)`.

- **Last restart > several days ago:** The pod has recovered. The restart count
  is historical. Monitor but do not treat as an active incident.
- **Last restart < 1 hour ago or "recently":** The pod is actively unstable.
  Get current logs immediately (Phase 4a) and watch for another crash.

### Step 7b: Check whether an HPA is involved

If a pod keeps restarting and there are more replicas than expected, check
whether a Horizontal Pod Autoscaler is scaling the deployment aggressively:

```bash
kubectl get hpa -n "${sbenv}" --context "vozni-${kenv}-aks"
kubectl describe deployment "${svc}" -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep -E "Replicas|Image|Selector"
```

If the deployment's desired replica count is 1 but many pods exist with the
same pod template hash, the excess pods are **not** from scaling — they are
orphaned from prior node disruptions (see Background section above).

### Step 7c: Get current logs for a restarting Running pod

```bash
kubectl logs "${svc}-<hash>" -n "${sbenv}" --context "vozni-${kenv}-aks" \
  --tail=50
```

If the logs show normal operation (no errors, expected polling/processing
messages), the pod has recovered. If they show repeated errors or exception
traces, treat as an active crash (Phase 4).

---

## Phase 8: Verify the fix

After applying any fix, confirm the pod reaches a healthy steady state:

```bash
# Watch pod status for the service until Running:
watch kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep "${svc}"
# Expected: STATUS=Running, READY=N/N, RESTARTS not climbing

# Confirm ExternalSecret is healthy:
kubectl get externalsecret "${svc}" -n "${sbenv}" --context "vozni-${kenv}-aks"
# Expected: STATUS=SecretSynced, READY=True

# Check ArgoCD health if the service is managed by an Application:
argocd app get "${svc}-${sbenv}" --server <argocd-server-for-${kenv}>
# Expected: Sync Status: Synced, Health Status: Healthy
```

---

## Quick-reference decision tree

```
Start: health sweep of a namespace
          |
          +-- Always run Phase 2 first (ExternalSecret check)
          |     kubectl get externalsecret -n ${sbenv}
          |     Any SecretSyncedError / Ready=False?
          |       Yes -> Phase 2b-e: identify missing key, create in KV,
          |              force re-sync; then continue sweep below
          |
          +-- Pod STATUS = Completed
          |     -> Stale old RS replica. Check for Running counterpart.
          |        If Running counterpart exists: not actionable.
          |
          +-- Pod STATUS = Error
          |     -> Is there a Running counterpart for the same service?
          |        Yes -> Stale replica; not actionable.
          |        No  -> Active failure; go to Phase 3 + Phase 4.
          |
          +-- Pod STATUS = CrashLoopBackOff
          |     -> Always investigate.
          |        Phase 3: describe pod -> check Events section
          |        Phase 4: kubectl logs / kubectl logs --previous
          |
          +-- Pod STATUS = ImagePullBackOff / ErrImagePull
          |     -> Phase 3: describe pod -> get exact image URI
          |        Phase 5: check ACR for missing tag / rebuild CI
          |
          +-- Pod STATUS = ContainerStatusUnknown
          |     -> Node became unreachable. Is this a recent pod?
          |        Recent (hours/days): may be related to active crash loop;
          |          check if same service has CrashLoopBackOff pod.
          |        Old (weeks+): orphaned from past disruption.
          |          Phase 6: delete after confirming Running pod is healthy.
          |
          +-- Pod STATUS = Pending
          |     -> Phase 3: describe pod -> "Insufficient cpu/memory"?
          |        Yes -> Cluster resource exhaustion; scale node pool.
          |        No  -> Check for missing ServiceAccount, PVC, or secret.
          |
          +-- Pod STATUS = Running, but RESTARTS elevated
                -> Phase 7: is last restart recent?
                   Yes -> Phase 4: get current logs; treat as active crash.
                   No  -> Historical; check Phase 2 for SecretSyncedError;
                          monitor only if ExternalSecret is clean.
```

---

## Summary: commands used and their purpose

| Command | Purpose |
|---|---|
| `kubectl config get-contexts` | Confirm which cluster context is active before running any commands |
| `kubectl get pods -n <ns>` | Get pod inventory: name, status, restart count, age |
| `kubectl get externalsecret -n <ns>` | Check ExternalSecret sync status — identifies missing Key Vault secrets before they cause pod crashes |
| `kubectl describe externalsecret <name> -n <ns>` | Get the exact Key Vault key name that ESO cannot find, from the Events section |
| `kubectl annotate externalsecret <name> -n <ns> force-sync=...` | Force ESO to re-sync immediately after creating missing Key Vault secrets |
| `kubectl describe pod <name> -n <ns>` | Get scheduling events, container image, volume mounts, readiness conditions — primary tool for `CrashLoopBackOff`, `ImagePullBackOff`, `Pending` |
| `kubectl logs <name> -n <ns> --tail=N` | Get current container stdout/stderr — primary tool for diagnosing application crashes |
| `kubectl logs --previous <name> -n <ns>` | Get logs from the *last terminated* container instance — use when CrashLoopBackOff back-off prevents new log output |
| `kubectl get hpa -n <ns>` | Check whether a Horizontal Pod Autoscaler is managing replica count — rules out autoscaling as the cause of excess pods |
| `kubectl describe deployment <name> -n <ns>` | Check desired replica count and current rollout state — confirms whether excess pods are from scaling or node disruptions |
| `kubectl delete pod <name> -n <ns>` | Remove orphaned ContainerStatusUnknown pods after fixing the underlying cause |
| `az keyvault secret list --vault-name <vault>` | List all secrets in a Key Vault — cross-reference against the ExternalSecret to find all missing keys at once |
| `az keyvault secret set --vault-name <vault> --name <key>` | Create a missing Key Vault secret (placeholder or real value depending on sub-environment) |
| `az acr repository show-tags` | Verify whether a specific image tag exists in ACR — confirms whether `ImagePullBackOff` is a missing build or a transient pull failure |
