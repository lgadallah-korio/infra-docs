#!/usr/bin/env bash
# validate-sftp-identity.sh
#
# Validates the Azure identity chain for an SFTP client service integration.
#
# Usage:
#   validate-sftp-identity.sh <serviceAccount> <workloadId> [<sponsor> <integration>]
#
# Arguments:
#   serviceAccount   serviceAccount value from identities.yaml
#                    e.g. staging-preview-moderna-icsf-consumer
#   workloadId       workloadId (UAMI Client ID) from identities.yaml
#   sponsor          Optional: sponsor slug, e.g. moderna
#   integration      Optional: integration slug, e.g. biostats
#
# If sponsor/integration are provided, check 4 lists all directories under
# {env}/{subenv}/{sponsor}/{integration} recursively, identifies the leaf
# directories (those created by korioctl azure dldp create), and checks the
# POSIX ACL on each one. If omitted, check 4 lists directories under
# {env}/{subenv} so you can identify the correct sponsor and integration.
#
# Dependencies: az, jq

set -uo pipefail

PASS="[PASS]"
FAIL="[FAIL]"
SKIP="[SKIP]"
INFO="[INFO]"

# Globals set by parse_args()
service_account=""
workload_id=""
sponsor=""
integration=""
kenv=""
sbenv=""
sftp_rg=""
storage_account=""

# Set by check_uami(); used by check_blob_storage() and check_dldp()
principal_id=""

# Updated to false by any check that fails
overall_pass=true

# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") <serviceAccount> <workloadId> [<sponsor> <integration>]

  serviceAccount   The service account name as recorded in identities.yaml,
                   e.g. staging-preview-moderna-icsf-consumer.
                   Used to look up the UAMI and derive env/subenv/resource group.

  workloadId       The workloadId value from identities.yaml for this service account
                   (a UUID). Check 1 verifies this matches the actual UAMI Client ID
                   in Azure -- a mismatch means identities.yaml is out of sync.
                   identities.yaml is at:
                     presto-besto-manifesto/{env}/presto_conf/.internal/{subenv}/identities.yaml

  sponsor          Optional: e.g. moderna
  integration      Optional: e.g. biostats
                   When provided, check 4 validates POSIX ACLs on all leaf directories
                   under {env}/{subenv}/{sponsor}/{integration} in the mirror storage.
EOF
    exit 1
}

