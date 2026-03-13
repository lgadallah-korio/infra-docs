# Runbook: Diagnose and Fix ArgoCD Application Sync Failures

This runbook was originally written while investigating why
`int-nest-node-configure`, `int-nest-node-v1-0-0-configure`,
`int-rave-consumer-node-configure`, and `int-rave-producer-node-configure`
were stuck out-of-sync in the `prod-configure` sub-environment (2026-02-26).
It has been generalised so it can be followed for any ArgoCD Application in
any `{env}-{subenv}`.

**Repos checked:** `argocd`, `presto-besto-manifesto`, `kubernetes-manifests`
**Azure resources checked:** Key Vault secrets
**Runtime checks:** ArgoCD application status, ExternalSecret status

---

## Set variables before starting

```bash
export kenv="prod"           # environment name  (prod | staging | test | ...)
export sbenv="configure"     # sub-environment   (configure | validate | accept | my | preview)
export app="int-rave-consumer-node-configure"   # ArgoCD Application name (<service>-<subenv>)
export svc="int-rave-consumer-node"             # service name (matches AppSet metadata.name)
export kv_name="vozni-${kenv}-${sbenv}"         # Key Vault name provisioned by Terraform
```

---

## Background

### ArgoCD status model

ArgoCD tracks two orthogonal dimensions for each Application:

- **Sync status** — does the desired state (rendered from Git/Helm) match the
  live state in the cluster?
  - `Synced` — live state matches desired state
  - `OutOfSync` — a diff exists; ArgoCD will attempt to reconcile
  - `Unknown` — ArgoCD could not compute the desired state (e.g. Helm rendering
    error)

- **Health status** — are the deployed resources actually healthy?
  - `Healthy` — all resources are ready and running
  - `Degraded` — one or more resources are in a failed state (e.g. a pod
    crashing, an ExternalSecret stuck in `SecretSyncedError`)
  - `Progressing` — resources exist but are not yet ready

All four apps in this runbook use `automated.selfHeal: true`, which means
ArgoCD will continuously attempt to re-apply the desired state. If an
application remains `OutOfSync` or `Degraded` despite self-healing, the root
cause is not a one-time drift but a structural issue that each sync attempt
hits identically.

### Two common failure modes

**Failure mode 1 — Missing Key Vault secret (ExternalSecret failure)**

The Helm chart renders an `ExternalSecret` CR for each secret listed in the
AppSet's `externalSecret:` block. The External Secrets Operator (ESO) then
attempts to pull each referenced key from the Azure Key Vault. If the key does
not exist in the vault, ESO sets the ExternalSecret's status to
`SecretSyncedError`. ArgoCD health checks detect the failed ExternalSecret and
mark the Application as `Degraded`.

This commonly occurs when a service is newly onboarded to an environment and
the service-specific secrets (e.g. integration passwords) have not yet been
created in the sub-env's Key Vault. Even when a sub-env uses dummy/placeholder
credentials for an integration (as `configure` does for most external
integrations), the Key Vault entries must still exist — ESO does not
distinguish between a real password and a placeholder.

**Failure mode 2 — Helm chart rendering error (SyncFailed / Unknown)**

The AppSet's `source.targetRevision` points to a specific branch of the
`kubernetes-manifests` Helm chart. If that branch introduces a new template
feature, a new required value, or a breaking change that is incompatible with
the values being passed, ArgoCD cannot render the desired state at all. The
Application will show `Unknown` sync status with a `ComparisonError`.

This commonly occurs when a service uses a feature branch (rather than
`release/MP-1` or a semver tag) that is still in development and may have
template bugs or unmet dependencies.

**Failure mode 3 — Cluster resource exhaustion (pods stuck Pending)**

The AKS node pool may not have sufficient CPU or memory to schedule new pods.
When this happens, pods remain in `Pending` state indefinitely. ArgoCD health
checks detect the unscheduled pods and mark the Application `Progressing` (and
eventually `Degraded` if the rollout deadline is exceeded). Sync status may
show `Synced` — the desired state was applied to the API server successfully —
but the workload is not actually running.

