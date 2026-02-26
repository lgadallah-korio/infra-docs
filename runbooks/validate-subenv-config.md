# Runbook: Validate a Sub-environment Configuration

Use this runbook to answer "Is `${kenv}-${sbenv}` correctly configured?" It
walks through every layer of the stack in order, from Terraform-provisioned
Azure resources down to live ArgoCD application health. Each check includes
the expected output and a pointer to the fix if something is missing.

**Repos checked:** `presto-besto-manifesto`, `argocd`, `kubernetes-manifests`
**Azure resources checked:** managed identities, FICs, Data Lake paths, Key
Vault, SFTP IP/disk
**Runtime checks:** Kubernetes namespace, ArgoCD application status

---

## Set variables before starting

```bash
export kenv="prod"        # environment name  (prod | staging | test | ...)
export sbenv="validate"   # sub-environment   (configure | validate | accept | my | preview)
export sftp_rg="vozni-${kenv}-sftp-storage"
export sub_id="<azure-subscription-id-for-${kenv}>"
# prod: 1a6c6f27-521f-4e1a-81e6-d855dd0b464a

# Sibling sub-env to compare against (typically configure or accept)
export sibling="configure"
```

---

## Quick-reference checklist

| # | Layer | What to check | Tool needed | Fix |
|---|---|---|---|---|
| 1 | Azure / Terraform | Key Vault exists | `az` | Add sub-env to `locals.tf` + apply |
| 2 | Azure / Terraform | SFTP managed disk exists | `az` | Add sub-env to `locals.tf` + apply |
| 3 | Azure / Terraform | SFTP public IP exists | `az` | Add sub-env to `locals.tf` + apply |
| 4 | Azure / manual | `int-biostats-node` UAMI exists | `az` | enable runbook Phase 2a |
| 5 | Azure / manual | `int-nest-node` UAMI exists | `az` | enable runbook Phase 2a |
| 6 | Azure / manual | biostats FIC exists (1) | `az` | enable runbook Phase 2b |
| 7 | Azure / manual | nest-node FICs exist (2) | `az` | enable runbook Phase 2b |
| 8 | Azure / manual | DLDP paths exist for all integrations | `az` | enable runbook Phase 2c |
| 9 | Azure / manual | DLDP leaf ACLs are correct | `az` | enable runbook Phase 2c |
| 10 | Kubernetes | Namespace `${sbenv}` exists | `kubectl` | Create manually |
| 11 | presto-besto-manifesto | `${sbenv}` in `subenvironments.yaml` | file check | enable runbook Phase 3a |
| 12 | presto-besto-manifesto | `identities.yaml` exists and is correct | file check | enable runbook Phase 3b |
| 13 | argocd | All envfrom ConfigMaps present | file check | enable runbook Phase 4b |
| 14 | argocd | `sftp-server.yaml` includes `${sbenv}` | file check | enable runbook Phase 4a |
| 15 | argocd | All `*-appset.yaml` include `${sbenv}` | file check | Merge auto-generated argocd PR |
| 16 | kubernetes-manifests | SFTP Kustomize overlay exists | file check | enable runbook Phase 5 |
| 17 | kubernetes-manifests | No stray sibling references in overlay | file check | enable runbook Phase 5d |
| 18 | ArgoCD (runtime) | All apps Synced + Healthy | `argocd`/UI | Investigate per-app sync errors |

Checks 1–3 should always pass if the sub-env appears in Terraform `locals.tf`.
Checks 11–17 can be run from the local repo clones without any login.
Checks 10 and 18 require Twingate connected to the `${kenv}` network.

---

## Part A: Repo checks (no login required)

These checks only require local checkouts of the repos. Run them first — they
are fast and catch the most common configuration gaps.

### A1. presto-besto-manifesto — `subenvironments.yaml`

```bash
grep -w "${sbenv}" "presto-besto-manifesto/${kenv}/subenvironments.yaml"
```

