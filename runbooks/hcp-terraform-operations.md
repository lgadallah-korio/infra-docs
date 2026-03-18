# Runbook: HCP Terraform Operations

This runbook documents operational gotchas, best practices, and
troubleshooting steps for managing Korio's HCP Terraform organisation
(`korio-clinical`). Several of these were learned the hard way and are
recorded here to avoid repeating the same debugging sessions.

---

## Variable management

### Always delete and re-create sensitive variables rather than editing them

**This is the single most important rule in this runbook.**

When you edit a sensitive variable in the HCP Terraform UI, the UI
accepts the new value and appears to save it — but the underlying stored
value is not reliably updated. Subsequent Terraform runs may continue
using the old value with no indication that anything is wrong. This
behaviour has caused at least a full day of debugging time.

**Always rotate a sensitive variable by:**
1. Deleting the existing variable entry.
2. Creating a new entry with the same name and the new value.

This applies to both workspace-level variables and variable set entries.

---

### Variable sets and Key Vault can drift out of sync

Secrets used by Terraform are stored in two places:
- **Azure Key Vault** (`vozni-common-secrets-kv`) — the source of truth
- **HCP Terraform "Common secrets" variable set** — what Terraform
  actually reads at runtime

These are not linked. When a secret is rotated in Key Vault, the
corresponding variable in HCP Terraform must be updated manually in the
same operation. If only one is updated, they silently diverge and
Terraform runs will fail with authentication errors while CLI tests
(which pull directly from Key Vault) succeed.

**Rule:** whenever you rotate a secret in Key Vault, update the
corresponding HCP Terraform variable in the same step. Use the
delete-and-recreate approach described above.

To retrieve the current value from Key Vault for pasting into HCP
Terraform:

```bash
az keyvault secret show \
  --vault-name "vozni-common-secrets-kv" \
  --name <secret-name> \
  --query value -o tsv
```

---

### Variable type matters: Terraform variable vs Environment variable

In HCP Terraform, each variable has a category:

| Category | How it works | Example |
|---|---|---|
| **Terraform variable** | Passed directly as `var.<name>` | A variable named `foo` feeds `var.foo` |
| **Environment variable** | Set as an env var in the run | A variable named `TF_VAR_foo` feeds `var.foo` via Terraform's `TF_VAR_*` mechanism |

Getting the category wrong silently breaks things:

- A Terraform variable named `TF_VAR_foo` attempts to set
  `var.TF_VAR_foo`, which almost certainly does not exist, rather than
  `var.foo`. It will appear in the "variables defined without being
  declared" warning.
- An environment variable named `foo` (without the `TF_VAR_` prefix)
  sets an env var literally named `foo`, which Terraform does not
  automatically map to `var.foo`. The provider may fall back to its own
  env var lookups (e.g. `DD_API_KEY` for the Datadog provider) or
  simply receive no value.

**Rule:** when adding a new variable to a variable set, double-check the
category. If the variable name has a `TF_VAR_` prefix, it must be
an **Environment variable**. If it feeds `var.<name>` directly, it must
be a **Terraform variable**.

---

### Workspace-level variables override variable sets

HCP Terraform applies variables in this precedence order (highest wins):

1. Workspace-level variables
2. Variable sets
3. `TF_VAR_*` environment variables
4. `terraform.tfvars` / `*.auto.tfvars` files uploaded with the workspace
5. Variable defaults in code

If a variable set update does not appear to take effect, check whether
the target workspace has a workspace-level variable with the same name
that is overriding it. Workspace-level variables are visible under the
workspace's own **Variables** tab, separate from the variable sets
listed under **Settings** > **Variable sets**.

---

### The "variables defined without being declared" warning

HCP Terraform plan output may include:

```
In addition to the other similar warnings shown, 8 other variable(s)
defined without being declared.
```

This means variables exist in a variable set (or workspace variables)
whose names do not correspond to any `variable "<name>"` block in the
Terraform code. These variables have no effect and are likely dead
entries left over from previous configurations.

To see the full list (the HCP Terraform UI truncates it), run the plan
locally:

```bash
terraform plan 2>&1 | grep "The root module does not declare a variable"
```

Or enumerate statically:

```bash
# Declared variables in .tf files:
grep -rh '^\s*variable\s' *.tf | grep -oP '(?<=variable ")[^"]+' | sort > declared.txt

# Variables set in .tfvars:
grep -oP '^\s*\K\w+(?=\s*=)' *.tfvars | sort > defined.txt

comm -13 declared.txt defined.txt
```

Dead variables should be removed from the variable set to keep
configuration clean and avoid confusion during future debugging.

---

## Debugging failing runs

### Enable TRACE logging for a run

To get detailed HTTP-level output from providers (useful for diagnosing
authentication failures), add a **workspace-level** environment variable
before triggering a plan:

| Key | Value | Category |
|-----|-------|----------|
| `TF_LOG` | `TRACE` | Environment variable |

Set this at the **workspace level** (not in Common secrets) so it only
affects the workspace being debugged and is easy to remove afterward.

Download the raw log from the run page and search for the provider name,
`403`, or `error` to find the relevant section. At `TRACE` level, the
log will show the full HTTP request and response for every provider API
call, including which headers are being sent.

**Remove `TF_LOG` immediately after debugging** — `TRACE` logs are very
large and will slow down runs.

---

### Validating credentials before triggering a Terraform run

**Azure service principal:**

```bash
az login --service-principal \
  --username <client-id> \
  --password "$(az keyvault secret show \
    --vault-name vozni-common-secrets-kv \
    --name <secret-name> --query value -o tsv)" \
  --tenant <tenant-id>
```

Returns account JSON on success. `AADSTS7000215` means the Secret ID
was stored instead of the Secret Value. `AADSTS7000222` means the secret
has expired.

After verifying, log back out and back in as yourself:

```bash
az logout && az login
```

**Datadog API key:**

```bash
curl -X GET "https://api.us3.datadoghq.com/api/v1/validate" \
  -H "DD-API-KEY: $(az keyvault secret show \
    --vault-name vozni-common-secrets-kv \
    --name datadog-api-key --query value -o tsv)"
```

Returns `{"valid": true}` on success. Note: this endpoint only validates
the API key — it ignores any app key passed alongside it.

**Datadog app key:**

```bash
curl -X GET "https://api.us3.datadoghq.com/api/v2/current_user" \
  -H "DD-API-KEY: $(az keyvault secret show \
    --vault-name vozni-common-secrets-kv \
    --name datadog-api-key --query value -o tsv)" \
  -H "DD-APPLICATION-KEY: $(az keyvault secret show \
    --vault-name vozni-common-secrets-kv \
    --name datadog-app-key --query value -o tsv)"
```

Returns user JSON on success. `{"errors":["Forbidden","This API does
not support scoped app keys..."]}` means the app key has permission
scopes set — the Terraform provider requires an unscoped app key.

---

## Common secrets variable set reference

The **"Common secrets"** variable set is applied to all workspaces and
provides shared credentials. Key Datadog entries:

| Variable name | Category | Feeds | Notes |
|---|---|---|---|
| `TF_VAR_datadog_api_key` | Environment variable | `var.datadog_api_key` | Must be unscoped |
| `TF_VAR_datadog_app_key` | Environment variable | `var.datadog_app_key` | Must be unscoped |
| `Datadog-API-Key` | Terraform variable | `var.Datadog-API-Key` | Declared but unused — dead variable, candidate for removal |
| `ARM_CLIENT_SECRET` | Environment variable | `var.azure_client_secret` | Expires periodically — see rotate-terraform-client-secret.md |
