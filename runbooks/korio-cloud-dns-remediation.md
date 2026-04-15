# Runbook: korio.cloud DNS Remediation

## Background

The `korio.cloud` private DNS zones that underpin internal service-to-service
communications were provisioned manually and are not represented in any
Terraform workspace. They live in the `devops-test` resource group rather than
the per-environment `vozni-{env}-rg` groups. This is a compliance gap.

Additionally, orphaned public DNS zones for `{env}.korio.cloud` exist in each
environment's resource group. These zones are not delegated from Cloudflare and
are unreachable from the public internet — they predate the migration of
`korio.cloud` to Cloudflare and serve no active purpose.

See [infrastructure.md — korio.cloud DNS Architecture](../infrastructure.md#koriocloud-dns-architecture)
for the full architectural context.

---

## Scope and sequencing

Three remediation steps are planned, in order:

| Step | Action | Risk | Status |
|------|--------|------|--------|
| 1 | Import private DNS zones into Terraform | None — state-only, no infra changes | TODO |
| 2 | Remove orphaned public DNS zones via Terraform | Low — zones are unreachable already | TODO |
| 3 | Relocate private zones from `devops-test` to `vozni-{env}-rg` | Needs Twingate impact assessment | Deferred |

Complete steps 1 and 2 first. Step 3 must not be attempted until the Twingate
dependency is understood and tested — a misconfigured relocation would break
developer access and internal routing for the entire environment.

---

## Step 1 — Import private DNS zones into Terraform

### What exists

Private DNS zones, one per environment, all in the `devops-test` resource group:

| Zone | Resource group |
|------|---------------|
| `sandbox.korio.cloud` | `devops-test` |
| `dev.korio.cloud` | `devops-test` |
| `test.korio.cloud` | `devops-test` |
| `platform.korio.cloud` | `devops-test` |
| `staging.korio.cloud` | `devops-test` |
| `prod.korio.cloud` | `devops-test` |

Each zone has:
- A VNet link to the corresponding AKS VNet (`registrationEnabled: true`)
- A `@` A record pointing to the internal NGINX LB IP
- A `*` A record (TTL 1) pointing to the internal NGINX LB IP

### Where to add the Terraform resources

The private DNS zones belong in `terraform-infra/env/` — the workspace that
manages per-environment Azure infrastructure (AKS, VNets, Key Vault). Suggested
filename: `env/private_dns.tf`.

### Terraform resource types needed

```hcl
# The private DNS zone itself
resource "azurerm_private_dns_zone" "korio_cloud" { ... }

# VNet link to the AKS VNet
resource "azurerm_private_dns_zone_virtual_network_link" "korio_cloud_aks" { ... }

# Wildcard A record routing all subdomains to the internal LB
resource "azurerm_private_dns_a_record" "wildcard" { ... }

# Apex A record (if present)
resource "azurerm_private_dns_a_record" "apex" { ... }
```

### Import procedure

For each environment, run the following from the `terraform-infra/env/`
workspace:

```bash
# Confirm the resource IDs before importing
SUBSCRIPTION="<env-subscription-id>"
RG="devops-test"
ENV="<env>"

# Get zone resource ID
az network private-dns zone show \
  --name "${ENV}.korio.cloud" \
  --resource-group "$RG" \
  --subscription "$SUBSCRIPTION" \
  --query id -o tsv

# Get VNet link resource ID
az network private-dns link vnet list \
  --zone-name "${ENV}.korio.cloud" \
  --resource-group "$RG" \
  --subscription "$SUBSCRIPTION" \
  --query '[].id' -o tsv

# Import
terraform import azurerm_private_dns_zone.korio_cloud \
  "/subscriptions/<id>/resourceGroups/devops-test/providers/Microsoft.Network/privateDnsZones/${ENV}.korio.cloud"

terraform import azurerm_private_dns_zone_virtual_network_link.korio_cloud_aks \
  "/subscriptions/<id>/resourceGroups/devops-test/providers/Microsoft.Network/privateDnsZones/${ENV}.korio.cloud/virtualNetworkLinks/<link-name>"
```

After importing, run `terraform plan` and confirm the plan shows **no changes**
before committing the state.

> **Important:** Write the Terraform resource definitions to match the existing
> infrastructure exactly before importing. Import will fail if the resource block
> does not exist in config. After a successful import, `terraform plan` must show
> no diff — if it proposes changes, reconcile the config first.

---

## Step 2 — Remove orphaned public DNS zones

### What exists

Public DNS zones for `{env}.korio.cloud` exist in each per-environment resource
group (e.g. `vozni-dev-rg`). These zones are **not** delegated from Cloudflare
and therefore receive no external queries. They are safe to delete.

Verify that a zone has no active NS delegation before deleting:

```bash
# If this returns NXDOMAIN or SERVFAIL, the zone has no public delegation
dig NS dev.korio.cloud +short
```

### Deletion procedure

If the zones are not already in Terraform, delete them via the Azure CLI:

```bash
az network dns zone delete \
  --name "${ENV}.korio.cloud" \
  --resource-group "vozni-${ENV}-rg" \
  --subscription "<env-subscription-id>" \
  --yes
```

If they are added to Terraform during Step 1 (not recommended — prefer keeping
public and private zones separate in state), remove the resource block and run
`terraform apply`.

---

## Step 3 — Relocate private DNS zones (Deferred)

### Context

The private DNS zones currently live in `devops-test`. The correct home is
`vozni-{env}-rg`, consistent with all other per-environment infrastructure.
Relocation is a destroy-and-recreate operation on the zone and its VNet link —
there is no in-place rename.

### Why this is deferred

The Twingate connector uses the VNet DHCP-assigned DNS server (168.63.129.16),
which resolves records from VNet-linked private DNS zones. A zone relocate
involves a brief period where the old zone is deleted and the new zone is not
yet linked. During that window:

- Internal `*.{env}.korio.cloud` hostnames will not resolve inside the cluster
- Twingate developers will lose hostname resolution for all internal services

This window needs to be assessed and a maintenance window planned before
relocation is attempted.

### Pre-requisites before attempting Step 3

1. Confirm with the Twingate team how quickly DNS changes propagate to connector
   nodes after a VNet link is recreated.
2. Identify the shortest possible deletion-and-recreate window (Terraform can
   likely do this in a single `apply` with `-target` ordering).
3. Plan a maintenance window for the affected environment.
4. After relocation, run `terraform plan` to confirm the new zone and link are
   stable.

---

## Verification

After completing Steps 1 and 2, verify:

```bash
# Private zone still resolves inside the cluster
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox --context vozni-${ENV}-aks \
  -- nslookup "*.${ENV}.korio.cloud"

# Public zone is gone (should return NXDOMAIN or SERVFAIL)
dig NS "${ENV}.korio.cloud" +short

# Terraform plan is clean (no pending changes)
cd terraform-infra/
terraform workspace select vozni-${ENV}
terraform plan
```
