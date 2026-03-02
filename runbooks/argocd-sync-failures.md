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
| `Synced` | `Degraded` | Failure mode 1 (ExternalSecret error) |
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

## Phase 4: Verify the fix

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
            │    └─ Helm rendering error (Phase 3)
            │         Check: targetRevision points to feature branch?
            │         Fix:  merge branch → release/MP-1 or pin to stable ref
            │
            └─ sync.status = Synced, health.status = Degraded
                 └─ ExternalSecret failure (Phase 2)
                      Check: kubectl get externalsecret -n ${sbenv}
                      Fix:   az keyvault secret set --vault-name ${kv_name}
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
