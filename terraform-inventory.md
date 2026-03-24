# Terraform Resource Inventory

This document inventories all resources managed by Terraform across the
`terraform-infra/` root modules, grouped by scope. It was produced as
part of planning a migration away from HCP Terraform and a broader
modularisation effort.

**Last updated:** 2026-03-20

---

## Root module layout

| Directory | State scope | Workspace scheme (current) | Notes |
|---|---|---|---|
| `org/` | Common/global — single state | `org` (single) | Rename to `common/` planned |
| `env/` | Per environment | prefix `env-` | azurerm 3.117.0 |
| `app/` | Per environment | prefix `app-` | azurerm 4.15.0 |
| `env-monitor/` | Per environment | prefix `env-monitor-` | |
| `app-monitor/` | Per environment | prefix `app-monitor-` | |
| `modules/` | Shared modules | n/a | |

Environments: `sandbox`, `dev`, `test`, `platform`, `platform3`,
`staging`, `staging3`, `prod`, `prod3`.

Sub-environments (per env): `configure`, `preview`, `validate`,
`accept`, `my`.

---

## Scope: `common` (currently `org/`) — single state, no environment dimension

| Resource | Type | Notes |
|---|---|---|
| `azurerm_resource_group.rg` | Azure | `vozni-common-rg` |
| `azurerm_container_registry.acr` | Azure | `korioclinical`, Standard SKU |
| `azurerm_dns_zone.korio_cloud_public` | Azure | `korio.cloud` |
| `azurerm_logic_app_workflow.logic_app_defender_alerts` | Azure | Defender alert -> PagerDuty |
| `azurerm_logic_app_trigger_custom.mdc_trigger` | Azure | MDC alert trigger |
| `azurerm_logic_app_action_custom.pagerduty_create_incident` | Azure | PD incident action |
| `azurerm_api_connection.*` | Azure | Defender + PagerDuty API connections |
| `pagerduty_service.defender` | PagerDuty | |
| `pagerduty_service_integration.defender` | PagerDuty | |
| `pagerduty_escalation_policy.defender` | PagerDuty | |
| `pagerduty_schedule.defender` | PagerDuty | |
| `github_branch_default.main` | GitHub | for_each over all repos (from `applications.yaml`) |
| `github_repository_ruleset.main` | GitHub | for_each over all repos |
| `github_repository_ruleset.main_bypass` | GitHub | for_each over all repos |
| `github_repository_ruleset.release` | GitHub | for_each over all repos |
| `github_repository_ruleset.pre_release` | GitHub | for_each over all repos |
| `github_repository_file.workflows` | GitHub | Syndicates workflow YAMLs to all repos + release branches |
| `azurerm_sentinel_*` | Azure | **ALL COMMENTED OUT** -- dead code, safe to delete |

### `applications.yaml`

`org/locals.tf` reads `applications.yaml` via `yamldecode(file(...))` to
produce the `repositories` local used by `github_repositories.tf` and
`github_workflows.tf`. The file declares ~27 microservice repos and, for each:

- `repository` -- GitHub repo name
- `workflows` -- workflow YAML files (from `org/github_workflows/`) to
  syndicate to that repo
- `optional_checks` / `required_checks` / `release_required_checks` --
  branch protection status checks

`sftp-server` is the only entry that maps to multiple repos (a list of
three: `sftp-acl-init-go`, `sftp-data-sync-go`, `sftp-server-docker`);
all other entries map to a single repo. The `locals.tf` flattens this
into a map keyed by repo name, discarding the logical service grouping.

**Migration note:** `applications.yaml` can be replaced with a typed
`variable "repositories"` in `variables.tf` with the data moved to
`common.tfvars`. The `sftp-server` grouping is an artefact of the YAML
format and can be dropped -- Terraform never uses the service-name key.
The `data "tfe_workspace" "org"` rate-limit guard in `data.tf` uses an
HCP-Terraform-specific data source and must be replaced with a hardcoded
threshold when HCP Terraform is removed.

---

## Scope: `env/` -- per environment (x9 envs)

### Grouping A -- Network

| Resource | Type | Notes |
|---|---|---|
| `azurerm_resource_group.rg` | Azure | `vozni-{env}-rg` |
| `module.vnet` | Azure/vnet/azurerm 4.1.0 | VNet + 6 subnets; address space and prefixes are per-env (embedded locals) |
| `azurerm_network_security_group.aks_ingress_snet` | Azure | Always created |
| `azurerm_network_security_group.privatelink_snet_nsg` | Azure | Conditional (`count`); currently only sandbox |