parse_args() {
    [[ $# -lt 2 ]] && usage

    service_account="$1"
    workload_id="$2"
    sponsor="${3:-}"
    integration="${4:-}"

    # Derive env and subenv from service_account ({env}-{subenv}-{service-name})
    IFS='-' read -ra _parts <<< "$service_account"
    kenv="${_parts[0]}"
    sbenv="${_parts[1]}"
    sftp_rg="vozni-${kenv}-sftp-storage"
    storage_account="${kenv}sftpmirror"
}

print_header() {
    echo ""
    echo "SFTP identity chain validation"
    echo "  serviceAccount:  ${service_account}"
    echo "  workloadId:      ${workload_id}"
    echo "  env:             ${kenv}"
    echo "  subenv:          ${sbenv}"
    echo "  resource group:  ${sftp_rg}"
    echo "  storage account: ${storage_account}"
    if [[ -n "$sponsor" && -n "$integration" ]]; then
        echo "  integration:     ${kenv}/${sbenv}/${sponsor}/${integration}"
    fi
    echo ""
}

# Check 1: UAMI exists in the expected resource group and its Client ID matches
# the workloadId declared in identities.yaml. Sets principal_id for downstream checks.
check_uami() {
    echo "=== Check 1: UAMI exists and Client ID matches workloadId ==="

    local uami_json
    uami_json=$(az identity show \
        --name "$service_account" \
        -g "$sftp_rg" \
        --query '{clientId:clientId, principalId:principalId}' \
        -o json 2>/dev/null) || uami_json=""

    if [[ -z "$uami_json" ]]; then
        echo "$FAIL UAMI '$service_account' not found in '$sftp_rg'"
        overall_pass=false
    else
        local actual_client_id
        actual_client_id=$(echo "$uami_json" | jq -r '.clientId')
        principal_id=$(echo "$uami_json" | jq -r '.principalId')
        echo "$INFO Principal ID: $principal_id"
        if [[ "$actual_client_id" == "$workload_id" ]]; then
            echo "$PASS Client ID matches workloadId"
        else
            echo "$FAIL Client ID mismatch"
            echo "     identities.yaml workloadId: $workload_id"
            echo "     UAMI clientId:              $actual_client_id"
            overall_pass=false
        fi
    fi
    echo ""
}

# Check 2: A FIC exists on the UAMI whose subject matches the expected
# Kubernetes ServiceAccount in the correct namespace, and whose issuer matches
# the AKS cluster's OIDC issuer URL. A subject mismatch causes AADSTS70025; an
# issuer mismatch (e.g. prodaks vs prod-aks in the hostname) also causes
# AADSTS70025 and is not caught by checking the subject alone.
check_fic() {
    echo "=== Check 2: FIC exists with correct subject and issuer ==="

    local expected_subject="system:serviceaccount:${sbenv}:${service_account}"
    local fic_list
    fic_list=$(az identity federated-credential list \
        --identity-name "$service_account" \
        -g "$sftp_rg" \
        -o json 2>/dev/null) || fic_list="[]"

    local fic_count
    fic_count=$(echo "$fic_list" | jq 'length')

    if [[ "$fic_count" -eq 0 ]]; then
        echo "$FAIL No FICs configured -- pod will fail with AADSTS70025"
        overall_pass=false
        echo ""
        return
    fi

    echo "$PASS $fic_count FIC(s) found"

    local matching
    matching=$(echo "$fic_list" | \
        jq -r --arg s "$expected_subject" '[.[] | select(.subject == $s)] | length')

    if [[ "$matching" -gt 0 ]]; then
        local actual_issuer
        actual_issuer=$(echo "$fic_list" | \
            jq -r --arg s "$expected_subject" '.[] | select(.subject == $s) | .issuer')
        echo "$PASS Subject matches: $expected_subject"

        # Validate the issuer against the AKS cluster's OIDC issuer URL.
        # A FIC created with a malformed issuer (e.g. prodaks.azure.com instead of
        # prod-aks.azure.com) is accepted by Azure but fails at token exchange time.
        local expected_issuer
        expected_issuer=$(az aks show \
            -g "vozni-${kenv}-rg" \
            --name "vozni-${kenv}-aks" \
            --query "oidcIssuerProfile.issuerUrl" \
            -otsv 2>/dev/null) || expected_issuer=""

        if [[ -z "$expected_issuer" ]]; then
            echo "$INFO Issuer: $actual_issuer"
            echo "$INFO Could not retrieve AKS OIDC issuer URL -- skipping issuer check"
        else
            # Normalize trailing slash before comparing
            local norm_actual="${actual_issuer%/}"
            local norm_expected="${expected_issuer%/}"
            if [[ "$norm_actual" == "$norm_expected" ]]; then
                echo "$PASS Issuer matches AKS OIDC URL: $actual_issuer"
            else
                echo "$FAIL Issuer mismatch -- pod will fail with AADSTS70025"
                echo "     FIC issuer:   $actual_issuer"
                echo "     AKS OIDC URL: $expected_issuer"
                overall_pass=false
            fi
        fi
    else
        echo "$FAIL No FIC with expected subject: $expected_subject"
        echo "$INFO Actual subject(s):"
        echo "$fic_list" | jq -r '.[].subject' | while read -r s; do
            echo "     $s"
        done
        overall_pass=false
    fi
    echo ""
}

# Check 3: Report RBAC role assignments on the mirror storage account for this principal.
# This check is informational only -- client services may rely on DLDP POSIX ACLs
# alone for data-plane access (ADLS2 HNS supports ACL-only OAuth2 access). Check 4
# is the definitive test of whether the service can reach its integration path.
check_blob_storage() {
    echo "=== Check 3: RBAC role assignments on ${storage_account} (informational) ==="

    if [[ -z "$principal_id" ]]; then
        echo "$SKIP Skipped -- UAMI not found in check 1"
        echo ""
        return
    fi

    local assignments
    assignments=$(az role assignment list \
        --assignee "$principal_id" \
        --query "[].{Role:roleDefinitionName, Scope:scope}" \
        -o json 2>/dev/null) || assignments="[]"

    local count
    count=$(echo "$assignments" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "$INFO No RBAC role assignments found for this principal"
        echo "$INFO Access may be granted via DLDP POSIX ACLs alone -- see check 4"
    else
        local contributor_count
        contributor_count=$(echo "$assignments" | \
            jq -r --arg sa "$storage_account" \
            '[.[] | select(
                (.Role == "Storage Blob Data Contributor" or .Role == "Storage Blob Data Owner")
                and (.Scope | contains($sa))
             )] | length')

        if [[ "$contributor_count" -gt 0 ]]; then
            echo "$PASS Storage Blob Data Contributor/Owner assigned on ${storage_account}"
        else
            echo "$INFO Role assignments found but none match Storage Blob Data Contributor on ${storage_account}:"
            echo "$assignments" | jq -r '.[] | "     \(.Role)  \(.Scope)"'
            echo "$INFO Access may be granted via DLDP POSIX ACLs alone -- see check 4"
        fi
    fi
    echo ""
}

# Check the POSIX ACL on a single directory path: verify the UAMI's Principal ID
# appears as a named entry and that the owner entry (user::) has write permission.
_check_path_acl() {
    local path="$1"

    echo "$INFO --- ${path} ---"

    local acl_json
    acl_json=$(az storage fs access show \
        --account-name "$storage_account" \
        --file-system mirror \
        --path "$path" \
        --auth-mode login \
        -o json 2>/dev/null) || acl_json=""

    if [[ -z "$acl_json" ]]; then
        echo "$FAIL Path not found: ${path} in ${storage_account}/mirror"
        overall_pass=false
        return
    fi

    local acl
    acl=$(echo "$acl_json" | jq -r '.acl')
    echo "$INFO ACL: $acl"

    if echo "$acl" | grep -q "$principal_id"; then
        echo "$PASS Principal ID found in ACL"
    else
        echo "$FAIL Principal ID ${principal_id} not found in ACL"
        overall_pass=false
    fi

    # Check that the owner ACL entry (user::) has write permission.
    # If the directory was created by a service running as this UAMI, that service
    # is the directory owner, and POSIX ACL semantics apply user:: (not any named
    # user entry) when the owner accesses the path. A missing write bit on user::
    # therefore prevents the owning service from writing even if a named
    # user:<principalId>:rwx entry is present.
    local owner_perms
    owner_perms=$(echo "$acl" | tr ',' '\n' | grep '^user::' | cut -d: -f3)
    if [[ -z "$owner_perms" ]]; then
        echo "$INFO Could not parse owner (user::) entry from ACL"
    elif [[ "$owner_perms" == *w* ]]; then
        echo "$PASS Owner ACL (user::) has write permission: ${owner_perms}"
    else
        echo "$FAIL Owner ACL (user::) missing write permission: ${owner_perms}"
        echo "     The owning principal cannot write to this path."
        echo "     Reset the ACL with korioctl azure dldp create using user::rwx."
        overall_pass=false
    fi
}

# Check 4: Discover all leaf directories under {env}/{subenv}/{sponsor}/{integration}
# and verify the POSIX ACL on each. Leaf directories are those created by
# korioctl azure dldp create and carry the named user/group ACL entries; parent
# directories above them carry only the base user::/group::/other:: entries.
# If sponsor/integration are omitted, lists directories under {env}/{subenv} instead.
check_dldp() {
    echo "=== Check 4: DLDP leaf directories and ACLs ==="

    if [[ -z "$sponsor" || -z "$integration" ]]; then
        echo "$SKIP Sponsor/integration not provided -- listing directories under ${kenv}/${sbenv}:"
        az storage fs directory list \
            --account-name "$storage_account" \
            --file-system mirror \
            --path "${kenv}/${sbenv}" \
            --auth-mode login \
            --query "[].name" \
            -o table 2>/dev/null || echo "     (path does not exist or access denied)"
        echo ""
        return
    fi

    if [[ -z "$principal_id" ]]; then
        echo "$SKIP Skipped -- UAMI not found in check 1"
        echo ""
        return
    fi

    local integration_path="${kenv}/${sbenv}/${sponsor}/${integration}"

    # List all directories under the integration path recursively.
    local all_dirs
    all_dirs=$(az storage fs directory list \
        --account-name "$storage_account" \
        --file-system mirror \
        --path "$integration_path" \
        --auth-mode login \
        --query "[].name" \
        -o json 2>/dev/null) || all_dirs="[]"

    # Identify leaf directories: those not appearing as a prefix of any other
    # directory in the list. These are the paths korioctl azure dldp create
    # was run on and where named ACL entries are expected.
    # If no subdirectories exist, fall back to checking the integration root itself.
    local check_paths
    if [[ "$all_dirs" == "[]" || "$all_dirs" == "null" ]]; then
        echo "$INFO No subdirectories found -- checking integration root: ${integration_path}"
        check_paths="$integration_path"
    else
        check_paths=$(echo "$all_dirs" | jq -r \
            '[.[] as $d | select([.[] | select(startswith($d + "/"))] | length == 0) | $d] | .[]')
    fi

    if [[ -z "$check_paths" ]]; then
        echo "$INFO Could not determine leaf directories -- no ACL checks performed"
        echo ""
        return
    fi

    echo "$INFO Leaf directories found:"
    while read -r p; do echo "     $p"; done <<< "$check_paths"
    echo ""

    while read -r path; do
        _check_path_acl "$path"
    done <<< "$check_paths"
    echo ""
}

summarize() {
    if $overall_pass; then
        echo "Result: PASS -- all checks passed"
    else
        echo "Result: FAIL -- one or more checks failed"
        exit 1
    fi
}

main() {
    parse_args "$@"
    print_header
    check_uami
    check_fic
    check_blob_storage
    check_dldp
    summarize
}

main "$@"
