# Runbook: Add a New Application Service

Use this runbook when a **brand-new microservice** is being added to the
platform — one that does not yet exist in any repo, presto manifest, or
ArgoCD ApplicationSet. For updating an existing service (new image SHA,
env var change, etc.), see the
[Microservice Deployment Lifecycle](../application-stack.md#microservice-deployment-lifecycle)
section in the Application Stack guide.

**Repos touched:** `terraform-infra` (org workspace), microservice repo,
`presto-besto-manifesto`, `argocd` (auto-generated), optionally `argocd`
(envfrom ConfigMaps), optionally `back-end-node` (React SPA only)

---

## Background: what the pipeline handles vs. what it does not

The presto → korioctl → ArgoCD pipeline is designed for services that
already exist and have an image in ACR. Once a service is in presto,
the pipeline fully automates:

- **ArgoCD ApplicationSet YAMLs** — one per service per environment,
  covering all sub-environments
- **External NGINX location blocks** — `api-gateway-cm.yaml` entries
  binding the client-specific path prefix to the service's Kubernetes
  Service name
- **Internal NGINX location blocks** — `internal-api-gateway-cm.yaml`
  derived automatically by the `Sync NGINX Config Files` workflow from
  the external config

What the pipeline does **not** cover for a brand-new service:

- Creating the GitHub repo and provisioning its CI/CD workflows
- Building and pushing the first container image to ACR
- Writing secrets to Azure Key Vault
- Committing envfrom ConfigMaps (if the service uses `envFrom`)
- Provisioning Azure Workload Identity (UAMI + FIC) for services that
  directly access Azure resources
- Wiring a new React SPA into `back-end-node`'s user dispatch logic

These must be completed before or alongside the presto PR.

---

## Phase 0: GitHub repo and CI/CD workflows

### Why is this needed?

Every microservice lives in its own GitHub repo under `korio-clinical`
(named `{service-name}-llama`). The per-environment deploy workflows
inside that repo (`dev-deploy.yml`, `staging-deploy.yml`, etc.) are
**Terraform-managed** (`terraform-infra/org/github_workflows`) and must
not be created by hand. A new repo therefore requires a Terraform change
in the `org` workspace to provision both the repository and its workflows.

### Step 0a: Provision the GitHub repo and workflows

Open a PR against `terraform-infra` in the `org` workspace to add the
new repo and its deploy workflows. Follow the patterns in
`terraform-infra/org/github_workflows` for the existing services. The
Terraform apply must be run locally after the PR is merged (HCP Terraform
VCS-triggered runs are disabled for this workspace).

### Step 0b: Check `BUILD_TYPE_LOOKUP` and `DEPLOYMENT_TYPE_LOOKUP`

These are org-level GitHub Variables (not secrets) consumed by the
reusable `deploy.yml` workflow:

| Variable | Default | When to override |
|---|---|---|
| `BUILD_TYPE_LOOKUP` | `docker-korio-microservice` | If the service has its own `Dockerfile` in the repo root rather than using the shared type-based Dockerfile from `korio-clinical/docker` |
| `DEPLOYMENT_TYPE_LOOKUP` | `helm` | Rarely needed; `sas-api` is the only service that uses `kustomize` |

For a standard Node.js, React, or Go service that uses the shared
Dockerfile, no changes to these variables are needed. If a custom
`BUILD_TYPE_LOOKUP` entry is required, update the org variable in the
GitHub UI (Settings → Variables) before the first build runs.

### Step 0c: Build and push the first image

Trigger the service's `dev-deploy.yml` workflow (via `workflow_dispatch`
or a push to its trigger branch) to produce the first container image
tagged with `github.sha` in ACR. Record the resulting SHA — you will
need it in Phase 2.

> Do not proceed to Phase 2 until an image SHA exists in ACR. presto
> does not accept a placeholder SHA and the ArgoCD Application will
> fail to sync if the image cannot be pulled.