Subnet names (fixed across all envs): `aks-node-snet`, `aks-ingress-snet`,
`aks-agw-snet`, `privatelink-snet`, `vpn-snet`, `container-snet`.

### Grouping B -- AKS

| Resource | Type | Notes |
|---|---|---|
| `module.aks` | Azure/aks/azurerm 9.4.1 | Cluster config (K8s version, SKU tier, node pool sizes) differs per env (embedded locals) |
| `kubernetes_service.dd_nginx_default_metrics` | Kubernetes | Datadog/Prometheus scrape target for external NGINX ingress |

### Grouping C -- Workload Identities

| Resource | Type | Notes |
|---|---|---|
| `azurerm_user_assigned_identity.id` | Azure | for_each: `aks-external-secrets`, `aks-grafana` |
| `azurerm_federated_identity_credential.id` | Azure | for_each: same two |
| `azurerm_role_assignment.aks_ingress_common_certs_user` | Azure | AKS WAR identity -> common TLS KV (Certificate User) |
| `azurerm_role_assignment.aks_eso_common_secrets_user` | Azure | ESO UAMI -> common secrets KV (Secrets User) |
| `azurerm_role_assignment.aks_eso_common_certs_user` | Azure | ESO UAMI -> common TLS KV (Certificate User) |
| `azurerm_role_assignment.aks_eso_env_secrets_user` | Azure | ESO UAMI -> env RG (Secrets User) |
| `azurerm_role_assignment.aks_eso_env_certs_user` | Azure | ESO UAMI -> env RG (Certificate User) |
| `azurerm_role_assignment.aks_grafana_monitor_reader` | Azure | Grafana UAMI -> subscription (Monitoring Reader) |

### Grouping D -- Azure AD Applications

| Resource | Type | Notes |
|---|---|---|
| `azuread_application.apps` | Azure AD | for_each: `aks-external-secrets` |
| `azuread_application_password.apps` | Azure AD | for_each: same |
| `azuread_service_principal.apps` | Azure AD | for_each: same |
| `azurerm_role_assignment.apps` | Azure | for_each: same |
| `azuread_application.argocd_sso` | Azure AD | ArgoCD Dex Microsoft connector |
| `time_rotating.argocd_sso_client_secret` | time | 365-day rotation trigger |
| `azuread_application_password.argocd_sso_client_secret` | Azure AD | 2-year secret, rotated by `time_rotating` |
| `azuread_service_principal.argocd_sso` | Azure AD | |

### Grouping E -- Key Vaults (per sub-environment)

| Resource | Type | Notes |
|---|---|---|
| `azurerm_key_vault.kv` | Azure | for_each over `sub_environments[env]`; naming is inconsistent for `staging` (known bug, documented in source comments) |

Naming convention:
- `prod`, `staging3`, `prod3` -> `vozni-{env}-{subenv}` (e.g. `vozni-prod-validate`)
- All other envs -> `{env}-{subenv}` (e.g. `test-validate`)
- `staging` should follow the prod-like pattern but does not; fixing requires
  a secrets backup and 30-day soft-delete window.

### Grouping F -- MongoDB Atlas

| Resource | Type | Notes |
|---|---|---|
| `mongodbatlas_project.project` | Atlas | `vozni-{env}` |
| `mongodbatlas_team.observers` | Atlas | All Atlas org users as observers |
| `mongodbatlas_advanced_cluster.cluster` | Atlas | for_each over `atlas_clusters[env]`; `shared` key for dev/test/platform/sandbox; per-subenv keys for staging/prod/staging3/prod3 |
| `mongodbatlas_cloud_backup_schedule.policy` | Atlas | for_each: same as clusters; hourly/daily/weekly/monthly/yearly policies |
| `mongodbatlas_database_user.master_user` | Atlas | username `admin` / role `atlasAdmin` |
| `mongodbatlas_database_user.app_users` | Atlas | for_each over `sub_environments[env]`; passwords in TF state only -- not written to Key Vault automatically |
| `random_password.mongoatlas_users` | random | for_each over sub_environments |
| `random_password.mongoatlas_master_user` | random | |
| `mongodbatlas_privatelink_endpoint.azure` | Atlas | |
| `mongodbatlas_privatelink_endpoint_service.azure` | Atlas | |
| `azurerm_private_endpoint.atlas` | Azure | In `privatelink-snet` |
| `azurerm_public_ip.atlas` | Azure | Dynamic allocation; used for Atlas NIC |
| `azurerm_network_interface.atlas` | Azure | NIC for Atlas private endpoint access |