**Expected:** a line containing `- ${sbenv}`.
If absent, the Dagger pipeline will not generate AppSets for this sub-env.
**Fix:** enable runbook Phase 3a.

---

### A2. presto-besto-manifesto — `identities.yaml`

```bash
cat "presto-besto-manifesto/${kenv}/presto_conf/.internal/${sbenv}/identities.yaml"
```

**Expected:**
```yaml
identityConfig:
  int-biostats-node:
    serviceAccount: ${kenv}-${sbenv}-int-biostats-node
    workloadId: <uuid>
  int-nest-node:
    serviceAccount: ${kenv}-${sbenv}-int-nest-node
    workloadId: <uuid>
  int-nest-node-v1.0.0:
    serviceAccount: ${kenv}-${sbenv}-int-nest-node-v1-0-0
    workloadId: <uuid>   # same UUID as int-nest-node
```

The `workloadId` values are **Client IDs** (not Principal IDs).
Cross-check against the Azure UAMI Client IDs from check B1.
**Fix:** enable runbook Phase 3b.

---

### A3. argocd — envfrom ConfigMaps

Compare the file list in `${sbenv}` against the sibling sub-env:

```bash
diff <(ls "argocd/apps/${kenv}/${sbenv}/") \
     <(ls "argocd/apps/${kenv}/${sibling}/")
```

**Expected:** no output (file sets are identical).
Lines prefixed with `<` are files in `${sbenv}` but not in `${sibling}` (unexpected extras).
Lines prefixed with `>` are files in `${sibling}` but not in `${sbenv}` (missing — will cause AppSet sync failures).
**Fix:** copy missing files from sibling and substitute sub-env-specific values. See enable runbook Phase 4b.

---

### A4. argocd — `sftp-server.yaml`

```bash
grep "subenv: ${sbenv}" "argocd/apps/${kenv}/sftp-server.yaml"
```

**Expected:** `- subenv: ${sbenv}` (one line).
If absent, ArgoCD will not deploy the SFTP server to this sub-env.
**Fix:** enable runbook Phase 4a. Note: kubernetes-manifests overlay (check A6) must be merged first.

---

### A5. argocd — application service AppSets

```bash
grep -rL "subenv: ${sbenv}" argocd/apps/${kenv}/*-appset.yaml
```

**Expected:** no output. Any files listed are AppSets that do **not** deploy to `${sbenv}` — meaning those services are missing from this sub-env.

> If `subenvironments.yaml` (A1) is correct and the Dagger pipeline ran, all
> ~80 AppSets should include `${sbenv}`. If files are listed here, the
> auto-generated argocd PR from the Dagger pipeline may not have been merged
> yet. Check presto-besto-manifesto CI for an open "Enable ${kenv}-${sbenv}
> sub-environment" PR.

To see which AppSets do include `${sbenv}` (for partial-activation triage):
```bash
grep -rl "subenv: ${sbenv}" argocd/apps/${kenv}/*-appset.yaml | wc -l
# Compare against total:
ls argocd/apps/${kenv}/*-appset.yaml | wc -l
```

---

### A6. kubernetes-manifests — SFTP Kustomize overlay

```bash
ls "kubernetes-manifests/kustomize/sftp-server/overlays/${kenv}/${sbenv}/"
```

**Expected:** directory listing including `kustomization.yaml`, `patches/`, `generators/`.
If absent, `sftp-server.yaml` (check A4) cannot be merged safely.
**Fix:** enable runbook Phase 5.

---

### A7. kubernetes-manifests — no stray sibling references

```bash
grep -r "${sibling}" \
  "kubernetes-manifests/kustomize/sftp-server/overlays/${kenv}/${sbenv}" \
  --include="*.yaml" | grep -v generators
```

**Expected:** no output.
Any matches indicate the overlay was not fully substituted during setup.
**Fix:** re-run the perl substitution script from enable runbook Phase 5b on the specific files shown.

---

## Part B: Azure checks (requires `az login`)

These checks require an authenticated Azure CLI session with access to the
`${kenv}` subscription.

### B1. Terraform-provisioned infrastructure

