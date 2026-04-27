# Runbook: Modify SFTP Human User Access

This runbook covers adding or removing individual human users from SFTP
access. It is scoped to **human users** (sponsor staff, client staff, Korio
staff) — not service accounts or full integration provisioning. For the
latter, see [sftp.md](../sftp.md).

**Repos touched:** `kubernetes-manifests`
**Azure resources:** Key Vault (full user removal only)

---

## Background: what controls human user access

Human users authenticate via SSH key and land in a chroot-jailed home
directory on the Azure Disk PVC. Their access to specific study directories
is controlled by POSIX group membership: `sftp-acl-init` sets ACLs on the
PVC using the GIDs in `etc-group`, so adding or removing a user from a group
is what grants or revokes their access to a study path.

Three distinct principal types interact with the SFTP system — see
[sftp.md](../sftp.md#principal-types-and-access-paths) for the full table.
This runbook covers **external SFTP users** only.

### Key Vault shadow file scope

`etc-shadow` (per-user password entries) lives in Azure Key Vault as the
`sftp-etc-shadow` secret and **only needs updating when adding or removing a
user entirely from `etc-passwd`**. Changing group membership does not touch
it. `etc-gshadow` (group shadow) is managed entirely in the repo via
`secretGenerator` and is never stored in Key Vault.

---

## Set variables before starting

```bash
export km="path/to/kubernetes-manifests/kustomize/sftp-server/overlays"
```

Determine which environments and sub-environments are in scope. The full
matrix is:

| Environment | Sub-environments |
|-------------|-----------------|
| dev | configure, validate |
| test | configure, validate, my |
| platform | configure, validate, preview |
| staging | configure, validate, preview |
| prod | configure, accept, my |

---

## Case 1: Remove a user from a specific study group

Use this when a user should lose access to one study but keep access to
others (e.g. their user entry and SSH key remain; only group membership
changes).

### Step 1 — Check for cross-study membership

Before touching anything, confirm which groups the user belongs to across
all overlays:

```bash
grep -r "<username>" "${km}" --include="etc-group" | grep -v "^Binary"
```

Look for the user appearing in multiple study groups (e.g.
`moderna-cluepoints-mrna-2808-p101-ro` as well as
`moderna-cluepoints-mrna-next-001-ro`). If they have memberships in other
studies, this case applies. If they are only in the target group, proceed
to Case 2 instead.

### Step 2 — Remove from the target group in etc-group and etc-gshadow

The member list in `etc-group` and `etc-gshadow` must stay identical.
Replace `<group>` with the full group name (e.g.
`moderna-cluepoints-mrna-next-001-ro`) and adjust the sed pattern to match
the exact member list as it appears in the files.

```bash
# Preview the lines that will change
grep -r "<group>" "${km}" --include="etc-group"
grep -r "<group>" "${km}" --include="etc-gshadow"

# Apply the change
find "${km}" -name "etc-group" \
  -exec sed -i '' 's/<group>:x:<gid>:<members>/<group>:x:<gid>:/' {} \;
find "${km}" -name "etc-gshadow" \
  -exec sed -i '' 's/<group>:\*::<members>/<group>:*::/' {} \;
```

If only some users are being removed from a group that retains other
members, adjust the sed pattern to remove just the target usernames from
the comma-separated list rather than clearing it entirely.

### Step 3 — Verify

```bash
grep -r "<group>" "${km}" --include="etc-group"
grep -r "<group>" "${km}" --include="etc-gshadow"
```

All affected overlays should show the group line with the users removed.
Confirm no unintended lines were changed (`git diff --stat`).

### Step 4 — No Key Vault changes needed

`etc-shadow` in Key Vault is per-user, not per-group. Changing group
membership does not require a Key Vault update.

---

## Case 2: Remove a user entirely from the SFTP system

Use this when the user should have no SFTP access at all across any study.
Applies to all overlays where the user appears.

### Step 1 — Inventory all occurrences

```bash
grep -rl "<username>" "${km}" --include="etc-passwd"
grep -r  "<username>" "${km}" --include="etc-group"
grep -r  "<username>" "${km}" --include="etc-gshadow"
grep -r  "<username>" "${km}" --include="humanHomedirs.yaml"
grep -r  "<username>" "${km}" --include="kustomization.yaml"
find "${km}" -path "*/ssh-public-keys/<username>"
```

### Step 2 — Edit each affected overlay

For each overlay returned above:

1. **`generators/etc-passwd`** — delete the user's line
2. **`generators/etc-group`** — remove the username from every group
   member list it appears in
3. **`generators/etc-gshadow`** — mirror the etc-group changes exactly
4. **`generators/ssh-public-keys/<username>`** — delete the file
5. **`kustomization.yaml`** — remove the
   `generators/ssh-public-keys/<username>` entry under `configMapGenerator`
6. **`patches/humanHomedirs.yaml`** — remove the user's volume mount stanza
   (the full `- op: add` block ending at their `mountPath`)

### Step 3 — Check and update Key Vault shadow entries

```bash
for vault in dev-configure dev-validate \
             test-configure test-validate test-my \
             platform-configure platform-validate platform-preview \
             staging-configure staging-validate staging-preview \
             vozni-prod-configure vozni-prod-accept vozni-prod-my; do
  result=$(az keyvault secret show \
    --vault-name "$vault" \
    --name sftp-etc-shadow \
    --query value -otsv 2>/dev/null \
    | grep -E "^<username>:")
  [ -n "$result" ] && echo "=== $vault ===" && echo "$result"
done
```

For each vault that prints a match, fetch the current secret, remove the
user's line, and write it back:

```bash
export vault="<vault-name>"
az keyvault secret show \
  --vault-name "$vault" \
  --name sftp-etc-shadow \
  --query value -otsv \
  | grep -v "^<username>:" > /tmp/shadow-updated

az keyvault secret set \
  --vault-name "$vault" \
  --name sftp-etc-shadow \
  --file /tmp/shadow-updated

rm /tmp/shadow-updated
```

Repeat for each affected vault.

### Step 4 — Verify build

```bash
for overlay in dev/configure dev/validate \
               test/configure test/validate test/my \
               platform/configure platform/validate platform/preview \
               staging/configure staging/validate staging/preview \
               prod/configure prod/accept prod/my; do
  kustomize build "${km}/${overlay}" > /dev/null && echo "OK: ${overlay}" \
    || echo "FAIL: ${overlay}"
done
```

---

## Case 3: Add a new human user

This is the reverse of Case 2. Collect:

- Unix username (derive from first initial + last name, lowercase)
- Email address and display name (for the GECOS field in etc-passwd)
- SSH public key
- UID (assign sequentially from the highest existing UID in `etc-passwd`;
  must be consistent across all overlays)
- Primary GID (`10000` for `korio-ro`, `10001` for `korio-rw`, or the
  sponsor's dedicated human group GID)
- Which study groups they need membership in
- Which environments/sub-environments are in scope

Then for each affected overlay, reverse the steps in Case 2: add the
passwd entry, add group memberships, add gshadow entries, place the SSH
key file, add it to `kustomization.yaml`, and add the home dir mount.

For the Key Vault `sftp-etc-shadow`, add a locked entry for the new user
(SSH-key-only users do not use password auth):

```bash
echo "<username>:!:$(date +%s / 86400 | bc):0:99999:7:::" >> /tmp/shadow
```

Then update the secret using the same `az keyvault secret set` pattern as
Case 2.

---

## After committing

The changes take effect when ArgoCD syncs and the sftp-server pod restarts
(init containers re-run on restart, rebuilding the ConfigMap-backed
`/etc/passwd`, `/etc/group`, and `/etc/gshadow` inside the pod). A restart
is not required for group-membership-only changes to revoke access — the
ConfigMap is remounted live — but a pod restart is needed if you want
`sftp-acl-init` to re-apply POSIX ACLs reflecting the new group state.