This commonly occurs after a wave of new sub-environment activations (e.g.
enabling `staging-validate` alongside other sub-envs) where the combined
resource requests of all new pods exceed available node capacity.

**Failure mode 4 — Image pull failure / incorrect image reference**

If the container image tag referenced in the AppSet does not exist in the
registry, or exists but is inaccessible, pods will fail to start with
`ImagePullBackOff` or `ErrImagePull`. ArgoCD marks the Application `Degraded`.

A related case: an image tag that exists in the registry but refers to the
wrong build (e.g. a stale tag, a branch that never built successfully, or a
tag that was overwritten). The pod starts from ArgoCD's perspective, but the
running container is not the intended version. This can make a deployment
appear to succeed while actually running incorrect code, or appear to fail
when the image reference simply needs to be corrected.

---

**Failure mode 5 — Deprecated Helm chart repository (Bitnami HTTP → OCI)**

Bitnami deprecated their HTTP Helm chart repository
(`https://charts.bitnami.com/bitnami`) and migrated to OCI
(`oci://registry-1.docker.io/bitnamicharts`). After the deprecation,
Bitnami modified the HTTP repo's `index.yaml` in a way that ArgoCD's
repo-server rejects, producing:

```
ComparisonError: Failed to load target state: failed to generate manifest
for source 1 of 1: rpc error: code = Unknown desc = invalid revision
'HEAD': improper constraint: HEAD
```

ArgoCD uses a stricter Helm index parser than the `helm` CLI — the same
chart version may pull successfully with `helm pull` while ArgoCD fails.
The apps show `Healthy / Synced` (reflecting the last successful sync)
alongside a sync error, which can make them appear healthy when they are
actually not being updated.

