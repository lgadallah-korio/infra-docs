# Internal TLS Certificate Rotation Runbook

## Overview

Wildcard TLS certificates for `*.{env}.korio.cloud` are used for internal
service-to-service communications within each AKS cluster. Certificates are
issued by Let's Encrypt, stored in the shared Azure Key Vault
`vozni-common-tls-kv`, and distributed to pods via the External Secrets
Operator (ESO) as the `internal-korio-tls` Kubernetes secret.

Certificates expire every **90 days**. Renewal is currently a manual process.

### Certificate names in Key Vault

| Environment | Key Vault certificate name        |
|-------------|-----------------------------------|
| sandbox     | `sandbox-korio-cloud-pfx`         |
| dev         | `dev-korio-cloud-pfx`             |
| test        | `test-korio-cloud-pfx`            |
| platform    | `platform-korio-cloud-pfx`        |
| staging     | `staging-korio-cloud-pfx`         |
| prod        | `prod-korio-cloud-pfx`            |

### Active sub-environments per environment

These are the sub-environments that need secrets rotated after cert renewal:

| Environment | Sub-environments                          |
|-------------|-------------------------------------------|
| sandbox     | `configure`                               |
| dev         | `configure validate`                      |
| test        | `configure validate my`                   |
| platform    | `configure validate preview`              |
| staging     | `configure validate preview`              |
| prod        | `configure validate accept my`            |

---

## Prerequisites

### Tools

- **Azure CLI** — must be logged in: `az login`
- **certbot** — installed via pipx with the Cloudflare DNS plugin:

  ```bash
  pipx install certbot --python python3.13
  pipx inject certbot certbot-dns-cloudflare
  ```

  > Do NOT use Python 3.14 — certbot dependencies are not compatible with it.

- **kubectl** — must have contexts configured for target clusters
- **jq**, **openssl**

### Cloudflare credentials file

certbot uses a Cloudflare API token to create DNS challenge records.
The credentials file must exist at `~/.secrets/certbot/cloudflare.ini`:

```ini
dns_cloudflare_api_token = <token>
```

```bash
mkdir -p ~/.secrets/certbot
echo "dns_cloudflare_api_token = <token>" > ~/.secrets/certbot/cloudflare.ini
chmod 600 ~/.secrets/certbot/cloudflare.ini
```

The token requires `Zone:DNS:Edit` and `Zone:Zone:Read` permissions on
`korio.cloud`. The current token expires **2026-10-07** — rotate it before
that date or renewal will fail.

To create a new token: Cloudflare dashboard -> My Profile -> API Tokens ->
Create Token -> Edit zone DNS template -> Zone Resources: korio.cloud.

> **Note:** IP restriction is not practical for Let's Encrypt tokens —
> the validation servers use dynamic, unpublished IP ranges.

---

## Renewal procedure

### Step 1 — Check current expiry

```bash
az keyvault certificate show \
  --name <env>-korio-cloud-pfx \
  --vault-name vozni-common-tls-kv \
  --query '{thumbprint:x509Thumbprint, expires:attributes.expires, updated:attributes.updated}' \
  --output table
```

Let's Encrypt will not issue a new certificate if the existing one has more
than 30 days remaining unless `--force-renewal` is passed to certbot.

### Step 2 — Generate and upload the new certificate

```bash
cd devops-scripts/certbot/
./generate_cert.sh <env>
```

This script:
1. Runs certbot with the Cloudflare DNS-01 authenticator
2. Issues a wildcard cert covering `<env>.korio.cloud` and `*.<env>.korio.cloud`
3. Converts the cert to PFX format
4. Imports the PFX into `vozni-common-tls-kv` as `<env>-korio-cloud-pfx`

### Step 3 — Rotate secrets and restart RabbitMQ

```bash
./update_secrets.sh <env> <subenv1> [subenv2 ...]
```

Example:
```bash
./update_secrets.sh dev configure validate
```

This script:
1. Verifies the new cert is present in Key Vault
2. Deletes the `internal-korio-tls` secret in each sub-environment namespace
   and forces ESO to re-fetch from Key Vault
3. Polls until ESO has recreated the secret (up to 6 minutes), then verifies
   the cert dates
4. Patches the `keyvault-rabbitmq` secret in each `rabbitmq-<subenv>`
   namespace and restarts the RabbitMQ StatefulSet

The script is safe to re-run if interrupted.

---

## Known issues and gotchas

### ESO sync may be slow

ESO's reconciler queue can be backed up by failing ExternalSecrets (e.g.
`int-biostats-node` in dev continuously errors on a missing Key Vault secret).
This can delay recreation of `internal-korio-tls` by several minutes.
`update_secrets.sh` polls for up to 6 minutes before timing out.

To diagnose ESO delays:
```bash
kubectl --context vozni-<env>-aks \
  -n external-secrets \
  logs deployment/external-secrets \
  --tail=50 | grep -i "error"
```

### RabbitMQ uses manually-managed secrets

RabbitMQ's TLS secret (`keyvault-rabbitmq`) is not managed by ESO — it must
be patched manually after each cert renewal. The reason for this is not
documented. `update_secrets.sh` handles this automatically.

### ArgoCD restart may not be reachable

The ArgoCD CLI connects to the internal ingress, which requires Twingate.
If the ArgoCD restart command fails with an EOF error, use `kubectl` directly:

```bash
kubectl --context vozni-<env>-aks \
  -n rabbitmq-<subenv> \
  rollout restart statefulset
```

### korio.cloud DNS is managed in Cloudflare

The `korio.cloud` domain is registered and managed in Cloudflare. The
`generate_cert.sh` script uses the `certbot-dns-cloudflare` plugin, which
writes the DNS-01 challenge record directly to Cloudflare. No Azure DNS
zones are required for cert issuance.

> If you see an older version of the script using `--authenticator dns-azure`,
> it is out of date. The Azure DNS plugin was replaced with the Cloudflare
> plugin after the domain was migrated to Cloudflare.

### pipx and certbot installation

Certbot must be installed as its own pipx app. Do not install certbot or its
plugins into another pipx app's venv (e.g. xkcdpass). To verify:

```bash
which certbot
# should be: /Users/<user>/.local/bin/certbot

pipx list | grep certbot
# should show certbot as a standalone app
```

If certbot resolves to a path inside another venv, reinstall it:
```bash
pipx uninstall certbot   # if it exists as a misplaced app
pipx install certbot --python python3.13
pipx inject certbot certbot-dns-cloudflare
```
