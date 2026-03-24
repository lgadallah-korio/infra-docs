# Terraform Sensitive Variables

This document catalogues every variable declared with `sensitive = true`
across all Terraform root modules and child modules, along with its
declaration location, Key Vault coverage, and any associated concerns.

It is intended as a reference for the migration away from HCP variable sets,
where each module's sensitive variables must be accounted for before the
module's HCP variable set can be removed.

**Last updated:** 2026-03-24

---

## Root module sensitive variables

| Variable | Declared at | Modules | In Key Vault? | KV secret name |
|---|---|---|---|---|
| `azure_client_secret` | `env/variables.tf:24`<br>`org/variables.tf:20`<br>`app/variables.tf:24`<br>`app-monitor/variables.tf:28` | env, org, app, app-monitor | Yes | `devops-terraform-cloud-client-secret` |
| `atlas_private_key` | `env/variables.tf:46`<br>`app/variables.tf:38` | env, app | Yes | `terraform-atlas-private-key` |
| `twingate_api_token` | `env/variables.tf:53` | env | Yes | `twingate-api-token` |
| `argocd_github_webhook_secret` | `env/variables.tf:62` | env | Unknown | — |
| `argocd_github_app_secret` | `env/variables.tf:77` | env | Unknown | — |
| `grafana_github_app_secret` | `env/variables.tf:89` | env | Unknown | — |
| `datadog_api_key` | `env/variables.tf:103`<br>`org/variables.tf:27` | env, org | Yes | `datadog-api-key` |
| `datadog_app_key` | `env/variables.tf:110`<br>`org/variables.tf:34` | env, org | Yes | `datadog-app-key` |
| `github_provider_app_pem` | `org/variables.tf:60` | org | Yes | `github-app-pem-file` |
| `pagerduty_token` | `org/variables.tf:67`<br>`app-monitor/variables.tf:35` | org, app-monitor | Yes | `pagerduty-token` |
| `microsoft_teams_webhook_url_mongo` | `env-monitor/variables.tf:1` | env-monitor | Yes | `microsoft-teams-webhook-url-mongo` |

## Secrets fetched via data source (anti-pattern)

These secrets are read from Key Vault by the `azurerm` provider at plan time
via `data "azurerm_key_vault_secret"` and passed directly into resource or
module arguments. This means their values are written to Terraform state in
plaintext. They do not appear in `variables.tf`.

When the affected module is migrated away from HCP variable sets, these data
sources should be removed and replaced with `TF_VAR_*` exports in `tf.sh`,
which keeps the secret out of state entirely.

| Data source | Declared at | KV secret | Used in | Issue |
|---|---|---|---|---|
| `data.azurerm_key_vault_secret.dockerhub_password` | `env/data.tf:42` | `dockerhub-password` | `env/azure_container_uptime_kuma.tf:18`<br>`env/azure_container_twingate.tf:12` | Value written to state in plaintext |

## Module-level sensitive variables

| Variable | Declared at | Instantiated? | Notes |
|---|---|---|---|
| `dockerhub_password` | `modules/uptime-kuma/variables.tf:45` | Yes (from env/) | Receives value from the data source above |
| `storage_account_key` | `modules/uptime-kuma/outputs.tf:1` | Yes (from env/) | Sensitive output — storage account primary key written to state |
| `cloudflare_api_token` | `modules/cloudflare-dns-from-github/variables.tf:12` | No | Module is not instantiated anywhere — possible dead code |

---

## Concerns

### 1. `argocd_github_webhook_secret` has `default = ""`

`env/variables.tf:62` declares this variable with an empty string default.
If no value is supplied — for example, if the HCP variable set entry is
missing for a workspace — Terraform silently accepts the empty string as the
webhook secret rather than failing. This should be confirmed as non-empty in
all active `env-*` workspaces, and the default should be removed so that a
missing value causes an explicit error.

### 2. `dockerhub_password` and `storage_account_key` in state

The Docker Hub password flows from Key Vault → `data` source → module
argument → Terraform state. The storage account primary key flows from the
Azure API → module output → Terraform state. Both values are visible in
plaintext in the HCP state file for every `env-*` workspace.

Remediation when migrating `env/`:
- Remove `data "azurerm_key_vault_secret" "dockerhub_password"` from
  `env/data.tf`
- Add `TF_VAR_dockerhub_password` export to `tf.sh` (fetched from KV)
- Declare `dockerhub_password` as a root-level variable in `env/variables.tf`
  and pass it to the module

The `storage_account_key` sensitive output is less actionable — it reflects
a value Azure generates, not a secret we inject. Ensure that state access is
appropriately restricted.

### 3. `argocd_github_app_secret` and `grafana_github_app_secret` not confirmed in Key Vault

These are declared in `env/variables.tf` but were not present in the Common
secrets variable set. They are likely in a per-workspace variable set for
`env-*`. Before migrating `env/`, confirm these are in Key Vault and note
their secret names here.

### 4. `cloudflare_api_token` in unused module

`modules/cloudflare-dns-from-github/` declares a `cloudflare_api_token`
variable but the module is not instantiated anywhere in the codebase. If the
module is genuinely unused it should be removed to avoid confusion.

---

## Migration status

| Module | HCP variable set removed? | tf.sh case branch added? | Notes |
|---|---|---|---|
| `env-monitor` | In progress (pilot) | Yes | Three KV secrets + one hardcoded public key |
| `env` | No | No | Pending — see concerns above |
| `org` | No | No | Pending |
| `app` | No | No | Pending |
| `app-monitor` | No | No | Pending |