All three resources below should exist as long as the sub-env is listed in
Terraform `locals.tf`. If any are missing, Terraform hasn't been applied yet.

```bash
# Key Vault
az keyvault show \
  --name "vozni-${kenv}-${sbenv}" \
  --query "properties.provisioningState" -o tsv
# Expected: Succeeded

# SFTP managed disk
az disk show \
  --resource-group "vozni-${kenv}-aks-rg" \
  --name "vozni-${kenv}-${sbenv}-sftp" \
  --query "provisioningState" -o tsv
# Expected: Succeeded

# SFTP public IP (also shows the IP value — needed for kubernetes-manifests overlay)
az network public-ip show \
  --resource-group "vozni-${kenv}-aks-rg" \
  --name "vozni-${kenv}-${sbenv}-sftp" \
  --query "{state:provisioningState, ip:ipAddress}" -o json
# Expected: { "state": "Succeeded", "ip": "<address>" }
```

---

### B2. Workload identity UAMIs

```bash
az identity list -g "${sftp_rg}" \
  --query "[?starts_with(name, '${kenv}-${sbenv}-')].{Name:name, ClientID:clientId, PrincipalID:principalId}" \
  --output table
```

**Expected:** at least three entries:
- `${kenv}-${sbenv}-sftp-server` (provisioned by Terraform)
- `${kenv}-${sbenv}-int-biostats-node` (created manually)
- `${kenv}-${sbenv}-int-nest-node` (created manually)

If the manual UAMIs are missing, workload identity will fail for those services.
Save the **Principal IDs** — you'll need them for check B4.
**Fix:** enable runbook Phase 2a.

---

### B3. Federated Identity Credentials (FICs)

```bash
# int-biostats-node — expect exactly one FIC
az identity federated-credential list \
  --identity-name "${kenv}-${sbenv}-int-biostats-node" \
  --resource-group "${sftp_rg}" \
  --query "[].{Name:name, Subject:subject}" --output table
# Expected subject: system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-biostats-node

# int-nest-node — expect exactly two FICs
az identity federated-credential list \
  --identity-name "${kenv}-${sbenv}-int-nest-node" \
  --resource-group "${sftp_rg}" \
  --query "[].{Name:name, Subject:subject}" --output table
# Expected subjects:
#   system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node
#   system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node-v1-0-0
```

A FIC with the wrong subject (e.g. still pointing at `configure`) will cause
the pod's Azure AD token exchange to be rejected.
**Fix:** enable runbook Phase 2b.

---

### B4. Data Lake Directory Paths (DLDP)

#### Step 1: List existing paths

```bash
az storage fs directory list \
  --account-name "${kenv}sftpmirror" \
  --file-system mirror \
  --path "${kenv}/${sbenv}" \
  --auth-mode login \
  --query "[].name" -o tsv
```

**Expected:** one entry per integration configured in the SFTP Kustomize
overlay (`kubernetes-manifests/kustomize/sftp-server/overlays/${kenv}/${sbenv}/patches/int-*.yaml`).
Cross-reference: each `-subdirs` argument in those patch files corresponds to
a leaf path that must exist here.

If paths are missing entirely, `sftp-data-sync` will fail silently when
mirroring files.
**Fix:** enable runbook Phase 2c.

#### Step 2: Verify ACLs on each leaf path

For each leaf directory, run:

```bash
az storage fs access show \
  --account-name "${kenv}sftpmirror" \
  --file-system mirror \
  --path "${kenv}/${sbenv}/<sponsor>/<integration>/<leaf>" \
  --auth-mode login \
  --query acl -o tsv
```

**Expected ACL entries on each leaf:**
| Entry | Permission | Notes |
|---|---|---|
| `user::<permission>` | `rwx` | Owning user |
| `group::<permission>` | `r-x` | Owning group |
| `other::<permission>` | `---` | No access |
| `user:<sftp-server-principal-id>:<permission>` | `rwx` | SFTP server writes files here |
| `user:<service-uami-principal-id>:<permission>` | `rwx` | Service reads/processes files |
| `group:<sftp-read-group-id>:<permission>` | `r-x` | Human read-only access |
| `group:<sftp-read-write-group-id>:<permission>` | `rwx` | Human read-write access |
| `mask::<permission>` | `rwx` | Effective permission mask |