Atlas cluster naming:
- `prod`, `staging`, `prod3`, `staging3` -> one cluster per sub-env: `vozni-{env}-{subenv}`
- `dev`, `test`, `platform`, `platform3`, `sandbox` -> one shared cluster: `vozni-{env}`

`lifecycle { ignore_changes = [...] }` is set on clusters because manual
changes are being made outside Terraform (disk size, replica specs).

### Grouping G -- Azure Monitor / Observability

| Resource | Type | Notes |
|---|---|---|
| `azurerm_log_analytics_workspace.main` | Azure | 30d retention (lower envs), 60d (customer envs) |
| `azurerm_log_analytics_solution.container_insights` | Azure | Container Insights solution |
| `azurerm_monitor_workspace.main` | Azure | Azure Monitor managed Prometheus |
| `azurerm_monitor_data_collection_endpoint.dce` | Azure | Prometheus DCE |
| `azurerm_monitor_data_collection_endpoint.logs_dce` | Azure | Logs DCE |
| `azurerm_monitor_data_collection_rule.dcr` | Azure | Prometheus DCR |
| `azurerm_monitor_data_collection_rule.logs_dcr` | Azure | Container Insights DCR |
| `azurerm_monitor_data_collection_rule_association.dcra` | Azure | Prometheus DCR -> AKS |
| `azurerm_monitor_data_collection_rule_association.logs_dcra` | Azure | Logs DCR -> AKS |
| `azurerm_monitor_alert_prometheus_rule_group.aks_node_recording` | Azure | 11 node recording rules |
| `azurerm_monitor_alert_prometheus_rule_group.aks_kubernetes_recording` | Azure | 13 Kubernetes recording rules |
| `azurerm_monitor_alert_prometheus_rule_group.aks_ux_recording` | Azure | 16 UX recording rules |

### Grouping H -- Helm Releases (Kubernetes bootstrapping)

| Resource | Type | Notes |
|---|---|---|
| `helm_release.argo_cd` | Helm | ArgoCD 7.7.1; Dex SSO (GitHub + Microsoft connectors) |
| `helm_release.argocd_apps` | Helm | argocd-apps 2.0.2; app-of-apps bootstrap |
| `helm_release.external_secrets` | Helm | external-secrets 0.10.5; Workload Identity auth |
| `helm_release.grafana` | Helm | grafana 8.6.0; Azure Monitor Prometheus + GitHub OAuth |

ArgoCD bootstrap sequence and dependencies are described in detail in
`infrastructure.md`.

### Grouping I -- DNS

| Resource | Type | Notes |
|---|---|---|
| `azurerm_dns_zone.public` | Azure | `{env}.korioclinical.com` |
| `azurerm_dns_ns_record.public` | Azure | Delegation NS record in parent zone |
| `azurerm_dns_a_record.aks_internal_ingress` | Azure | `@` -> internal LB IP (from `kubernetes_service` data source) |
| `azurerm_dns_cname_record.wildcard_aks_internal_ingress` | Azure | `*` -> `{env}.korio.cloud` |

### Grouping J -- Twingate + Container Instances

| Resource | Type | Notes |
|---|---|---|
| `twingate_remote_network.azure_network` | Twingate | `vozni-{env}` |
| `twingate_connector.azure_connector` | Twingate | `vozni-{env}-vnet` |
| `twingate_connector_tokens.azure_connector_tokens` | Twingate | Injected into ACI as env vars |
| `twingate_resource.atlas_resource` | Twingate | Atlas private endpoint IP; accessible to Engineers + Admins |
| `twingate_resource.vnet` | Twingate | VNet CIDR; accessible to Admins only |
| `azurerm_container_group.*` | Azure ACI | Twingate connector container (`twingate/connector:1`) |
| `module.uptime_kuma` | local module | Uptime Kuma ACI; sized by `customer_environment` flag |

### Placeholders / empty files (candidates for deletion)