---

## Phase 1: Azure Key Vault secrets

### Why is this needed?

If the service declares `externalSecret` in its presto manifest, the
ExternalSecrets operator will attempt to pull those secrets from Azure
Key Vault immediately after the ArgoCD Application syncs. If the
secrets do not exist yet, the ExternalSecret will fail and the pod
will not start.

Write all required secrets to the Key Vault for each sub-environment
before merging the argocd PR. Key Vault names follow the pattern
`vozni-{env}-{subenv}`.

```bash
az keyvault secret set \
  --vault-name "vozni-{env}-{subenv}" \
  --name "MY-SECRET-NAME" \
  --value "secret-value"
```

Repeat for each sub-environment that will run the service.

---

## Phase 2: presto-besto-manifesto

This is the primary developer-facing step. Three attributes are declared
per service per environment: container image SHA, env vars, and secrets.

```bash
cd presto-besto-manifesto
git checkout main && git pull
git checkout -b {author}/add-{service-name}
```

Edit `{env}/deployments.yaml` to add the new service entry. Consult
existing entries for the correct format. The three mandatory fields are:

| Field | What it controls |
|---|---|
| `image` | Full ACR image URI and SHA (e.g. `korio.azurecr.io/{service}:{sha}`) |
| `env` | Literal key-value env vars; baked into a ConfigMap |
| `externalSecret` | Maps env var names to Azure Key Vault secret names |

Open a PR against `main`. The Dagger CI pipeline fires automatically on
PR open and calls `korioctl PushToArgo`, which generates the ArgoCD
ApplicationSet YAMLs and NGINX ConfigMap location blocks and opens a PR
on the `argocd` repo.

---

## Phase 3: envfrom ConfigMaps (if applicable)

### When is this needed?

If the service uses `envFrom` in its presto manifest (referencing a
`{service}-envfrom` ConfigMap), those ConfigMaps must exist in the
`argocd` repo at `apps/{env}/{subenv}/{service}-envfrom.yaml` for every
sub-environment the service is deployed to. The ApplicationSet korioctl
generates will reference these files; if they are missing, the ArgoCD
Application will fail to sync.

### What to include

`envFrom` ConfigMaps carry sub-environment-specific values that vary
between sub-envs and therefore cannot be baked into the ApplicationSet
at korioctl generation time:

- `APP_BASE_URL` — the sub-environment's public-facing URL
- `INTERNAL_BASE_URL` — the internal NGINX gateway URL for service-to-service calls
- `MONGO_NAME_PREFIX` — the MongoDB database name prefix for this sub-env
- `MONGO_USERNAME` — the Atlas database user for this sub-env
- Any other values that differ between sub-environments

Create one file per sub-environment in the `argocd` repo:

```yaml
# argocd/apps/{env}/{subenv}/{service}-envfrom.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {service}-envfrom
data:
  APP_BASE_URL: https://{subenv}-{env}.korioclinical.com
  INTERNAL_BASE_URL: http://internal-api-gateway-nginx.{subenv}.svc.cluster.local
  MONGO_NAME_PREFIX: {env}-{subenv}
  MONGO_USERNAME: {subenv}
```

> These files can be committed alongside the auto-generated argocd PR
> (by pushing directly to the auto-generated branch) or in a separate
> PR. They must be on `main` before the ApplicationSet syncs.

---

## Phase 4: Auto-generated argocd PR

The Dagger pipeline that fires on the presto PR opens a PR on the
`argocd` repo automatically. This PR contains:

- A new `apps/{env}/{service}.yaml` ApplicationSet for each environment
  the service is deployed to
- New location blocks in `api-gateway-cm.yaml` for each sub-environment
- The `Sync NGINX Config Files` workflow then fires on any push touching
  `api-gateway-cm.yaml` and opens a follow-up PR to update the internal
  NGINX config (`internal-api-gateway-cm.yaml`)

