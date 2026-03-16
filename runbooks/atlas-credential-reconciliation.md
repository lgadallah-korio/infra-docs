# Runbook: Atlas Credential Reconciliation

Use this runbook when MongoDB authentication is failing for a sub-environment —
typically surfacing as 401 errors from auth-node, or as `MongoServerError: bad auth`
/ `Authentication failed` in pod logs.

**Background:** Terraform manages the Atlas database user and its password, but
does not write the MongoDB URI to Key Vault. The password in Key Vault can
therefore diverge from the password Terraform has set in Atlas. See
[infrastructure.md — MongoDB Atlas Credential Management](../infrastructure.md#mongodb-atlas-credential-management)
for the full design.

---

## Step 1: Distinguish auth failures from connectivity failures

The fix is different depending on whether MongoDB cannot be reached at all, or
whether it is reached but rejecting credentials.

```bash
# Tail the last 200 auth-node log lines and filter for MongoDB errors.
# Run this for the affected sub-environment namespace.
kubectl logs -n {subenv} --context vozni-{env}-aks \
  -l app=auth-node --tail=200 | \
  grep -Ei 'mongo|auth|error|connect|ECONN|ENOTFOUND'
```

| Log pattern | Meaning | Go to |
|---|---|---|
| `bad auth`, `Authentication failed`, `not authorized`, `AuthenticationFailed` | Password mismatch or user deleted | Step 2 |
| `ECONNREFUSED`, `ENOTFOUND`, `MongoNetworkError`, `MongoServerSelectionError`, `connection timed out` | Network / Private Link / Atlas cluster unavailable | Step 3 |
| Both patterns present | Likely connectivity issue masking auth error | Step 3 first, then Step 2 |

The `check-atlas-health.sh` script automates this classification:

```bash
./infra-docs/scripts/check-atlas-health.sh -n {subenv} {env}
```

---

## Step 2: Resolve an auth failure (password mismatch or deleted user)

### 2a. Check whether the Atlas user exists

Using the Atlas API (credentials from 1Password / HCP Terraform variables):

```bash
# The expected username is the sub-environment name (e.g. "validate")
curl --digest -s \
  -u "${ATLAS_PUBLIC_KEY}:${ATLAS_PRIVATE_KEY}" \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${ATLAS_PROJECT_ID}/databaseUsers/admin/{subenv}" \
  | jq '{username: .username, roles: [.roles[].databaseName]}'
```

- **200 with user data** — user exists; password mismatch is the cause. Go to **Step 2b**.
- **404** — user was deleted. Go to **Step 2c**.

### 2b. Password mismatch — resync Key Vault to match Terraform state

The Atlas user exists but its password (set by Terraform) does not match the
URI stored in Key Vault. Read the Terraform-managed password:

```bash
cd terraform-infra/
terraform workspace select vozni-{env}

terraform state show 'random_password.mongoatlas_users["{subenv}"]' | grep result
```

Confirm the correct cluster-id suffix for the Private Link hostname. For
prod-validate this is `v1wct` (`vozni-prod-validate-pl-0.v1wct.mongodb.net`).
For other sub-environments, check the Atlas UI cluster detail page or an
existing working envfrom ConfigMap in `argocd/apps/{env}/{subenv}/`.

Update the Key Vault secret with the correct URI:

```bash
az keyvault secret set \
  --vault-name vozni-{env}-{subenv} \
  --name <mongo-uri-secret-name> \
  --value "mongodb+srv://{subenv}:<password-from-tf-state>@vozni-{env}-{subenv}-pl-0.<cluster-id>.mongodb.net/?authSource=admin"
```

Force ESO to re-sync the K8s Secret immediately:

```bash
kubectl annotate externalsecret <es-name> -n {subenv} \
  --context vozni-{env}-aks \
  force-sync="$(date +%s)" --overwrite
```

Verify auth-node stops producing auth errors:

```bash
kubectl logs -n {subenv} --context vozni-{env}-aks \
  -l app=auth-node --tail=50 --follow
```

### 2c. Deleted user — restore via Terraform

If the Atlas user is missing, Terraform should recreate it. Run a targeted
plan to confirm:

```bash
cd terraform-infra/
terraform workspace select vozni-{env}

terraform plan \
  -target='random_password.mongoatlas_users["{subenv}"]' \
  -target='mongodbatlas_database_user.app_users["{subenv}"]'
```

The plan should show a `create` action for the database user. If it does not
(e.g. the user is already in state as existing), the state is inconsistent —
see Step 2d. Otherwise apply:

```bash
terraform apply \
  -target='random_password.mongoatlas_users["{subenv}"]' \
  -target='mongodbatlas_database_user.app_users["{subenv}"]'
```

Then immediately update Key Vault as described in Step 2b. The password will
be the same value already in TF state (the `random_password` resource is not
recreated if it already exists in state).

### 2d. State inconsistency — user missing in Atlas but present in TF state

If `terraform plan` shows no create action but the user does not exist in
Atlas, TF state and Atlas are out of sync. Remove the stale state entry so
Terraform will recreate it:

```bash
# Remove stale state entries — this does NOT delete anything in Atlas
terraform state rm 'mongodbatlas_database_user.app_users["{subenv}"]'
terraform state rm 'random_password.mongoatlas_users["{subenv}"]'
```

Then re-run the targeted plan and apply from Step 2c. Note: removing
`random_password` from state causes Terraform to generate a **new** random
password. You must update Key Vault with this new password after the apply.

---

## Step 3: Resolve a connectivity failure

Connectivity failures (ECONNREFUSED, MongoServerSelectionError, etc.) mean the
pod cannot reach the Atlas cluster at all, regardless of credentials.

### 3a. Check the Atlas cluster state

```bash
# Cluster name for prod/staging per-subenv: vozni-{env}-{subenv}
# Cluster name for dev/test/platform shared: vozni-{env}
curl --digest -s \
  -u "${ATLAS_PUBLIC_KEY}:${ATLAS_PRIVATE_KEY}" \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${ATLAS_PROJECT_ID}/clusters/vozni-{env}-{subenv}" \
  | jq '{name: .name, state: .stateName}'
```

Expected state: `IDLE`. Any other state (`REPAIRING`, `UPDATING`, `CREATING`)
means the cluster is temporarily unavailable — wait for it to return to `IDLE`.

### 3b. Check the Private Link endpoint status

The Private Link connection is per-environment, not per-sub-environment. If
one sub-env has connectivity issues, all sub-envs in the same environment may
be affected.

```bash
curl --digest -s \
  -u "${ATLAS_PUBLIC_KEY}:${ATLAS_PRIVATE_KEY}" \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${ATLAS_PROJECT_ID}/privateEndpoint/AZURE/endpointService" \
  | jq '.results[] | {id: ._id, status: .status}'
```

Expected status: `AVAILABLE`. If `WAITING_FOR_USER`, `INITIATING`, or `FAILED`,
run a targeted Terraform apply to reconcile the Private Link resources:

```bash
cd terraform-infra/
terraform workspace select vozni-{env}

terraform plan \
  -target='mongodbatlas_privatelink_endpoint.azure' \
  -target='mongodbatlas_privatelink_endpoint_service.azure' \
  -target='azurerm_private_endpoint.atlas'

terraform apply \
  -target='mongodbatlas_privatelink_endpoint.azure' \
  -target='mongodbatlas_privatelink_endpoint_service.azure' \
  -target='azurerm_private_endpoint.atlas'
```

### 3c. Test DNS resolution from inside the cluster

If the cluster and Private Link look healthy but pods still cannot connect,
the CoreDNS resolution of the Private Link hostname may be broken. Test from
inside the auth-node pod:

```bash
kubectl exec -n {subenv} --context vozni-{env}-aks \
  deploy/auth-node -- \
  sh -c 'nslookup vozni-{env}-{subenv}-pl-0.<cluster-id>.mongodb.net'
```

If DNS resolution fails, check the AKS VNet DNS configuration and whether the
Private Link DNS zone is correctly linked to the VNet.

---

## Step 4: Verify recovery

After any fix, confirm the following before closing the incident:

```bash
# 1. No MongoDB errors in auth-node logs for the past 2 minutes
kubectl logs -n {subenv} --context vozni-{env}-aks \
  -l app=auth-node --tail=100 | \
  grep -Ei 'mongo|auth.*error|bad auth|ECONN' | wc -l
# Expected: 0

# 2. Successful HTTP requests flowing through (no 401s from MongoDB-related auth failures)
kubectl logs -n {subenv} --context vozni-{env}-aks \
  -l app=nginx --tail=100 | \
  grep -c '"status".*401'
# Expected: 0 (or baseline level if unrelated auth failures exist)
```

---

## Prevention

To avoid this class of incident in the future:

1. **Never manually change Atlas database users whose names match sub-env names.**
   Terraform will reconcile them away.

2. **Add `prevent_destroy = true`** to `mongodbatlas_database_user.app_users` and
   `random_password.mongoatlas_users` in `terraform-infra/env/atlas_clusters.tf`.
   This blocks accidental deletion at plan time.

3. **Update Key Vault immediately after any Terraform apply** that modifies Atlas
   users. Make this a checklist item in any runbook that involves running
   `terraform apply` on the `env/` workspace.
