# Runbook: Enable a Sub-environment

This runbook was originally written during the activation of `prod-validate`
(2026-02-25). It has been generalised so it can be followed for any
`{env}-{subenv}` combination. Prod-validate specific values are preserved as
inline comments wherever they are useful as examples.

**Repos touched:** `presto-besto-manifesto`, `argocd`, `kubernetes-manifests`
**Azure resources created:** 2 managed identities, 3 federated credentials (per sub-env)

---

## Set variables before starting

All commands below use these shell variables. Set them once at the start of
your session and the rest of the commands can be copied verbatim.

```bash
export kenv="prod"        # environment name  (prod | staging | test | ...)
export sbenv="validate"   # sub-environment   (configure | validate | accept | my | preview)
export sftp_rg="vozni-${kenv}-sftp-storage"
export sub_id="1a6c6f27-521f-4e1a-81e6-d855dd0b464a"  # Azure subscription/tenant ID for ${kenv}
```

---

## Background

### Why does a sub-environment need activating?

Environments are designed around a client validation lifecycle:
`configure` → `preview` → `validate` → `accept` → `my`

- **configure** — internal QA / integration testing
- **preview** — pre-validation demo environment for the client
- **validate** — the environment the client formally validates against (IQ/OQ/PQ testing)
- **accept** — the accepted, locked version the client signs off on
- **my** — the client's live production environment

Each sub-environment gets its own Kubernetes namespace, its own Azure Key
Vault, its own SFTP disk, and its own SFTP load balancer IP — so services
running in one sub-env are completely isolated from the others.

### Why isn't it already active?

Terraform provisions Azure infrastructure for all five sub-environments as soon
as they appear in `locals.tf` (Key Vault, SFTP disk, SFTP public IP). But the
**deployment pipeline** — the presto/ArgoCD stack — is separate and must be
explicitly enabled. This split exists because infrastructure can be provisioned
and "ready" before a client is ready to start their validation lifecycle.

**Prerequisites already satisfied by Terraform:**
- Key Vault `vozni-${kenv}-${sbenv}` exists
- SFTP managed disk `vozni-${kenv}-${sbenv}-sftp` exists in `vozni-${kenv}-aks-rg`
- SFTP public IP `vozni-${kenv}-${sbenv}-sftp` exists in `vozni-${kenv}-aks-rg`
- Kubernetes namespace `${sbenv}` exists in the `${kenv}` AKS cluster

---

## Azure SFTP Storage Architecture

### What we need

Sponsors and integrations need a place to exchange files with Korio's clinical
trial platform — think lab results arriving from a CRO, or inventory updates
going out to a depot. The mechanism is SFTP: sponsors connect to a
Korio-hosted SFTP server and drop files into agreed folder paths.

But SFTP alone only gives you a transient file drop. What Korio actually needs
is for those files to be:
1. **Durably stored** — survive pod restarts and AKS maintenance
2. **Accessible to services** — `int-biostats-node`, `int-nest-node`, and
   similar services need to read and process the files programmatically
3. **Mirrored to Azure** — files written via SFTP need to end up in Azure Data
   Lake Storage Gen2 (ADLS2) so that Azure-native tooling (Databricks, Synapse,
   etc.) can also access them, and so they're backed by Azure's storage
   redundancy rather than an AKS-local disk