Review both PRs and merge them. ArgoCD will sync immediately on merge.

---

## Phase 5: Verify

After the argocd PR(s) are merged and ArgoCD has synced:

```bash
# Check the Application is synced and healthy
kubectl get applications -n argocd | grep {service}

# Check the pod is running
kubectl get pods -n {subenv} | grep {service}

# Confirm the ExternalSecret synced (if applicable)
kubectl get externalsecret -n {subenv} {service}-kv

# Confirm the NGINX location block is present
kubectl get configmap api-gateway-cm -n {subenv} -o yaml | grep {service}
```

---

## Special cases

### Enabling external API routes (korioctl BasePaths)

NGINX location blocks are generated for a service only if it is
registered in the `BasePaths` map in `korioctl/pkg/service/routes.go`.
This hardcoded Go map is the gating check — a service absent from
`BasePaths` will never appear in the generated `api-gateway-cm.yaml`
regardless of what is in `apiRoutes.yaml`. If `apiRoutes.yaml` references
a service not in `BasePaths`, the Dagger pipeline fails with:

```
Error applying apiRoutes: route upstream missing from deployments:
/api/v1/<path>/ => <service-name>
```

Three changes must land together for end-to-end external access to work:

**1. korioctl `BasePaths` (korioctl repo PR)**

Add the service to `BasePaths` in `korioctl/pkg/service/routes.go`:

```go
var BasePaths = map[string][]string{
    // ...existing entries...
    "<service-name>": []string{"<canonical-path>"},
}
```

**2. `apiRoutes.yaml` (presto-besto-manifesto PR)**

Add the path-to-service mapping in `{env}/apiRoutes.yaml`. The service
name must always be the **base** service name — korioctl automatically
appends the version suffix (e.g. `-v1-0-0` for `release/v1.0.0`) when
constructing the Kubernetes Service DNS name:

```yaml
apiRoutes:
  /api/v1/<canonical-path>:
    main: <base-service-name>
    release/v1.0.0: <base-service-name>   # NOT <base-service-name>-v1-0-0
```

**3. Application global prefix (service repo PR)**

The service application code must declare the matching global prefix.
NestJS example in `src/app.ts` (or `src/main.ts`):

```typescript
const globalPrefix = 'api/v1/<canonical-path>';
app.setGlobalPrefix(globalPrefix);
// Update any middleware that uses a raw path to use the prefixed path:
app.use(`${globalPrefix}/some-raw-endpoint`, raw({...}));
```

The korioctl and presto PRs can merge first; the gateway will return 404
until the service PR is also deployed. The application PR can merge
first too — it only changes which paths the service binds to, not
whether it starts.

### React SPA (new client frontend)

A new client-specific React SPA (`app-react-{client}`) follows the same
presto pipeline as other services. The Helm chart creates an Ingress
object (via `ingress.rewrite: true` in the ApplicationSet) that routes
`/app-{client}/` to the container and strips the path prefix.

However, the platform's login flow requires an additional step.
`portico-react` calls `/api/v1/info/` → `back-end-node` after the user
authenticates. `back-end-node` resolves the user's client context from
MongoDB and redirects the browser to the correct client-specific app
path (e.g. `/app-{client}/`). **This routing logic lives in the
`back-end-node` application code and must be updated to include the new
client.** Without this change, authenticated users who belong to the new
client will not be redirected to the new SPA.

Coordinate with the `back-end-node` developer to ensure the user
dispatch logic is updated before the new SPA goes live.

### Services that access Azure resources directly (Workload Identity)

If the service needs to authenticate to Azure Storage (ADLS2), Azure
Key Vault directly, or other Azure services using Workload Identity, a
UAMI and FIC must be provisioned and declared in presto before the pod
can authenticate successfully.

**Step 1: Create the UAMI**