| File | Status |
|---|---|
| `azure_disks.tf` | Empty `locals` map, no resources |
| `azure_ips.tf` | Empty `locals` map, no resources |

---

## Scope: `app/` -- per environment (x9 envs)

| Resource | Type | Notes |
|---|---|---|
| `azurerm_public_ip.sftp` | Azure | for_each over `sub_environments[env]`; one static public IP per sub-env; domain label `korio-sftp-{env}-{subenv}` |
| `azurerm_managed_disk.sftp` | Azure | for_each over `sub_environments[env]`; 32 GB managed disk per sub-env |

Note: `app/` uses azurerm provider 4.15.0 while `env/` uses 3.117.0.
These cannot be merged without an azurerm major version upgrade in `env/`.

### Placeholders / empty files (candidates for deletion)

| File | Status |
|---|---|
| `kubernetes.tf` | Empty `locals` maps (`kubernetes_for_env`, `kubernetes_for_subenv`), no resources |
| `azure_rg.tf` | Commented-out resource group templates, no resources |

---

## Scope: `env-monitor/` -- per environment (x9 envs)

| Resource | Type | Notes |
|---|---|---|
| `pagerduty_service.service` | PagerDuty | for_each: `mongo`, `mongo-metrics` |
| `pagerduty_service_integration.integration` | PagerDuty | for_each: same; vendor = "MongoDB Cloud Alerts" |
| `pagerduty_escalation_policy.escalation_policy` | PagerDuty | for_each: same |
| `pagerduty_schedule.schedule` | PagerDuty | for_each: same; 2-layer weekly rotation |

**Notable gap:** `atlas_alerts_configs.tf` defines `locals.mongo_alerts`
(Atlas alert thresholds and event types) but creates no actual
`mongodbatlas_alert_configuration` resources. The configuration is
declared but never applied. This is either incomplete work or resources
previously removed from state. Requires clarification before the
refactor.

Also contains `tf_env.tf` (a null resource that runs `env | sort`
locally for debugging TFC environment variables) -- **dead code, safe to
delete**.

---

## Scope: `app-monitor/` -- per environment (x9 envs)

| Resource | Type | Notes |
|---|---|---|
| `azurerm_monitor_action_group.apps` | Azure | Webhook -> PagerDuty apps service |
| `azurerm_monitor_action_group.rabbitmq` | Azure | Webhook -> PagerDuty rabbitmq service |
| `azurerm_monitor_alert_prometheus_rule_group.apps` | Azure | KubeContainerWaiting, KubePodUnhealthy; **disabled** in lower envs (`rule_group_enabled = local.alert_environment`) |
| `azurerm_monitor_alert_prometheus_rule_group.rabbitmq` | Azure | 5 RabbitMQ alert rules; **disabled** in lower envs |
| `pagerduty_service.apps` | PagerDuty | Urgency: severity-based (alert envs) or low (lower envs) |
| `pagerduty_service.rabbitmq` | PagerDuty | |
| `pagerduty_service_integration.azure_apps` | PagerDuty | Azure alerts vendor integration |
| `pagerduty_service_integration.azure_rabbitmq` | PagerDuty | |
| `pagerduty_escalation_policy.apps` | PagerDuty | 30m delay (alert envs), 60m (lower) |
| `pagerduty_escalation_policy.rabbitmq` | PagerDuty | |
| `pagerduty_schedule.apps` | PagerDuty | 2-layer rotation; `lifecycle { ignore_changes }` on start/rotation_virtual_start to suppress PD API drift |
| `pagerduty_schedule.rabbitmq` | PagerDuty | Same lifecycle treatment |

Environment classification used by `app-monitor/`:
- `alert_environment` (alerts enabled, severity-based urgency): `staging`, `staging3`, `prod`, `prod3`
- `lower_environment` (alerts disabled, low urgency): `sandbox`, `dev`, `test`, `platform`, `platform3`

---

## Existing modules (`modules/`)

| Module | Used by | Purpose |
|---|---|---|
| `modules/uptime-kuma` | `env/` | Azure Container Instance running Uptime Kuma; sized by `customer_environment` |
| `modules/cloudflare-dns-zone` | (unknown -- not referenced in files read) | Cloudflare DNS zone management |

---

## Cross-cutting observations

### 1. Three divergent `sub_environments` maps

