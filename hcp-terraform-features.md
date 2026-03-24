# HCP Terraform — Feature Reference

This document lists features that are specific to HCP Terraform (i.e. have
no native open-source Terraform equivalent), along with their self-managed
alternatives and current usage status in this codebase.

## State and execution

| Feature | Description | Alternative |
|---|---|---|
| Remote state backend | The `remote`/`cloud` backend itself | azurerm, s3, gcs backends |
| Hosted runner | HCP's managed execution environment for remote plans/applies | Any CI runner (GitHub Actions) when using Local execution mode |
| Self-hosted agents | Terraform runs on your own infra, lifecycle-managed by HCP | Pure CI runner |
| State version history and UI | Browsing previous state versions graphically | None without HCP; raw state files in other backends have no equivalent UI |

## Variable and workspace management

| Feature | Description | Alternative |
|---|---|---|
| Variable sets | Sharing variables across multiple workspaces | tfvars files + environment variables |
| Workspace prefix scheme | The `prefix =` pattern in the `remote` backend | Not available with azurerm or other backends; workspace separation managed via separate state keys |
| `tfe` provider and data sources | `tfe_workspace`, `tfe_variable_set`, etc. — only work against HCP | N/A (HCP-only) |

## Policy and governance

| Feature | Description | Alternative |
|---|---|---|
| Sentinel | Policy-as-code framework enforced as a run gate | conftest/OPA, tflint (external to Terraform) |
| Cost estimation | Automated cost diff on every plan | Infracost |
| Run tasks | Third-party integrations (security scanning, compliance) wired into the run lifecycle | CI pipeline steps |

## Access control and audit

| Feature | Description | Alternative |
|---|---|---|
| Team-based RBAC | Per-workspace permissions for plan/apply/state management | CI pipeline access controls, branch protection rules |
| SSO/SAML | Federated identity for HCP UI access | Not relevant once HCP UI is no longer the control plane |
| Audit log | Tamper-evident log of all API and UI actions | GitHub Actions run history (partial substitute) |

## Notifications and visibility

| Feature | Description | Alternative |
|---|---|---|
| VCS integration | HCP natively watches a branch and triggers runs | GitHub Actions |
| Run notifications | Slack/email alerts on plan/apply status | GitHub Actions notification steps |
| Structured plan output in UI | Coloured resource diff view in HCP UI | CI logs (same content, plain text) |
| Private module registry | Hosting internal Terraform modules within HCP | git-based module sources |
| Private provider registry | Hosting internal providers within HCP | Network mirror or filesystem mirror |

---

## Current usage in this codebase

| Feature | Currently used | Status / Replacement |
|---|---|---|
| Remote state backend | Yes | Staying on HCP |
| Hosted runner / VCS auto-apply | Yes | Replacing with GitHub Actions |
| Variable sets | Yes | Replacing with Key Vault + tf.sh |
| Workspace prefix scheme | Yes | Staying on HCP |
| `data "tfe_workspace"` data source | Yes (env/) | Needs replacing — simple local value or removed |
| Team RBAC | Basic | GitHub branch protection |
| Sentinel | No | — |
| Cost estimation | No | — |
| Private registry | No | — |
| SSO | No | — |
| Audit log | No | — |