Affected ApplicationSets in this repo: all `rabbitmq-appset.yaml` and
`api-gateway-appset.yaml` / `internal-api-gateway-appset.yaml` files
(fixed in argocd PR #886, 2026-03-13).

Fix: change `repoURL` from `https://charts.bitnami.com/bitnami` to
`oci://registry-1.docker.io/bitnamicharts` in the ApplicationSet.
`chart:` and `targetRevision:` fields are unchanged.

---

## Phase 0: Pre-check — verify the sub-environment is activated

Before diagnosing individual application failures, confirm that the
sub-environment is actually registered in the presto-besto-manifesto pipeline.
If it is not, no ArgoCD Applications will exist for it — there is nothing to
sync or heal.

```bash
grep -w "${sbenv}" "presto-besto-manifesto/${kenv}/subenvironments.yaml"
```

**Expected:** a line containing `- ${sbenv}`.

If this returns no output, the sub-environment has never been activated in the
Dagger pipeline. All downstream symptoms (missing apps, nothing in ArgoCD for
this sub-env) are a consequence of this single missing entry — do not proceed
to Phase 1 until it is fixed.

**Fix:** add `${sbenv}` to `presto-besto-manifesto/${kenv}/subenvironments.yaml`,
open a PR, and merge it. The Dagger pipeline will run automatically and open a
follow-up PR on the `argocd` repo to add `${sbenv}` to all AppSets. Merge that
PR too, then return to Phase 1.

See also: `validate-subenv-config.md` check A1 and Phase 3a of the
sub-environment enable runbook for the full activation sequence.

---

## Phase 1: Identify the failure mode

### Step 1a: Check ArgoCD app status

```bash
# Via ArgoCD CLI (requires Twingate connected to ${kenv} network):
argocd app get "${app}" --server <argocd-server-for-${kenv}>

# Or via kubectl:
kubectl get application "${app}" -n argocd --context "${kenv}" -o yaml \
  | grep -A 20 "status:"
```

Look at the output for:
- `sync.status` — `Synced`, `OutOfSync`, or `Unknown`
- `health.status` — `Healthy`, `Degraded`, or `Progressing`
- `conditions[].message` — the human-readable error, if any
- `operationState.syncResult` — details of the last sync attempt

**Key distinction:**

| `sync.status` | `health.status` | Most likely cause |
|---|---|---|
| `Synced` | `Degraded` | Failure mode 1, 3, or 4 — check pod events first (Step 1d) |
| `Synced` | `Progressing` | Failure mode 3 (cluster resource exhaustion — pod Pending) |
| `OutOfSync` | Any | Failure mode 1 or 2 — check for rendering error first |
| `Unknown` | Any | Failure mode 2 (Helm rendering error) |
| `SyncFailed` | Any | Failure mode 2 (Helm rendering error) |

---

### Step 1b: Check ExternalSecret status (for Degraded apps)

If the app is `Synced` but `Degraded`, inspect the ExternalSecret objects in
the target namespace:

```bash
kubectl get externalsecret -n "${sbenv}" --context "${kenv}" \
  | grep "${svc}"
# Expected: all ExternalSecrets in Ready=True state
# If any show Ready=False or SecretSyncedError, proceed to Phase 2

kubectl describe externalsecret "${svc}-main" -n "${sbenv}" --context "${kenv}"
# Look for: Status.Conditions[].Message
# SecretSyncedError typically reads: "could not get secret <KEY-NAME> from provider"
```

> **prod-configure example:** `int-rave-consumer-node` was `Synced/Degraded`.
> Describing its ExternalSecret showed `SecretSyncedError` with
> `could not get secret RAVE-PASSWORD from provider` — the key did not exist in
> `vozni-prod-configure.vault.azure.net`.

---

### Step 1c: Check for Helm rendering errors (for Unknown/SyncFailed apps)

If the app shows `Unknown` or `SyncFailed`, the issue is likely in the Helm
chart rather than Key Vault. Check the sync error:

```bash
argocd app get "${app}" --server <argocd-server-for-${kenv}> \
  | grep -A 10 "Message:"

# Or check the Application's conditions:
kubectl get application "${app}" -n argocd --context "${kenv}" -o jsonpath \
  '{.status.conditions[*].message}'
```

---

### Step 1d: Check pod events (for Degraded or Progressing apps)

If the app is `Degraded` or `Progressing` and the ExternalSecret check (1b)
found no errors, inspect the pod directly:

```bash
# List pods for the service in the target namespace:
kubectl get pods -n "${sbenv}" --context "${kenv}" | grep "${svc}"

# Describe the pod to see scheduling and container events:
kubectl describe pod -n "${sbenv}" --context "${kenv}" \
  -l "app.kubernetes.io/name=${svc}" | tail -30
```

Look at the `Events:` section at the bottom:

| Event message | Failure mode | Next step |
|---|---|---|
| `0/N nodes available: insufficient cpu/memory` | Failure mode 3 (cluster resources) | Phase 4 |
| `Back-off pulling image` / `ImagePullBackOff` | Failure mode 4 (image pull) | Phase 5 |
| `Failed to pull image ... not found` | Failure mode 4 (image does not exist) | Phase 5 |
| `Error: secret ... not found` | Failure mode 1 (Key Vault) | Phase 2 |
| Pod already exists / `Terminating` (old pod present) | Previous rollout not yet complete | Wait, or force-delete the old pod |

> **Note — existing pod from a prior deployment:** If `kubectl get pods` shows
> a pod in `Terminating` or `Running` state with an older image while a new
> pod is `Pending` or `ContainerCreating`, the deployment is mid-rollout, not
> failed. Wait for the termination grace period to complete. If the old pod is
> stuck `Terminating`, force-delete it:
> ```bash
> kubectl delete pod <pod-name> -n "${sbenv}" --context "${kenv}" --grace-period=0 --force
> ```

Also check which `targetRevision` the AppSet uses:

```bash
grep "targetRevision" "argocd/apps/${kenv}/${svc}-appset.yaml"
# Expected: a stable branch like release/MP-1 or a semver tag
# If it is a feature branch (e.g. jl/some-feature/DI-XXXX), proceed to Phase 3
```

> **prod-configure example:** `int-nest-node` and `int-nest-node-v1-0-0` used
> `targetRevision: jl/korio-platform-version-env-var/DI-2647` — a feature
> branch adding `envFromDownwardAPI` support for the `korioPlatformVersion`
> label. No other service in prod used this branch.

---

## Phase 2: Fix — missing Key Vault secrets

### Why secrets must exist even for dummy integrations

In sub-environments like `configure` that use mock/placeholder credentials
for external integrations, the envfrom ConfigMaps set usernames to `dummy` and
hostnames to `mock-sftp-server.dev-tools`. However, the corresponding
**passwords and connection strings** are still sourced from Key Vault via
ExternalSecret — because the Helm chart always renders ExternalSecret objects
for every entry in `externalSecret:`, regardless of whether the sub-env
actually uses them. ESO will fail if the Key Vault key doesn't exist, even
if the resulting pod would never use the secret value.

### Step 2a: Identify which secrets are missing

Cross-reference the AppSet's `externalSecret:` block against what exists in
the Key Vault:

```bash
# List what the AppSet expects:
grep -A 30 "externalSecret:" "argocd/apps/${kenv}/${svc}-appset.yaml"

# List what actually exists in Key Vault:
az keyvault secret list --vault-name "${kv_name}" \
  --query "[].name" -o tsv | sort
```

Any key referenced in `externalSecret:` that is absent from the `az keyvault
secret list` output is a missing secret and needs to be created.

Note: AppSet `externalSecret:` values use underscores and the Key Vault names
use hyphens. The Helm chart maps between them. For example:
`RAVE_PASSWORD: RAVE-PASSWORD` means Key Vault key name is `RAVE-PASSWORD`.
If there is a `secret_name:` override in the presto secrets file
(`presto-besto-manifesto/${kenv}/secrets/${svc}@any.yaml`), that overriding
name is the Key Vault key.

```bash
# Check for secret_name overrides:
cat "presto-besto-manifesto/${kenv}/secrets/${svc}@any.yaml"
```

> **prod-configure example for `int-rave-consumer-node`:**
> AppSet declared: `ALPHEUS_CV01201_RAVE_PASSWORD`, `KUMQUAT_KQB198103_EDC_PASSWORD`,
> `MODERNA_RAVE_PASSWORD`, `RAVE_PASSWORD`, `TAGWORKS_TGW101101_EDC_PASSWORD`,
> `MONGO_CONNECTION_STRING`, `MONGO_PASSWORD`, `RABBITMQ_URL`.
> The common secrets (`MONGO-*`, `RABBITMQ-URL`) existed. The five
> Rave/EDC-specific secrets did not.

---

### Step 2b: Create the missing secrets with placeholder values

For sub-environments that use mock or disabled integrations, a placeholder
value is sufficient. Use a value that makes it obvious the secret is
intentionally a stub:

```bash
# Create a single missing secret with a placeholder value:
az keyvault secret set \
  --vault-name "${kv_name}" \
  --name "<KEY-NAME>" \
  --value "placeholder" \
  --output none
# Example: --name "RAVE-PASSWORD" --value "placeholder"
```

To create multiple secrets at once:

```bash
for secret_name in \
  "ALPHEUS-CV01201-RAVE-PASSWORD" \
  "KUMQUAT-KQB198103-EDC-PASSWORD" \
  "MODERNA-RAVE-PASSWORD" \
  "RAVE-PASSWORD" \
  "TAGWORKS-TGW101101-EDC-PASSWORD"
do
  az keyvault secret set \
    --vault-name "${kv_name}" \
    --name "${secret_name}" \
    --value "placeholder" \
    --output none
  echo "Created: ${secret_name}"
done
```

> **Important:** For sub-environments where the integration IS active (e.g.
> `my`), use real credentials, not placeholders. Placeholder values are only
> appropriate for sub-environments where the integration is intentionally
> mocked or disabled.

---

### Step 2c: Trigger ESO to re-sync

ESO polls Key Vault on a schedule (typically every 1 hour). To force an
immediate re-sync without waiting:

```bash
# Annotate the ExternalSecret to trigger immediate refresh:
kubectl annotate externalsecret "${svc}-main" -n "${sbenv}" --context "${kenv}" \
  force-sync="$(date +%s)" --overwrite
```

Alternatively, delete and let ArgoCD recreate the ExternalSecret:

```bash
kubectl delete externalsecret "${svc}-main" -n "${sbenv}" --context "${kenv}"
# ArgoCD selfHeal will recreate it within ~30 seconds
```

---

## Phase 3: Fix — Helm chart feature branch issue

### Step 3a: Confirm the branch exists and is renderable

```bash
# Check what branch the AppSet uses:
grep "targetRevision" "argocd/apps/${kenv}/${svc}-appset.yaml"

# Verify the branch exists in kubernetes-manifests:
cd kubernetes-manifests
git fetch origin
git ls-remote --heads origin "<branch-name>"
# Expected: one line with the branch ref
# If no output: the branch was deleted or renamed
```

---

### Step 3b: Attempt a local Helm render to reproduce the error

```bash
# From inside the kubernetes-manifests repo on the feature branch:
git checkout "<feature-branch>"

# Try rendering the chart with the values from the AppSet:
helm template test-release ./helm/korio \
  --set appName="${svc}" \
  --set korioPlatformVersion="main" \
  --set image.tag="<tag-from-appset>" \
  --set serviceAccountName="${kenv}-${sbenv}-${svc}"
# If this command errors, the template has a rendering bug
```

If the template renders cleanly locally but ArgoCD still reports a
`ComparisonError`, the issue may be a value that ArgoCD is passing but the
local render is not, or an ArgoCD-specific rendering restriction. Check the
ArgoCD error message for the specific template or value that failed.

---

### Step 3c: Resolution paths

**If the feature branch is a work-in-progress:**

The fix is to coordinate with the branch owner. Until the feature branch is
merged into `release/MP-1` or a stable tag, the AppSet will continue to fail
if the branch has rendering bugs. Options:

1. Merge the feature branch to `release/MP-1` and update `targetRevision` in
   the AppSet.
2. Pin `targetRevision` to a known-good commit SHA on the feature branch as a
   temporary workaround.
3. Roll back `targetRevision` to the previously working branch/tag while the
   feature is fixed.

**If the feature branch was already merged or deleted:**

Update `targetRevision` in the AppSet to point to the merged location:

```bash
# In argocd/apps/${kenv}/${svc}-appset.yaml:
#   Change:
#     targetRevision: jl/some-feature/DI-XXXX
#   To:
#     targetRevision: release/MP-1   # or the appropriate stable ref
```

Open a PR on the `argocd` repo with the change. When merged, ArgoCD will
pick up the new `targetRevision` on the next poll cycle.

> **prod-configure example:** `int-nest-node` and `int-nest-node-v1-0-0` used
> `jl/korio-platform-version-env-var/DI-2647`, which added `envFromDownwardAPI`
> to inject `KORIO_APP_NAME` and `KORIO_PLATFORM_VERSION` from pod labels.
> The fix was to merge that branch into `release/MP-1` and update the AppSet
> `targetRevision`.

---

## Phase 4: Fix — cluster resource exhaustion

### Step 4a: Confirm pods are Pending due to resources

```bash
# Identify Pending pods:
kubectl get pods -n "${sbenv}" --context "${kenv}" | grep Pending

# Confirm the reason is resource pressure (look for "Insufficient" in Events):
kubectl describe pod <pending-pod-name> -n "${sbenv}" --context "${kenv}" \
  | grep -A 5 "Events:"
```

Expected output will include lines like:
```
Warning  FailedScheduling  ...  0/3 nodes are available: 3 Insufficient cpu.
```

### Step 4b: Check current node utilization

```bash
kubectl top nodes --context "${kenv}"
# Shows current CPU/memory consumption per node vs. allocatable capacity

kubectl describe nodes --context "${kenv}" | grep -A 5 "Allocated resources"
# Shows how much of each node's allocatable capacity is already requested
```

### Step 4c: Scale up the AKS node pool

Scale the node pool through the Azure Portal or CLI. Identify the AKS cluster
and node pool name first:

```bash
az aks list -o table | grep "${kenv}"
az aks nodepool list --cluster-name <cluster-name> \
  --resource-group "vozni-${kenv}-aks-rg" -o table
```

Then scale:

```bash
az aks nodepool scale \
  --cluster-name <cluster-name> \
  --resource-group "vozni-${kenv}-aks-rg" \
  --name <nodepool-name> \
  --node-count <new-count>
```

Once new nodes are ready, the pending pods will be scheduled automatically
within a few minutes. Monitor with:

```bash
watch kubectl get pods -n "${sbenv}" --context "${kenv}" | grep "${svc}"
```

---

## Phase 5: Fix — image pull failure / incorrect image reference

### Step 5a: Identify the failing image reference

```bash
# Get the image the pod is trying to pull:
kubectl describe pod -n "${sbenv}" --context "${kenv}" \
  -l "app.kubernetes.io/name=${svc}" | grep -E "Image:|Failed to pull"
```

Also check what the AppSet specifies:

```bash
grep "tag\|image" "argocd/apps/${kenv}/${svc}-appset.yaml"
```

### Step 5b: Verify the image tag exists in the registry

Check whether the tag exists in the Azure Container Registry (ACR) or
whichever registry is in use:

```bash
# List tags for the repository (replace <registry> and <repo> as appropriate):
az acr repository show-tags \
  --name <registry-name> \
  --repository <image-repo> \
  --orderby time_desc \
  --top 10 \
  -o tsv | grep "<expected-tag>"
```

If the tag is missing, the CI pipeline that builds and pushes the image either
did not run or failed. Check the CI run for the relevant branch/commit in the
service's repository.

### Step 5c: Correct the image reference if wrong

If the AppSet references the wrong tag or image, update it in
`argocd/apps/${kenv}/${svc}-appset.yaml` (or in
`presto-besto-manifesto/${kenv}/` if the image is managed by presto) and open
a PR. Once merged, ArgoCD will pull the corrected image on the next sync.

> If the image reference is correct but the tag was recently pushed and ArgoCD
> has not re-synced yet, trigger a manual sync:
> ```bash
> argocd app sync "${app}" --server <argocd-server-for-${kenv}>
> ```

---

## Phase 6: Verify the fix

```bash
# Watch ArgoCD application status until Synced + Healthy:
watch argocd app get "${app}" --server <argocd-server-for-${kenv}>
# Expected final state: Sync Status: Synced, Health Status: Healthy

# Confirm ExternalSecret is Ready:
kubectl get externalsecret -n "${sbenv}" --context "${kenv}" | grep "${svc}"
# Expected: READY=True, STATUS=SecretSynced

# Confirm pod is Running:
kubectl get pods -n "${sbenv}" --context "${kenv}" | grep "${svc}"
# Expected: STATUS=Running, READY=1/1 (or N/N)
```

---

## Comparing AppSets to identify what's different

When a service is not syncing but structurally similar services are, the
fastest diagnostic is to diff the broken AppSet against a known-working one:

```bash
# Compare a broken AppSet against a working counterpart:
diff "argocd/apps/${kenv}/${svc}-appset.yaml" \
     "argocd/apps/${kenv}/<working-service>-appset.yaml"
```

Key fields to compare:

| Field | What to look for |
|---|---|
| `targetRevision` | Is the broken service on a feature branch while working services are on `release/MP-1`? |
| `externalSecret:` | Does the broken service reference more/different secrets than the working one? |
| `serviceAccountName` | Does the broken service require a named ServiceAccount? Does `identities.yaml` provision it? |
| `workloadIdentityClientId` | Is a UAMI Client ID referenced? Does it exist in Azure? |
| `envFromDownwardAPI` | Is a new Helm feature being used that the chart version doesn't support? |

---

## Quick-reference: failure mode decision tree

```
ArgoCD Application not Synced/Healthy
            │
            ├─ sync.status = Unknown / SyncFailed
            │    ├─ Helm rendering error (Phase 3)
            │    │    Check: targetRevision points to feature branch?
            │    │    Fix:  merge branch -> release/MP-1 or pin to stable ref
            │    │
            │    └─ "invalid revision 'HEAD': improper constraint: HEAD"
            │         Check: repoURL is https://charts.bitnami.com/bitnami?
            │         Fix:  change repoURL to oci://registry-1.docker.io/bitnamicharts
            │
            ├─ sync.status = Synced, health.status = Progressing
            │    └─ Cluster resource exhaustion (Phase 4)
            │         Check: kubectl describe pod ... | grep "Insufficient"
            │         Fix:  az aks nodepool scale --node-count <new-count>
            │
            └─ sync.status = Synced, health.status = Degraded
                 │
                 ├─ Pod events show ImagePullBackOff / ErrImagePull
                 │    └─ Image pull failure (Phase 5)
                 │         Check: az acr repository show-tags ...
                 │         Fix:  correct image tag in AppSet / trigger CI build
                 │
                 ├─ Pod events show "Insufficient cpu/memory"
                 │    └─ Cluster resource exhaustion (Phase 4)
                 │
                 ├─ Old pod stuck Terminating, new pod Pending/ContainerCreating
                 │    └─ Rolling update in progress (not a real failure)
                 │         Fix:  wait, or force-delete stuck pod (Step 1d)
                 │
                 └─ ExternalSecret Ready=False / SecretSyncedError
                      └─ Missing Key Vault secret (Phase 2)
                           Check: kubectl get externalsecret -n ${sbenv}
                           Fix:  az keyvault secret set --vault-name ${kv_name}
                                    --name <MISSING-KEY> --value "placeholder"
```

---

## Summary of changes (per failure mode)

### Failure mode 1 — Missing Key Vault secret

| System | Resource | Action |
|---|---|---|
| Azure Key Vault | `<MISSING-KEY>` in `vozni-${kenv}-${sbenv}` | Create with placeholder value |
| Kubernetes | ExternalSecret for `${svc}` | Annotate to force re-sync (or delete to recreate) |

No repo changes required.

### Failure mode 2 — Helm chart feature branch

| System | Resource | Action |
|---|---|---|
| `kubernetes-manifests` | Feature branch | Merge to `release/MP-1` (or fix rendering bug) |
| `argocd` | `apps/${kenv}/${svc}-appset.yaml` — `targetRevision` | Update to `release/MP-1` (or stable ref) |

### Failure mode 3 — Cluster resource exhaustion

| System | Resource | Action |
|---|---|---|
| AKS | Node pool | Scale up node count via `az aks nodepool scale` |

No repo changes required.

### Failure mode 4 — Image pull failure / incorrect image reference

| System | Resource | Action |
|---|---|---|
| CI pipeline | Image build for `${svc}` | Trigger build / verify tag was pushed to registry |
| `argocd` or `presto-besto-manifesto` | Image tag reference | Correct the tag and open a PR |

No Azure resource changes required.

### Failure mode 5 — Deprecated Bitnami HTTP Helm repository

| System | Resource | Action |
|---|---|---|
| `argocd` | `repoURL` in affected ApplicationSet | Change to `oci://registry-1.docker.io/bitnamicharts` and open a PR |

No Azure resource changes required. `chart:` and `targetRevision:` fields are unchanged.