The same map is defined independently in three separate modules, and the
`app-monitor/` version is materially different:

| Module | `dev` value |
|---|---|
| `env/locals.tf` | `["configure", "accept", "my", "validate", "preview"]` |
| `app/locals.tf` | `["configure", "accept", "my", "validate", "preview"]` |
| `app-monitor/locals.tf` | `["configure"]` |

The `app-monitor/` divergence is intentional (it scopes Prometheus alert
namespace regexes, so `dev` only needs `configure`). However, having
three separate definitions with no shared source of truth is a latent
consistency risk. Migration to per-env tfvars should address this by
making the scoping explicit per module.

### 2. Embedded per-environment configuration in locals

Four files contain large `locals {}` blocks that encode per-environment
config, selected at apply-time by `local.environment`. These are the
primary candidates for extraction to per-env tfvars files:

| File | Contents |
|---|---|
| `env/azure_vnet.tf` | VNet address space + subnet prefixes for all 9 envs |
| `env/azure_aks_cluster.tf` | AKS cluster version, SKU tier, node pool sizes for all 9 envs |
| `env/atlas_clusters.tf` | Atlas cluster instance sizes + disk sizes per env/subenv |
| `app-monitor/locals.tf` | `sub_environments`, `alert_environment`, `lower_environment` flags |

### 3. `terraform.workspace` as environment identity

All env-scoped modules derive `local.environment` from the workspace name:

```hcl
environment = element(split("-", terraform.workspace), length(split("-", terraform.workspace)) - 1)
```

This is the primary coupling to HCP Terraform. Replacing with
`var.environment` is the first step of the migration.

### 4. `data "tfe_workspace"` in `org/data.tf`

Used for the GitHub API rate limit guard. This is an HCP-Terraform-specific
data source and must be removed. Replace the postcondition with a simple
threshold check (e.g. `remaining > 500`) rather than comparing against
`resource_count`.

### 5. Dead / placeholder code -- safe to delete

| File | Location | Reason |
|---|---|---|
| `azure_sentinel.tf` | `org/` | Entirely commented out |
| `azure_disks.tf` | `env/` | Empty locals, no resources |
| `azure_ips.tf` | `env/` | Empty locals, no resources |
| `kubernetes.tf` | `app/` | Empty locals, no resources |
| `azure_rg.tf` | `app/` | Commented-out, no resources |
| `tf_env.tf` | `env-monitor/` | Debug null resource, no production value |

### 6. `atlas_alerts_configs.tf` gap

`env-monitor/atlas_alerts_configs.tf` declares `locals.mongo_alerts` with
alert thresholds and event types but creates no actual
`mongodbatlas_alert_configuration` resources. Clarify intent before
proceeding -- either complete the implementation or remove the dead locals.

### 7. `app/` provider version mismatch

`env/` is on azurerm 3.117.0; `app/` has been upgraded to 4.15.0.
These cannot be merged into a single root module without first upgrading
`env/` to azurerm 4.x, which is a breaking change requiring resource
attribute updates.

---

## Monolithism assessment

### What "monolithic" means in Terraform

In Terraform, monolithism has three distinct dimensions:

1. **State blast radius** -- how much live infrastructure is at risk from a single `apply`
2. **Coupling** -- how many unrelated concerns share a root module and state file
3. **Configuration granularity** -- can you make a targeted change to one environment or one resource group without touching everything else

A well-structured implementation minimises all three.

### Module-by-module assessment

#### `env/` -- Highly monolithic

This is the most significant problem. A single `terraform apply env-prod`
has blast radius over:

| Domain | Resources at risk |
|---|---|
| Networking | VNet, 6 subnets, NSGs |
| AKS | Entire cluster, node pools, autoscaler profile |
| Kubernetes bootstrapping | ArgoCD, External Secrets, Grafana Helm releases; ArgoCD app-of-apps |
| Azure AD | 2 app registrations + service principals, ArgoCD SSO app + rotating secret |
| Workload identities | 2 UAMIs + federated credentials + 6 role assignments |
| MongoDB Atlas | Project, 1-5 clusters, backup schedules, admin user, 5 sub-env DB users, Private Link (both sides) |
| Key Vaults | 5 vaults (one per sub-env) |
| Azure Monitor | Log Analytics workspace, Azure Monitor workspace, 2 DCEs, 2 DCRs, 2 DCRAs, 40 Prometheus recording rules |
| DNS | Public zone, NS delegation, A record, wildcard CNAME |
| Twingate | Remote network, connector, tokens, 2 resources, ACI container |
| Misc | Uptime Kuma ACI |