```bash
korioctl azure uami create \
  -g "vozni-{env}-sftp-storage" \
  "{env}-{subenv}-{service-name}"
# Record the Client ID returned — used in identities.yaml (Step 3)
# Record the Principal ID separately — used for DLDP ACLs if applicable
az identity show \
  --resource-group "vozni-{env}-sftp-storage" \
  --name "{env}-{subenv}-{service-name}" \
  --query "{clientId: clientId, principalId: principalId}" -o json
```

**Step 2: Create the FIC**

```bash
# Get the OIDC issuer for the cluster
export oidc_cluster_uuid="$(basename "$(az aks show \
  --resource-group "vozni-{env}-rg" \
  --name "vozni-{env}-aks" \
  --query oidcIssuerProfile.issuerUrl -otsv 2>/dev/null)")"
export oidc_issuer="https://eastus.oic.prod-aks.azure.com/{sub_id}/${oidc_cluster_uuid}/"

korioctl azure fic create \
  -g "vozni-{env}-sftp-storage" \
  --identity "{env}-{subenv}-{service-name}" \
  --issuer "${oidc_issuer}" \
  --subject "system:serviceaccount:{subenv}:{env}-{subenv}-{service-name}" \
  "{env}-{subenv}-{service-name}"
```

**Step 3: Declare the identity in presto**

Create or update `{env}/presto_conf/.internal/{subenv}/identities.yaml`
in presto-besto-manifesto:

```yaml
identityConfig:
  {service-name}:
    serviceAccount: {env}-{subenv}-{service-name}
    workloadId: <client-id-from-step-1>
```

This causes korioctl to annotate the generated Kubernetes ServiceAccount
with the UAMI Client ID, enabling the Workload Identity token exchange.

**Step 4: Assign RBAC roles to the UAMI**

Grant the UAMI the Azure RBAC roles it needs (e.g. `Storage Blob Data
Contributor` for ADLS2 access) via the Azure portal or CLI.

Repeat Steps 1-4 for each sub-environment.

For SFTP integration services that also require ADLS2 directory ACLs,
see the [Enable a Sub-environment](enable-prod-validate.md) runbook
Phase 2c (DLDP creation).

---

## Summary table

| Step | System | Action | When required |
|---|---|---|---|
| 0a | `terraform-infra` (org workspace) | Provision GitHub repo and deploy workflows | Always (new repo) |
| 0b | GitHub org variables | Update `BUILD_TYPE_LOOKUP` if non-standard Dockerfile | Only if custom build type |
| 0c | ACR | Build and push first image | Always |
| 1 | Azure Key Vault | Write secrets to each sub-env vault | If using `externalSecret` |
| 2 | `presto-besto-manifesto` | Add service entry (image, env vars, secrets) | Always |
| 2a | `presto-besto-manifesto` | Add route to `apiRoutes.yaml` (base service name only) | If service needs external API routes |
| 2b | `korioctl` | Add service to `BasePaths` in `pkg/service/routes.go` | If service needs external API routes |
| 2c | Service repo | Declare matching `setGlobalPrefix` in bootstrap | If service needs external API routes |
| 3 | `argocd` | Commit envfrom ConfigMaps | If using `envFrom` |
| 4 (auto) | `argocd` | ApplicationSet YAMLs + external NGINX config | Auto-generated by pipeline |
| 4 (auto) | `argocd` | Internal NGINX config | Auto-generated by `Sync NGINX Config Files` workflow |
| 4 (manual) | `argocd` | Review and merge auto-generated PRs | Always |
| SPA | `back-end-node` | Add client to user dispatch logic | New client React SPA only |
| WI-1 | Azure | Create UAMI | Workload Identity services only |
| WI-2 | Azure | Create FIC | Workload Identity services only |
| WI-3 | `presto-besto-manifesto` | Add entry to `identities.yaml` | Workload Identity services only |
| WI-4 | Azure | Assign RBAC roles to UAMI | Workload Identity services only |