**Warning:** if any `user:` or `group:` entry shows a bare UUID with no
display name in the Azure Portal (Manage ACL view), a Client ID was used
instead of a Principal ID. The ACL entry is non-functional and must be
corrected.

To check the AD group IDs:
```bash
az ad group show -g "sftp-read-${kenv}" --query id -o tsv
az ad group show -g "sftp-read-write-${kenv}" --query id -o tsv
```

To resolve which service UAMI belongs to an ACL entry UUID:
```bash
az identity list -g "${sftp_rg}" \
  --query "[?principalId=='<uuid-from-acl>'].name" -o tsv
```

**Fix:** enable runbook Phase 2c.

---

## Part C: Runtime checks (requires Twingate + cluster access)

These checks verify the live state in Kubernetes and ArgoCD. Twingate must be
connected to the `${kenv}` network before running them.

### C1. Kubernetes namespace

```bash
kubectl get namespace "${sbenv}" --context "${kenv}"
```

**Expected:** `${sbenv}   Active   <age>`

The namespace must pre-exist before ArgoCD can deploy to it — all AppSets
use `CreateNamespace=false`. If the namespace is missing, ArgoCD will fail
to create resources in it.

If missing, create it:
```bash
kubectl create namespace "${sbenv}" --context "${kenv}"
```

---

### C2. ArgoCD application health

List all ArgoCD applications deployed to the `${sbenv}` namespace:

```bash
argocd app list -l "argocd.argoproj.io/namespace=${sbenv}" \
  --server <argocd-server-for-${kenv}>
```

Or in the ArgoCD UI: filter by **Namespace = `${sbenv}`**.

**Expected:** all applications show `Synced` + `Healthy`.

For any application not in this state, inspect it individually:

```bash
argocd app get <app-name> --server <argocd-server-for-${kenv}>
```

Common causes:
| Symptom | Likely cause | Fix |
|---|---|---|
| `ComparisonError` on `sftp-server-${sbenv}` | SFTP Kustomize overlay missing | Check A6 + enable runbook Phase 5 |
| `OutOfSync` on any app | AppSet generator missing `${sbenv}` | Check A5 — merge the auto-generated argocd PR |
| `Missing` resource | Namespace doesn't exist | Check C1 |
| `Degraded` pod | Workload identity failure (UAMI/FIC) | Check B2, B3 |
| `sftp-data-sync` errors | DLDP paths/ACLs wrong | Check B4 |

---

## Interpreting results

### All checks pass
The sub-environment is fully configured. All services are deployed to
`${sbenv}` and the SFTP integration is set up with correct Azure identities
and Data Lake access.

### Repo checks pass but AppSets don't include `${sbenv}` (A5 fails)
The presto-besto-manifesto PR (A1 correct) was merged but the auto-generated
argocd PR hasn't been merged yet. Find and merge the open "Enable
${kenv}-${sbenv} sub-environment" PR on the `argocd` repo.

### A1 fails (`${sbenv}` not in `subenvironments.yaml`)
The sub-environment has Terraform infrastructure (if B1 passes) but has
never been activated in the deployment pipeline. Follow the enable runbook
from Phase 3 onwards.

### B1 fails (Terraform resources missing)
The sub-environment has not been provisioned by Terraform at all. Add it to
`locals.tf` in both `terraform-infra/env/` and `terraform-infra/app/` and
apply.

### B4 fails (DLDP paths missing or ACLs wrong)
`sftp-data-sync` will silently fail when mirroring sponsor files. This is the
most likely gap when all repo checks pass but file ingestion isn't working.
Follow enable runbook Phase 2c, checking which paths are missing by comparing
against the SFTP Kustomize overlay patches.