Azure Data Lake Storage Gen2 is Azure Blob Storage with a hierarchical
namespace layered on top — that's what enables POSIX-style ACLs on individual
directories (which plain Blob Storage doesn't support). The relevant storage
account is `${kenv}sftpmirror`, the container is `mirror`. Every integration
gets a directory path like `${kenv}/${sbenv}/<sponsor>/<integration>/...`.

### Why do we need UAMIs, FICs, and DLDP?

The problem is: how do Kubernetes pods authenticate to Azure Storage without
embedding passwords or keys?

**UAMIs (User Assigned Managed Identities)** solve the identity problem.
Instead of giving the pod a password, you create a named Azure identity (a
UAMI) and grant that identity the necessary Azure RBAC roles. The pod then
requests access tokens on behalf of that identity. No secrets in the cluster.

**FICs (Federated Identity Credentials)** solve the trust problem. Kubernetes
has its own identity system (ServiceAccounts), and Azure has its own (Azure
AD). A FIC is the bridge: it tells Azure AD "trust a token issued by *this*
Kubernetes cluster (`issuer`), for *this* ServiceAccount (`subject`), as if it
were this UAMI." When a pod presents its ServiceAccount token to Azure AD,
Azure exchanges it for an Azure access token — this is the Azure Workload
Identity flow.

**DLDP (Data Lake Directory Paths)** solve the access control problem. Azure
Data Lake Gen2 uses POSIX-style ACLs on directories. Before a service can
write a file to `${kenv}/${sbenv}/<sponsor>/<integration>/...`, the directory
tree must already exist in the Data Lake with ACL entries that grant the right
identities the right permissions. `korioctl azure dldp create` creates the
directory and sets the ACLs in one step. If this step is skipped,
`sftp-data-sync` will fail silently when it tries to mirror files.

**How it all fits together at runtime:**

```
Sponsor uploads file via SFTP
        │
        ▼
sftp-server pod (authenticates to Azure Key Vault as ${kenv}-${sbenv}-sftp-server UAMI)
        │  writes file to Azure Disk (mounted as PV)
        │
sftp-data-sync sidecar (runs alongside sftp-server)
        │  detects new file, authenticates to ${kenv}sftpmirror as ${kenv}-${sbenv}-sftp-server UAMI
        │  copies file to ${kenv}sftpmirror/mirror/${kenv}/${sbenv}/<sponsor>/<integration>/...
        │  publishes file event to RabbitMQ
        ▼
int-biostats-node / int-nest-node (authenticates to ${kenv}sftpmirror as its own UAMI)
        │  reads file from Data Lake for processing
        ▼
processed output written back to Data Lake or MongoDB
```

Each arrow that crosses a Kubernetes-to-Azure boundary requires a UAMI + FIC
pair. Each directory in the Data Lake that a pod writes to requires a DLDP
entry with that pod's UAMI **Principal ID** in the leaf ACL.

---

## Phase 1: Azure — Look up infrastructure values

These values are not derivable from naming conventions — they must be looked up
from Azure before doing anything else.

```bash
# Get the static IP provisioned by Terraform for the SFTP load balancer.
# This IP is fixed to the Azure resource; it will not change even if the pod restarts.
# We need it to populate loadbalancerIp.yaml in the Kustomize overlay (Phase 5).
az network public-ip show \
  --resource-group "vozni-${kenv}-aks-rg" \
  --name "vozni-${kenv}-${sbenv}-sftp" \
  --query ipAddress -o tsv
# prod-validate: → 51.8.75.86

# Get the Client ID of the sftp-server managed identity.
# This UAMI was provisioned by Terraform and is what the sftp-server pod
# authenticates to Azure as (e.g. to read Key Vault secrets).
# We need it for the Kustomize serviceAccount.yaml patch (Phase 5).
# Note: this is the CLIENT ID, not the Principal ID. These are different UUIDs —
# Client ID is used for application authentication (e.g. Workload Identity annotations);
# Principal ID is used for ACL assignments (e.g. Data Lake directory ACLs).
az identity show \
  --resource-group "${sftp_rg}" \
  --name "${kenv}-${sbenv}-sftp-server" \
  --query clientId -o tsv
# prod-validate: → 8fc203ee-8f0c-4f28-bc22-0bef436be3e8

# Get the OIDC issuer URL for the AKS cluster.
# This URL identifies the cluster's token issuer to Azure AD — it is how Azure
# verifies that a Kubernetes service account token was genuinely issued by the
# right cluster. It is used when creating Federated Identity Credentials (Phase 2).
#
# Preferred approach: derive it directly from the AKS cluster.
export oidc_cluster_uuid="$(basename "$(az aks show \
  --resource-group "vozni-${kenv}-rg" \
  --name "vozni-${kenv}-aks" \
  --query oidcIssuerProfile.issuerUrl \
  -otsv 2>/dev/null)")"
export oidc_issuer="https://eastus.oic.prod-aks.azure.com/${sub_id}/${oidc_cluster_uuid}/"
echo "$oidc_issuer"
# prod-validate: → https://eastus.oic.prod-aks.azure.com/1a6c6f27-521f-4e1a-81e6-d855dd0b464a/d94c45d4-52b9-4d9c-8c77-438345d65b13/
#
# Alternative (read from an existing federated credential on a sibling sub-env):
az identity federated-credential list \
  --identity-name "${kenv}-configure-int-biostats-node" \
  --resource-group "${sftp_rg}" \
  --query "[0].issuer" -o tsv
# → same value; all sub-envs share the same AKS cluster
```

---

## Phase 2: Azure — Create workload identities

### Why are workload identities needed?

Two services — `int-biostats-node` and `int-nest-node` — authenticate to Azure
(e.g. to read from Azure Storage, Key Vault, or Data Lake) using **Azure
Workload Identity**. This mechanism replaces the older pod-level secrets
approach: instead of storing a password or key in the cluster, the pod
presents a Kubernetes ServiceAccount token, and Azure AD exchanges that token
for an Azure access token if a matching Federated Identity Credential (FIC)
exists.

The chain is:
1. **UAMI** — The Azure identity that represents the service. Has its own
   Client ID and Principal ID. Azure RBAC roles are assigned to this identity.
2. **Kubernetes ServiceAccount** — The in-cluster identity the pod runs as
   (created automatically by the presto pipeline from `identities.yaml`).
3. **FIC** — The trust binding between the two: "this Azure UAMI trusts tokens
   issued by this cluster (`issuer`), for this Kubernetes ServiceAccount
   (`subject`)."

Each sub-environment requires its own UAMI and FIC(s). The UAMIs for
`int-biostats-node` and `int-nest-node` are **not** managed by Terraform in
this repo — they must be created manually.

### Why does int-nest-node need two FICs?

`int-nest-node` is versioned: the service runs multiple versions simultaneously
on different URL routes, each needing its own Kubernetes ServiceAccount name.
Two FICs are required — one for the current service account
(`${kenv}-${sbenv}-int-nest-node`) and one for the versioned account
(`${kenv}-${sbenv}-int-nest-node-v1-0-0`). Both FICs bind to the same UAMI,
so the same managed identity is reused.

---

### Step 2a: Create the UAMIs

Both approaches accomplish the same thing. Use whichever you prefer —
`korioctl` is preferred for consistency with other tooling.

**Using `korioctl` (preferred):**
```bash
korioctl azure uami create -g "${sftp_rg}" "${kenv}-${sbenv}-int-biostats-node"
# prod-validate: → a2afdb8a-4c7a-44b3-b405-c4b1a18b05c1

korioctl azure uami create -g "${sftp_rg}" "${kenv}-${sbenv}-int-nest-node"
# prod-validate: → 70d64cba-49f6-411b-9307-a67ff86bdd55
```

**Using raw `az` CLI:**
```bash
az identity create \
  --name "${kenv}-${sbenv}-int-biostats-node" \
  --resource-group "${sftp_rg}" \
  --location eastus \
  --query clientId -o tsv
# prod-validate: → a2afdb8a-4c7a-44b3-b405-c4b1a18b05c1

az identity create \
  --name "${kenv}-${sbenv}-int-nest-node" \
  --resource-group "${sftp_rg}" \
  --location eastus \
  --query clientId -o tsv
# prod-validate: → 70d64cba-49f6-411b-9307-a67ff86bdd55
```

**To verify UAMIs exist (both Client ID and Principal ID):**
```bash
az identity list -g "${sftp_rg}" \
  --query "[?type == 'Microsoft.ManagedIdentity/userAssignedIdentities'].{Name:name, ClientID:clientId, PrincipalID:principalId}" \
  --output table | grep "${kenv}-${sbenv}-int-"
# Note the Principal IDs — you will need them in Phase 2c (DLDP ACLs).
# Principal ID ≠ Client ID. They are different UUIDs for the same identity.
```

---

### Step 2b: Create the Federated Identity Credentials (FICs)

**Using `korioctl` (preferred):**
```bash
# The subject format is: system:serviceaccount:<namespace>:<service-account-name>
# Namespace matches the sub-environment name.
# Service account name matches the UAMI name.

korioctl azure fic create \
  -g "${sftp_rg}" \
  --identity "${kenv}-${sbenv}-int-biostats-node" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-biostats-node" \
  "${kenv}-${sbenv}-int-biostats-node"

korioctl azure fic create \
  -g "${sftp_rg}" \
  --identity "${kenv}-${sbenv}-int-nest-node" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node" \
  "${kenv}-${sbenv}-int-nest-node"

# Second FIC for the versioned service account (v1-0-0 suffix)
korioctl azure fic create \
  -g "${sftp_rg}" \
  --identity "${kenv}-${sbenv}-int-nest-node" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node-v1-0-0" \
  "${kenv}-${sbenv}-int-nest-node-v1-0-0"
```

**Using raw `az` CLI:**
```bash
az identity federated-credential create \
  --name "${kenv}-${sbenv}-int-biostats-node" \
  --identity-name "${kenv}-${sbenv}-int-biostats-node" \
  --resource-group "${sftp_rg}" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-biostats-node" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "${kenv}-${sbenv}-int-nest-node" \
  --identity-name "${kenv}-${sbenv}-int-nest-node" \
  --resource-group "${sftp_rg}" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "${kenv}-${sbenv}-int-nest-node-v1-0-0" \
  --identity-name "${kenv}-${sbenv}-int-nest-node" \
  --resource-group "${sftp_rg}" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node-v1-0-0" \
  --audiences "api://AzureADTokenExchange"
```

---

## Phase 2c: Azure — Create Data Lake Directory Paths (DLDP)

> **prod-validate:** Completed 2026-02-26. This step was skipped in the
> original execution and completed separately. See details below.

### Why are DLDP entries needed?

The `sftp-data-sync` sidecar container that runs alongside the SFTP server
syncs file events to Azure Data Lake Storage (`${kenv}sftpmirror`). For this
sync to work, the Data Lake directory tree must pre-exist with the correct
POSIX ACLs — otherwise the sidecar gets a permission error and file events
are lost.

The ACLs control who can read/write each folder. There are four principals
per sub-environment:
- **sftp-server UAMI** — the SFTP pod's own identity; needs `rwx` on leaf dirs
- **service UAMI** — the integration-specific service identity; needs `rwx` to
  read/process files (which UAMI to use per integration is determined by
  checking the equivalent path on a sibling sub-env — see below)
- **sftp-read group** (`sftp-read-${kenv}`) — Entra AD group for humans with
  read-only access; needs `r-x`
- **sftp-read-write group** (`sftp-read-write-${kenv}`) — Entra AD group for
  humans with read-write access; needs `rwx`

**Critical:** The `-l` (leaf ACL) flags require **Principal IDs**, not Client
IDs. These are different UUIDs for the same identity. Using a Client ID here
silently sets the ACL with an unresolvable GUID — the Portal will show a bare
UUID instead of the identity name, indicating the wrong ID was used.

### Look up Principal IDs

```bash
# All UAMIs for this sub-environment (sftp-server + per-integration service UAMIs)
az identity list --resource-group "${sftp_rg}" \
  --query "[?starts_with(name, '${kenv}-${sbenv}-')].{Name:name, PrincipalID:principalId}" \
  --output table

# Entra AD group IDs (per-environment, not per-subenv)
export sftp_ro_id="$(az ad group show -g "sftp-read-${kenv}" --query id -o tsv)"
export sftp_rw_id="$(az ad group show -g "sftp-read-write-${kenv}" --query id -o tsv)"
```

**prod-validate Principal IDs (for reference):**

| Identity | Principal ID |
|---|---|
| `prod-validate-sftp-server` | `5b86796b-9514-4f93-890c-863f2225b03a` |
| `prod-validate-int-biostats-node` | `cfa35105-3f9d-4a55-afb7-e17d1fba1dae` |
| `prod-validate-int-nest-node` | `6691e133-3c73-4612-ab8f-5d18e41de006` |
| `prod-validate-moderna-icsf` | `179157d3-6cbe-4086-9c67-c2d4e2772be0` |
| `prod-validate-moderna-maestro` | `f8fa6185-959e-4e4a-ad7b-c126979d2aab` |
| `prod-validate-tagworks-pci` | `3a64a6dd-c5cf-472a-91a3-4c7e7c10ada5` |
| `sftp-read-prod` (Entra group) | `3b1325b9-4525-4966-9493-21f106756234` |
| `sftp-read-write-prod` (Entra group) | `963a6dd7-ccdf-4f86-8ae7-750bb6300a54` |

### Determine which paths to create

The paths to create come from the `-subdirs` argument in each `int-*.yaml`
patch file under:

```
kubernetes-manifests/kustomize/sftp-server/overlays/${kenv}/${sbenv}/patches/
```

Each `int-*.yaml` patch declares one or more leaf directories that
`sftp-data-sync` watches. Each of those directories needs a DLDP entry.

Before running `dldp create`, check whether any paths already exist (they
may have been created by a previous process or copied from another sub-env):

```bash
az storage fs directory list \
  --account-name "${kenv}sftpmirror" \
  --file-system mirror \
  --path "${kenv}/${sbenv}" \
  --auth-mode login \
  --query "[].name" -o tsv
```

For any paths that exist, verify the ACLs are correct by checking a sibling
sub-env's equivalent path and comparing:

```bash
# Check ACL on an existing path in a sibling sub-env (e.g. accept)
az storage fs access show \
  --account-name "${kenv}sftpmirror" \
  --file-system mirror \
  --path "${kenv}/accept/<sponsor>/<integration>/<leaf>" \
  --auth-mode login --query acl -o tsv

# Check ACL on the corresponding validate path
az storage fs access show \
  --account-name "${kenv}sftpmirror" \
  --file-system mirror \
  --path "${kenv}/${sbenv}/<sponsor>/<integration>/<leaf>" \
  --auth-mode login --query acl -o tsv
```

The service UAMI to use for each integration can be determined by inspecting
the sibling sub-env's leaf ACL: look for the `user:<uuid>:rwx` entries that
are not the sftp-server UAMI, then resolve the UUID:

```bash
az identity list -g "${sftp_rg}" \
  --query "[?principalId=='<uuid-from-acl>'].name" -o tsv
```

**prod-validate: what was pre-existing vs. newly created:**

| Integration | Leaf path(s) | Status |
|---|---|---|
| biostats | `prod/validate/moderna/biostats/moderna/mRNA-2808-P101` | Created 2026-02-26 |
| cluepoints | `prod/validate/moderna/cluepoints/Moderna/mRNA-2808-P101/CluePoints` | Created 2026-02-26 |
| icsf | 12 leaves under `prod/validate/moderna/icsf/Moderna/{study}/{Inventory,Patient,Site}` | Pre-existing |
| maestro | 8 dirs under `prod/validate/moderna/maestro/{study}_{type}/Test` | Pre-existing |
| pci | `prod/validate/tagworks/pci/to_Korio` and `.../TGW101-101` | Pre-existing |
| fisher | `prod/validate/moderna/fisher/to_Korio` | Pre-existing |

### Create a directory path

Run this once per leaf directory. Substitute the correct service UAMI
Principal ID for the integration (resolved above).

```bash
korioctl azure dldp create \
  -a "${kenv}sftpmirror" \
  -f mirror \
  -p user::rwx -p group::r-x -p "other::--x" \
  -l user::rwx -l group::r-x -l "other::---" \
  -l "user:<sftp-server-principal-id>:rwx" \
  -l "user:<service-uami-principal-id>:rwx" \
  -l "group:${sftp_ro_id}:r-x" \
  -l "group:${sftp_rw_id}:rwx" \
  -l mask::rwx \
  "${kenv}/${sbenv}/<sponsor>/<integration>/<leaf>"
```

**prod-validate examples (biostats and cluepoints, the two that were missing):**

```bash
# biostats — service UAMI: prod-validate-int-biostats-node
korioctl azure dldp create \
  -a prodsftpmirror -f mirror \
  -p user::rwx -p group::r-x -p "other::--x" \
  -l user::rwx -l group::r-x -l "other::---" \
  -l "user:5b86796b-9514-4f93-890c-863f2225b03a:rwx" \
  -l "user:cfa35105-3f9d-4a55-afb7-e17d1fba1dae:rwx" \
  -l "group:3b1325b9-4525-4966-9493-21f106756234:r-x" \
  -l "group:963a6dd7-ccdf-4f86-8ae7-750bb6300a54:rwx" \
  -l mask::rwx \
  "prod/validate/moderna/biostats/moderna/mRNA-2808-P101"

# cluepoints — service UAMI: prod-validate-int-nest-node
# (int-nest-node processes cluepoints output; confirmed by inspecting accept ACL)
korioctl azure dldp create \
  -a prodsftpmirror -f mirror \
  -p user::rwx -p group::r-x -p "other::--x" \
  -l user::rwx -l group::r-x -l "other::---" \
  -l "user:5b86796b-9514-4f93-890c-863f2225b03a:rwx" \
  -l "user:6691e133-3c73-4612-ab8f-5d18e41de006:rwx" \
  -l "group:3b1325b9-4525-4966-9493-21f106756234:r-x" \
  -l "group:963a6dd7-ccdf-4f86-8ae7-750bb6300a54:rwx" \
  -l mask::rwx \
  "prod/validate/moderna/cluepoints/Moderna/mRNA-2808-P101/CluePoints"
```

**Notes:**
- `-p` sets the ACL on intermediate (parent) directories as the tree is created
- `-l` sets the ACL on the leaf directory
- `other::--x` on parents (traverse only) vs `other::---` on leaves (no access)
- Use `-l user::rwx` (not `r-x`) on the leaf — the owning user needs write access

### Verify correct ACLs were applied

```bash
az storage fs access show \
  --account-name "${kenv}sftpmirror" \
  --file-system mirror \
  --path "${kenv}/${sbenv}/<sponsor>/<integration>/<leaf>" \
  --auth-mode login \
  --query acl -o tsv
# Each principal should resolve by name in the Portal (Manage ACL view).
# If you see only a raw GUID with no name, a Client ID was used instead of a Principal ID.
```

---

## Phase 3: Repo — `presto-besto-manifesto`

### Why does presto-besto-manifesto need changes?

`subenvironments.yaml` is the authoritative list of sub-environments the presto
pipeline actively manages. When the Dagger CI pipeline runs on a PR to this
repo, it calls `korioctl` to regenerate all ~80 service ApplicationSets in the
`argocd` repo — one ApplicationSet per service per sub-environment in this
list. Adding `${sbenv}` here is what causes all services to get `${sbenv}`
instances.

`identities.yaml` is required for every sub-environment listed in
`subenvironments.yaml`. It tells the presto pipeline which Azure Managed
Identity Client IDs to use when generating the Kubernetes ServiceAccount
annotations for Workload Identity-enabled services. The `workloadId` field is
the **Client ID** (not Principal ID — this is the opposite of the DLDP step).

```bash
cd presto-besto-manifesto
git checkout -b {author}/enable-${kenv}-${sbenv}
```

### 3a. Edit `${kenv}/subenvironments.yaml`

Add `${sbenv}` in the correct position in the lifecycle order:

```yaml
subenvironments:
  - configure
  - validate   # ← example: add new sub-env here
  - accept
  - my
```

### 3b. Create `${kenv}/presto_conf/.internal/${sbenv}/identities.yaml` (new file)

```yaml
identityConfig:
  int-biostats-node:
    serviceAccount: ${kenv}-${sbenv}-int-biostats-node
    workloadId: <client-id-from-phase-2a>   # prod-validate: a2afdb8a-4c7a-44b3-b405-c4b1a18b05c1
  int-nest-node:
    serviceAccount: ${kenv}-${sbenv}-int-nest-node
    workloadId: <client-id-from-phase-2a>   # prod-validate: 70d64cba-49f6-411b-9307-a67ff86bdd55
  int-nest-node-v1.0.0:
    serviceAccount: ${kenv}-${sbenv}-int-nest-node-v1-0-0
    workloadId: <client-id-from-phase-2a>   # prod-validate: 70d64cba-... (same as int-nest-node)
```

Note: `int-nest-node` and `int-nest-node-v1.0.0` share the same `workloadId`
— both service accounts bind to the same UAMI. The versioned service account
is for the pinned v1.0.0 deployment that runs alongside the current version.

```bash
git add "${kenv}/subenvironments.yaml" "${kenv}/presto_conf/.internal/${sbenv}/"
git commit -m "feature: enable ${kenv}-${sbenv} sub-environment"
git push -u origin {author}/enable-${kenv}-${sbenv}
# prod-validate: PR #152
```

---

## Phase 4: Repo — `argocd`

### Why does the argocd repo need changes?

The `argocd` repo holds two kinds of files for each sub-environment:

1. **`apps/${kenv}/sftp-server.yaml`** — A manually maintained ApplicationSet
   that deploys the SFTP server. It is not generated by korioctl. Adding
   `${sbenv}` here tells ArgoCD to create and sync
   `sftp-server-${sbenv}` against the Kustomize overlay created in Phase 5.

2. **`apps/${kenv}/${sbenv}/*-envfrom.yaml`** — ConfigMaps that inject
   environment-specific variables into service pods. These are referenced by
   the ApplicationSets korioctl generates. Every ConfigMap file that exists for
   a sibling sub-env must also exist for `${sbenv}` — a missing file will
   cause the corresponding ApplicationSet to fail to sync.

```bash
cd argocd
git checkout -b {author}/enable-${kenv}-${sbenv}
```

### 4a. Edit `apps/${kenv}/sftp-server.yaml`

Add `${sbenv}` to the ApplicationSet generator list:

```yaml
  generators:
    - list:
        elements:
          - subenv: configure
          - subenv: validate   # ← add new sub-env here
          - subenv: accept
          - subenv: my
```

> **Dependency warning:** This change must not be merged until the
> kubernetes-manifests PR (Phase 5) is merged first. ArgoCD uses
> `CreateNamespace=false` and will immediately attempt to sync
> `sftp-server-${sbenv}` against the Kustomize overlay path on
> `kubernetes-manifests@main`. If that overlay doesn't exist yet, the
> Application will enter a persistent `ComparisonError` state. Convert this PR
> to draft until the dependency is clear.

### 4b. Ensure all envfrom ConfigMaps are present

Compare file counts against a sibling sub-env:

```bash
diff <(ls "apps/${kenv}/${sbenv}/") <(ls "apps/${kenv}/configure/")
```

Any missing `*-envfrom.yaml` files must be created. For each missing file,
copy the equivalent from the sibling sub-env and substitute the sub-env name
in the values (namespace, `MONGO_NAME_PREFIX`, `MONGO_USERNAME`,
`APP_BASE_URL`, `INTERNAL_BASE_URL`, etc.).

**prod-validate: two files were missing vs. configure:**

`apps/prod/validate/int-pci-node-main-envfrom.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: int-pci-node-main-envfrom
data:
  APP_BASE_URL: https://validate-prod.korioclinical.com
  INTERNAL_BASE_URL: http://internal-api-gateway-nginx.validate.svc.cluster.local
  MONGO_NAME_PREFIX: prod-validate
  MONGO_USERNAME: validate
```

`apps/prod/validate/automated-resupply-node-v0.9.0-envfrom.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: automated-resupply-node-v0.9.0-envfrom
data:
  APP_BASE_URL: https://validate.korioclinical.com
  INTERNAL_BASE_URL: http://internal-api-gateway-nginx.validate.svc.cluster.local
  MONGO_HOST: vozni-prod-validate-pl-0.v1wct.mongodb.net
  MONGO_NAME_PREFIX: prod-validate
  MONGO_USERNAME: validate
```

```bash
git add "apps/${kenv}/sftp-server.yaml" "apps/${kenv}/${sbenv}/"
git commit -m "feature: enable ${kenv}-${sbenv} sub-environment"
git push -u origin {author}/enable-${kenv}-${sbenv}
# prod-validate: PR #865
# ⚠️ Convert to draft — must not merge before kubernetes-manifests PR
```

---

## Phase 5: Repo — `kubernetes-manifests`

### Why does kubernetes-manifests need a new overlay?

The SFTP deployment is not managed by the Helm chart — it uses Kustomize
exclusively. One overlay directory exists per `{env}/{subenv}` combination,
containing all the per-environment configuration: the load balancer IP, the
managed disk name, the namespace, the service account annotations, and init
container/sidecar patches for each integration. There is no generator for
these; each overlay is maintained manually. The overlay must exist on `main`
before the ArgoCD ApplicationSet in Phase 4 can sync successfully.

```bash
cd kubernetes-manifests
git checkout -b {author}/enable-${kenv}-${sbenv}
```

### 5a. Copy a sibling overlay as the starting point

```bash
cp -r "kustomize/sftp-server/overlays/${kenv}/configure" \
      "kustomize/sftp-server/overlays/${kenv}/${sbenv}"
```

The `generators/` subdirectory (etc-passwd, etc-group, etc-gshadow,
ssh-public-keys/) is identical across sub-envs and requires no changes —
SFTP users and their SSH keys are environment-wide, not sub-environment-specific.

### 5b. Apply substitutions to all non-generator files

Look up the values to substitute from Phase 1, then replace all
`configure`-specific values with `${sbenv}` equivalents. We use `perl -pi -e`
rather than `sed -i ''` because BSD sed on macOS does not reliably handle
in-place editing with multiple `-e` expressions.

```bash
# Set these from Phase 1 lookups:
export new_ip="<sftp-lb-ip>"                  # prod-validate: 51.8.75.86
export old_ip="<sibling-subenv-sftp-lb-ip>"   # prod-configure: 51.8.74.232
export new_uami_client_id="<sftp-server-client-id>"   # prod-validate: 8fc203ee-...
export old_uami_client_id="<sibling-subenv-sftp-server-client-id>"  # prod-configure: e90b1212-...
export sibling="configure"   # the sub-env you copied from

find "kustomize/sftp-server/overlays/${kenv}/${sbenv}" \
  -type f -name "*.yaml" ! -path "*/generators/*" | \
while read -r f; do
  perl -pi -e "
    s/value: ${sibling}/value: ${sbenv}/g;
    s|subPath: ${kenv}/${sibling}|subPath: ${kenv}/${sbenv}|g;
    s|/mnt/sftp-data/${kenv}/${sibling}|/mnt/sftp-data/${kenv}/${sbenv}|g;
    s/namespace: ${sibling}/namespace: ${sbenv}/g;
    s/value: sftp-${sibling}/value: sftp-${sbenv}/g;
    s/vozni-${kenv}-${sibling}-sftp/vozni-${kenv}-${sbenv}-sftp/g;
    s/${old_ip}/${new_ip}/g;
    s/${old_uami_client_id}/${new_uami_client_id}/g;
  " "\$f"
done
```

**What each substitution does:**

| Pattern replaced | Replaced with | Files affected | Why |
|---|---|---|---|
| `value: {sibling}` | `value: ${sbenv}` | All patch files | `KORIO_SUBENVIRONMENT` env var |
| `subPath: {kenv}/{sibling}` | `subPath: {kenv}/${sbenv}` | `humanHomedirs.yaml`, `int-*.yaml` | Azure Disk subPath mount path |
| `/mnt/sftp-data/{kenv}/{sibling}` | `/mnt/sftp-data/{kenv}/${sbenv}` | `int-*.yaml` | `sftp-data-sync` watch path |
| `namespace: {sibling}` | `namespace: ${sbenv}` | `kustomization.yaml` | Target namespace |
| `value: sftp-{sibling}` | `value: sftp-${sbenv}` | `persistentVolume.yaml` | PV resource name (must be unique) |
| `vozni-{kenv}-{sibling}-sftp` | `vozni-{kenv}-${sbenv}-sftp` | `persistentVolume.yaml` | Azure Disk resource handle |
| `{old_ip}` | `{new_ip}` | `loadbalancerIp.yaml` | Static IP from Phase 1 |
| `{old_uami_client_id}` | `{new_uami_client_id}` | `serviceAccount.yaml` | sftp-server UAMI Client ID from Phase 1 |

### 5c. Fix the comment in `serviceAccount.yaml`

Update the comment referencing the `az` command to use the new sub-env name:

```yaml
# az identity show --resource-group vozni-${kenv}-sftp-storage \
#   --name ${kenv}-${sbenv}-sftp-server --query 'clientId' -otsv
```

### 5d. Verify no stray sibling references remain

```bash
grep -r "${sibling}" "kustomize/sftp-server/overlays/${kenv}/${sbenv}" \
  --include="*.yaml" | grep -v generators
# Should produce no output
```

```bash
git add "kustomize/sftp-server/overlays/${kenv}/${sbenv}/"
git commit -m "${kenv}/${sbenv} - initial SFTP Kustomize overlay"
git push -u origin {author}/enable-${kenv}-${sbenv}
# prod-validate: PR #222
```

---

## Phase 6: Merge order

### Why does order matter?

ArgoCD watches `argocd` repo changes and acts on them immediately. The
`sftp-server.yaml` ApplicationSet change (Phase 4) tells ArgoCD to create an
Application that points at a Kustomize overlay path on
`kubernetes-manifests@main`. If that path doesn't exist yet, ArgoCD enters a
persistent `ComparisonError` state. The korioctl-generated service
ApplicationSets (from Phase 3) have the same dependency on the envfrom
ConfigMaps in the `argocd` repo.

### Step 1 — `kubernetes-manifests` PR ✅ (prod-validate: PR #222)

The SFTP Kustomize overlay must exist on `main` before ArgoCD attempts to sync
`sftp-server-${sbenv}`. Merge this first.

### Step 2 — `argocd` PR ✅ (prod-validate: PR #865)

Undraft the PR (it was put in draft to prevent premature merge), then merge.
This:
- Brings any missing envfrom ConfigMaps into the `${sbenv}` namespace
- Adds `sftp-server-${sbenv}` to the SFTP ApplicationSet, triggering ArgoCD
  to sync

### Step 3 — `presto-besto-manifesto` PR ✅ (prod-validate: PR #152)

Adding `${sbenv}` to `subenvironments.yaml` triggers the Dagger pipeline,
which calls `korioctl` to regenerate all ~80 service ApplicationSets to include
`${sbenv}`. This auto-generates a fourth PR on `argocd`.

### Step 4 — auto-generated `argocd` PR ✅ (prod-validate: PR #869)

The Dagger pipeline auto-generates `[Dagger CiCd] Enable ${kenv}-${sbenv}
sub-environment`. Review and merge to complete deployment of all application
microservices to the `${sbenv}` namespace.

---

## Summary of all changes

| System | Resource | Action |
|---|---|---|
| Azure | `${kenv}-${sbenv}-int-biostats-node` (managed identity) | Create |
| Azure | `${kenv}-${sbenv}-int-nest-node` (managed identity) | Create |
| Azure | Federated credential on int-biostats-node | Create |
| Azure | Federated credential on int-nest-node | Create |
| Azure | Federated credential on int-nest-node (v1-0-0) | Create |
| Azure | Data Lake leaf paths in `${kenv}sftpmirror` for each integration | Create (check sibling first — may be pre-existing) |
| `presto-besto-manifesto` | `${kenv}/subenvironments.yaml` | Modify |
| `presto-besto-manifesto` | `${kenv}/presto_conf/.internal/${sbenv}/identities.yaml` | Create |
| `argocd` | `apps/${kenv}/sftp-server.yaml` | Modify |
| `argocd` | `apps/${kenv}/${sbenv}/` — any missing envfrom ConfigMaps | Create |
| `argocd` | All ~80 service ApplicationSets (auto-generated) | Auto-generated by Dagger |
| `kubernetes-manifests` | `kustomize/sftp-server/overlays/${kenv}/${sbenv}/` | Create |
