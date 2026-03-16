# Runbook: Adding a New MongoDB Atlas Database (Integration)

Use this runbook when a new integration (client or database partition) needs a
MongoDB database provisioned across environments. The outcome is a PR against
`terraform-infra/env/atlas_clusters.tf` that grants the appropriate Atlas
database user roles on the new database.

---

## Background

### Database naming convention

Every per-integration MongoDB database is named `{env}-{subenv}-{integration}`,
e.g. `prod-validate-acme`. The naming is enforced by the dynamic `roles` block
in `mongodbatlas_database_user.app_users`:

```hcl
# atlas_clusters.tf
dynamic "roles" {
  for_each = setunion(local.atlas_extra_databases["common"],
                      try(local.atlas_extra_databases[local.environment], []))
  content {
    database_name = format("%s-%s-%s", local.environment, each.key, roles.value)
    role_name     = "readWrite"  # (and a matching dbAdmin block)
  }
}
```

Adding an integration name to `atlas_extra_databases` causes Terraform to grant
`readWrite` and `dbAdmin` on `{env}-{subenv}-{integration}` for **every**
sub-environment user in scope. The MongoDB database itself is created
automatically the first time the application writes to it.

### `MONGO_CONNECTION_STRING` is not affected

`MONGO_CONNECTION_STRING` (Key Vault secret `MONGO-CONNECTION-STRING`) holds the
cluster URI, not a database-specific URI. It is shared across all
sub-environments and integrations within an environment. Adding a new database
does **not** require updating this secret. Services derive the target database
name from runtime env vars such as `MONGO_NAME_PREFIX`.

---

## Step 1: Determine scope

Decide which environments need the new database.

| Scope | When to use | Where to add |
|---|---|---|
| All environments | Integration being rolled out everywhere | `common` list |
| Specific environment(s) only | Demo/test-only client, or staged rollout | Named key (`dev`, `test`, `staging`, `prod`, etc.) |

> **Note:** There is no per-sub-environment scope. Adding a database grants
> access to all sub-environments (`configure`, `preview`, `validate`, `accept`,
> `my`) within the chosen scope.

Current `atlas_extra_databases` in `env/atlas_clusters.tf`:

```hcl
atlas_extra_databases = {
  common   = ["global", "acme", "biopab", "pharmaco", "recode", "moderna",
               "maia", "alpheus", "kumquat", "tagworks", "tgtherapeutics"]
  dev      = ["korio"]
  test     = ["jjdemo", "bms", "korio"]
  platform = ["korio"]
}
```

Environments without an explicit key (`staging`, `prod`, `staging3`, `prod3`,
`platform3`, `sandbox`) inherit only the `common` list.

---

## Step 2: Create a feature branch

```bash
cd terraform-infra/
git checkout main && git pull
git checkout -b feat/atlas-db-{integration}
```

---

## Step 3: Edit `atlas_clusters.tf`

Open `env/atlas_clusters.tf` and add the integration name to the appropriate
list(s).

**Example — add `newclient` to all environments:**

```hcl
  atlas_extra_databases = {
    common   = ["global", "acme", "biopab", "pharmaco", "recode", "moderna",
-                "maia", "alpheus", "kumquat", "tagworks", "tgtherapeutics"]
+                "maia", "alpheus", "kumquat", "tagworks", "tgtherapeutics",
+                "newclient"]
    dev      = ["korio"]
    test     = ["jjdemo", "bms", "korio"]
    platform = ["korio"]
  }
```

**Example — add `jjdemo2` to `test` only:**

```hcl
    test     = ["jjdemo", "bms", "korio", "jjdemo2"]
```

**Example — add `betaclient` to `staging` and `prod` (new key required):**

```hcl
  atlas_extra_databases = {
    common   = [...]
    dev      = ["korio"]
    test     = ["jjdemo", "bms", "korio"]
    platform = ["korio"]
+   staging  = ["betaclient"]
+   prod     = ["betaclient"]
  }
```

Use lowercase, hyphen-free names. The resulting database name will be
`{env}-{subenv}-{integration}`.

---

## Step 4: Format and validate

```bash
cd env/
terraform fmt
terraform validate
```

---

## Step 5: Open a PR

```bash
git add env/atlas_clusters.tf
git commit -m "feat: add {integration} MongoDB database to {scope}"
git push -u origin feat/atlas-db-{integration}
# then open a PR against main on github.com/korio-clinical/terraform-infra
```

Include in the PR description:
- Which integration is being added
- Which environments/sub-environments will be affected
- Confirmation that `MONGO_CONNECTION_STRING` does not need updating

---

## Step 6: Apply after PR merge (per environment)

After the PR is merged, apply the change locally for each affected environment.
The team applies Terraform locally; HCP Terraform VCS-triggered runs are
disabled.

```bash
cd env/
terraform workspace select vozni-{env}

# Targeted plan -- verify only the database user roles change
terraform plan \
  -target='mongodbatlas_database_user.app_users'

# Apply
terraform apply \
  -target='mongodbatlas_database_user.app_users'
```

Repeat for each environment in scope (e.g. `vozni-dev`, `vozni-test`,
`vozni-staging`, `vozni-prod`).

> **Do not** pass `-target='random_password.mongoatlas_users'` unless you
> intend to rotate passwords. A targeted apply on `app_users` alone updates
> roles without touching passwords.

---

## Step 7: Verify

### Confirm roles via Atlas API

```bash
# Replace {subenv} with any sub-environment (e.g. "validate")
curl --digest -s \
  -u "${ATLAS_PUBLIC_KEY}:${ATLAS_PRIVATE_KEY}" \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${ATLAS_PROJECT_ID}/databaseUsers/admin/{subenv}" \
  | jq '[.roles[] | select(.databaseName | contains("{integration}"))]'
```

Expected output: two role objects (`readWrite` and `dbAdmin`) for each
`{env}-{subenv}-{integration}` database.

### Confirm the connection string is unchanged

```bash
az keyvault secret show \
  --vault-name vozni-{env}-{subenv} \
  --name MONGO-CONNECTION-STRING \
  --query value -o tsv
```

The URI should be identical to what was there before the apply.

---

## Scope reference

The table below shows which Terraform workspace to target for each
environment-scope combination.

| Integration scope | Workspaces to apply |
|---|---|
| `common` | All: dev, test, platform, platform3, staging, staging3, prod, prod3, sandbox |
| `dev` key | `vozni-dev` only |
| `test` key | `vozni-test` only |
| `staging` + `prod` keys | `vozni-staging`, `vozni-prod` |
| `staging3` + `prod3` keys | `vozni-staging3`, `vozni-prod3` |