That is roughly 100+ resources across 11 entirely unrelated infrastructure
domains in a single state file. Rotating an ArgoCD client secret and
resizing an Atlas cluster are in the same blast radius. So are changing a
Prometheus recording rule and updating a Key Vault.

The coupling is further compounded by deep cross-domain dependency chains
within the same module -- the AKS cluster must exist before the ArgoCD
Helm release can run, which must exist before the DNS A record can be set
(it reads the internal LB IP), which chains back through the VNet. These
are legitimate provisioning dependencies, but embedding them all in one
flat module means there is no way to update observability config without
having a provider connection to AKS, Atlas, Twingate, and Azure AD
simultaneously.

#### `app/` -- Not monolithic

Only two resource types (SFTP IPs and managed disks), both iterated with
`for_each` over sub-environments. The blast radius is small and the scope
is coherent. Its existence as a separate module is primarily a historical
artefact of HCP Terraform workspace organisation rather than a meaningful
logical boundary.

#### `org/` (`common/`) -- Moderately monolithic, with one acute problem

The org-level resources (ACR, DNS, Logic Apps, PagerDuty, GitHub rulesets)
are a reasonable grouping -- they are genuinely org-scoped with no
environment dimension.

The acute problem is `github_repository_file.workflows`. A single
`terraform apply` can commit changes to every workflow YAML file across all
~27 repos, on both `main` and every `release/*` branch simultaneously. A
mis-applied change here has an unusually wide blast radius for what is
notionally a configuration management task.

#### `env-monitor/` -- Not monolithic

Four PagerDuty resources per environment, all coherent in scope. Lean and
appropriate.

#### `app-monitor/` -- Not monolithic

Twelve resources covering Azure Monitor alert rules and PagerDuty services
for application-layer alerts. Coherent scope, appropriate size.

### Overall verdict

The implementation is **partially monolithic**, concentrated almost entirely
in `env/`. The monitoring and app modules are well-scoped. The problem is
structural: `env/` conflates infrastructure provisioning (AKS, VNet,
Atlas), application bootstrapping (ArgoCD, Helm), and operational concerns
(monitoring, DNS, Twingate) into a single deployable unit.

The practical consequences:

**1. Every apply requires every provider to be authenticated
simultaneously.** To update a Prometheus recording rule, you need valid
credentials for Azure, Azure AD, MongoDB Atlas, Twingate, Kubernetes, and
Helm -- all at once.

**2. Plan output is unreadable at scale.** A `terraform plan` against
`env-prod` returns changes across 11 domains. Operators cannot quickly
assess whether a plan is safe -- the signal-to-noise ratio is very low.

**3. State lock contention.** Any operation on any resource in `env/` --
even a read-only refresh -- locks the entire env state, blocking concurrent
work.

**4. Targeted applies become the de facto workflow.** The `-target` flag
being the recommended approach for sub-environment scoped changes is a code
smell: needing `-target` routinely means the module boundaries are wrong.

**5. Risk of cascading partial failures.** If, say, the Twingate provider
returns a transient error mid-apply, Terraform may leave state partially
updated across completely unrelated resources (e.g. a Key Vault was updated
but ArgoCD was not).

### The one genuine structural strength

The separation of `env/`, `app/`, `env-monitor/`, and `app-monitor/` into
four distinct root modules with independent state files is the right
instinct -- it just was not taken far enough inside `env/`. The monitoring
and app modules demonstrate what appropriately scoped modules look like.
The `env/` module needs the same treatment applied internally.

### What good would look like

A well-layered structure for `env/` would separate at minimum:

| Proposed scope | Contents | Rationale |
|---|---|---|
| `env/network` | VNet, NSGs, resource group | Pure infrastructure; no provider other than azurerm needed |
| `env/cluster` | AKS module, workload identities, role assignments, DNS | Depends on network output; no Kubernetes/Helm provider needed |
| `env/bootstrap` | ArgoCD, External Secrets, Grafana Helm releases | Depends on cluster; short-lived, frequent change cadence |
| `env/database` | Atlas project, clusters, Private Link, Key Vaults | Independent domain; Atlas + azurerm providers only |
| `env/monitoring` | Azure Monitor workspace, DCEs, DCRs, Prometheus rules | Currently split across `env/` and `env-monitor/`; consolidate here |

This would reduce the blast radius of any single apply by roughly 80% and
allow operators to authenticate only against the providers relevant to
their current task.

---

## Variable analysis

This section documents every variable declared across the five root modules,
where it is actually referenced, and whether it can be replaced by a
provider-native environment variable (eliminating it from Terraform
entirely).

**Last updated:** 2026-03-23

### Methodology

Each `variables.tf` was read to catalogue declarations. Each module directory
was then searched for `var.<name>` references across all `.tf` files. A
variable declared but never referenced would indicate a dead HCP variable-set
placeholder; however, no such variables were found — every declared variable
is genuinely referenced in at least one resource or provider block.

### Complete variable matrix

`S` = sensitive=true, `Y` = declared and referenced, `-` = not declared in this module.

| Variable | S | env | org | app | env-monitor | app-monitor |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `azure_subscription_id` | | Y | Y | Y | - | Y |
| `azure_tenant_id` | | Y | Y | Y | - | Y |
| `azure_client_id` | | Y | Y | Y | - | Y |
| `azure_client_secret` | S | Y | Y | Y | - | Y |
| `atlas_organization_id` | | Y | - | - | - | - |
| `atlas_public_key` | | Y | - | Y | Y | - |
| `atlas_private_key` | S | Y | - | Y | Y | - |
| `twingate_api_token` | S | Y | - | - | - | - |
| `argocd_github_webhook_secret` | S | Y | - | - | - | - |
| `argocd_github_app_id` | | Y | - | - | - | - |
| `argocd_github_app_secret` | S | Y | - | - | - | - |
| `grafana_github_app_id` | | Y | - | - | - | - |
| `grafana_github_app_secret` | S | Y | - | - | - | - |
| `privatelink_nsg_enabled_environments` | | Y | - | - | - | - |
| `datadog_api_key` | S | Y | Y | - | - | - |
| `datadog_app_key` | S | Y | Y | - | - | - |
| `datadog_url` | | Y | Y | - | - | - |
| `github_provider_app_id` | | - | Y | - | - | - |
| `github_provider_app_installation_id` | | - | Y | - | - | - |
| `github_provider_app_pem` | S | - | Y | - | - | - |
| `pagerduty_token` | S | - | Y | - | Y | Y |
| `microsoft_teams_webhook_url_mongo` | S | - | - | - | Y | - |

**Total declared:** env=17, org=11, app=6, env-monitor=4, app-monitor=5.
No variable is declared in all five modules. The closest are the four Azure
auth vars (subscription, tenant, client ID, client secret), which appear in
four of five modules — `env-monitor` has no `azurerm` provider and therefore
needs none of them.

### Variable categorisation for migration

Variables fall into three categories that determine how they should be handled
in the post-HCP tfvars-based setup.

#### Category A — provider-only: eliminate via provider-native env vars

These variables appear **only** in `providers.tf`. Once the corresponding
provider-native environment variable is set, the variable block and every
`var.xxx` reference can be deleted from the module entirely.

| Variable | S | Provider env var | Modules affected |
|---|:---:|---|---|
| `azure_tenant_id` | | `ARM_TENANT_ID` | env, org, app, app-monitor |
| `azure_client_id` | | `ARM_CLIENT_ID` | env, org, app, app-monitor |
| `azure_client_secret` | S | `ARM_CLIENT_SECRET` | env, org, app, app-monitor |
| `atlas_public_key` | | `MONGODB_ATLAS_PUBLIC_KEY` | env, app, env-monitor |
| `atlas_private_key` | S | `MONGODB_ATLAS_PRIVATE_KEY` | env, app, env-monitor |
| `twingate_api_token` | S | `TWINGATE_API_TOKEN` | env |
| `datadog_api_key` | S | `DD_API_KEY` | env, org |
| `datadog_app_key` | S | `DD_APP_KEY` | env, org |
| `datadog_url` | | `DATADOG_HOST` | env, org |
| `github_provider_app_installation_id` | | `GITHUB_APP_INSTALLATION_ID` | org |
| `github_provider_app_pem` | S | `GITHUB_APP_PEM_FILE` | org |

Of the 11 sensitive variables in the codebase, **six** (azure_client_secret,
atlas_private_key, twingate_api_token, datadog_api_key, datadog_app_key,
github_provider_app_pem) fall into this category and can be removed from
Terraform state entirely by setting the corresponding env var before running
`terraform`. The `tf.sh` wrapper script should export these from Key Vault via
`az keyvault secret show` before delegating to `terraform`.

#### Category B — provider + resource: variable stays, provider reference becomes env var

These variables appear in `providers.tf` **and** in resource or Helm value
blocks. The provider reference can use the env var, but the variable must
remain because it is interpolated into resource arguments. They should be
moved to the appropriate `envs/<env>.tfvars` or `envs/common.tfvars`.

| Variable | S | Modules | Non-provider reference |
|---|:---:|---|---|
| `azure_subscription_id` | | env, org, app, app-monitor | Resource scope strings, Helm values (`env/azure_identities.tf`, `env/helm.tf`, `org/azure_defender.tf`) |
| `pagerduty_token` | S | org, env-monitor, app-monitor | `org/az_api_connection.tf` (Logic App API connection body) |
| `github_provider_app_id` | | org | `org/github_repositories.tf` (bypass actor on branch rulesets) |

`azure_subscription_id` is non-sensitive and already has a hardcoded default
in most modules; it belongs in `envs/common.tfvars`. `pagerduty_token` is
sensitive and must be sourced from Key Vault at runtime, not stored in any
tfvars file. `github_provider_app_id` is non-sensitive and already has a
default; it belongs in `envs/common.tfvars`.

#### Category C — resource-only: TF variable with no provider-native alternative

These variables are only referenced in resource or Helm blocks; no provider
supports them as an environment variable. They must remain as Terraform
variables and be sourced either from a non-sensitive tfvars file or from
Key Vault at runtime (for sensitive ones).

| Variable | S | Module(s) | Used in |
|---|:---:|---|---|
| `atlas_organization_id` | | env | Atlas project and team resource arguments |
| `argocd_github_webhook_secret` | S | env | Helm release value (`env/helm.tf`) |
| `argocd_github_app_id` | | env | Helm release value |
| `argocd_github_app_secret` | S | env | Helm release value |
| `grafana_github_app_id` | | env | Helm release value |
| `grafana_github_app_secret` | S | env | Helm release value |
| `privatelink_nsg_enabled_environments` | | env | `locals.tf` logic (`is_privatelink_nsg_enabled`) |
| `microsoft_teams_webhook_url_mongo` | S | env-monitor | Atlas alert integration webhook URL |

Non-sensitive ones (`atlas_organization_id`, `argocd_github_app_id`,
`grafana_github_app_id`, `privatelink_nsg_enabled_environments`) belong in
`envs/common.tfvars` (or `envs/<env>.tfvars` if they vary per env).
Sensitive ones must be exported by the wrapper script from Key Vault as
`TF_VAR_<name>` before calling `terraform`.

### Summary: sensitive variable handling

Of the 11 sensitive variables:

| Variable | Strategy |
|---|---|
| `azure_client_secret` | Provider env var (`ARM_CLIENT_SECRET`) — remove from TF |
| `atlas_private_key` | Provider env var (`MONGODB_ATLAS_PRIVATE_KEY`) — remove from TF |
| `twingate_api_token` | Provider env var (`TWINGATE_API_TOKEN`) — remove from TF |
| `datadog_api_key` | Provider env var (`DD_API_KEY`) — remove from TF |
| `datadog_app_key` | Provider env var (`DD_APP_KEY`) — remove from TF |
| `github_provider_app_pem` | Provider env var (`GITHUB_APP_PEM_FILE`) — remove from TF |
| `pagerduty_token` | Keep as TF var; `tf.sh` exports `TF_VAR_pagerduty_token` from Key Vault |
| `argocd_github_webhook_secret` | Keep as TF var; `tf.sh` exports from Key Vault |
| `argocd_github_app_secret` | Keep as TF var; `tf.sh` exports from Key Vault |
| `grafana_github_app_secret` | Keep as TF var; `tf.sh` exports from Key Vault |
| `microsoft_teams_webhook_url_mongo` | Keep as TF var; `tf.sh` exports from Key Vault |

Net result: 6 sensitive variables are removed from Terraform state completely;
5 remain as `TF_VAR_*` exports injected at runtime, never written to any
tfvars file.
