#!/usr/bin/env bash
# check-subenv-config.sh
#
# Runs the checks from validate-subenv-config.md for a given env/sub-env pair
# and reports PASS/FAIL/SKIP/INFO for each one.
#
# Usage:
#   check-subenv-config.sh [OPTIONS] <kenv> <sbenv>
#
# Arguments:
#   kenv     environment name  (dev | test | staging | prod | ...)
#   sbenv    sub-environment   (configure | validate | accept | my | preview)
#
# Options:
#   --repos-root <path>   parent directory containing presto-besto-manifesto,
#                         argocd, and kubernetes-manifests repo clones
#                         (default: current working directory)
#   --sibling <sbenv>     sibling sub-env to diff ConfigMaps against
#                         (default: configure)
#   --skip-azure          skip Part B Azure checks (no az login required)
#   --skip-runtime        skip Part C runtime checks (no kubectl required)
#   --context <name>      kubectl context name (default: kenv value)
#
# Checks 1-7  (Part A) require only local repo clones.
# Checks 8-11 (Part B) require an authenticated az session on the kenv subscription.
# Checks 12-13 (Part C) require kubectl access to the kenv cluster via Twingate.
#
# Dependencies: jq (Part B), az (Part B), kubectl (Part C)

set -uo pipefail

PASS="[PASS]"
FAIL="[FAIL]"
SKIP="[SKIP]"
INFO="[INFO]"

# Globals set by parse_args()
kenv=""
sbenv=""
sibling="configure"
repos_root="."
skip_azure=false
skip_runtime=false
kubectl_context=""
sftp_rg=""
storage_account=""

# Updated to false by any check that fails
overall_pass=true

# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <kenv> <sbenv>

  kenv     environment name  (dev | test | staging | prod | ...)
  sbenv    sub-environment   (configure | validate | accept | my | preview)

Options:
  --repos-root <path>   parent directory containing repo clones (default: .)
  --sibling <sbenv>     sibling sub-env for ConfigMap comparison (default: configure)
  --skip-azure          skip Part B Azure checks
  --skip-runtime        skip Part C runtime checks
  --context <name>      kubectl context name (default: kenv value)
EOF
    exit 1
}

parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repos-root)   repos_root="$2";       shift 2 ;;
            --sibling)      sibling="$2";           shift 2 ;;
            --skip-azure)   skip_azure=true;        shift   ;;
            --skip-runtime) skip_runtime=true;      shift   ;;
            --context)      kubectl_context="$2";   shift 2 ;;
            --)             shift; positional+=("$@"); break ;;
            -*)             echo "Unknown option: $1" >&2; usage ;;
            *)              positional+=("$1"); shift ;;
        esac
    done
    [[ ${#positional[@]} -lt 2 ]] && usage
    kenv="${positional[0]}"
    sbenv="${positional[1]}"
    [[ -z "$kubectl_context" ]] && kubectl_context="$kenv"
    sftp_rg="vozni-${kenv}-sftp-storage"
    storage_account="${kenv}sftpmirror"
}

print_header() {
    echo ""
    echo "Sub-environment configuration check"
    echo "  env:          ${kenv}"
    echo "  subenv:       ${sbenv}"
    echo "  sibling:      ${sibling}"
    echo "  repos root:   ${repos_root}"
    echo "  skip-azure:   ${skip_azure}"
    echo "  skip-runtime: ${skip_runtime}"
    echo ""
}

# ---------------------------------------------------------------------------
# Part A: Repo checks
# ---------------------------------------------------------------------------

# A1: subenvironments.yaml includes sbenv. If missing, no AppSets will be
# generated for this sub-env and all downstream checks will fail.
check_a1_subenvironments() {
    echo "=== A1: ${sbenv} in presto-besto-manifesto subenvironments.yaml ==="
    local file="${repos_root}/presto-besto-manifesto/${kenv}/subenvironments.yaml"
    if [[ ! -f "$file" ]]; then
        echo "$FAIL File not found: ${file}"
        overall_pass=false
        echo ""
        return
    fi
    if grep -qw "${sbenv}" "$file"; then
        echo "$PASS ${sbenv} found in subenvironments.yaml"
    else
        echo "$FAIL ${sbenv} not in subenvironments.yaml -- no AppSets will be generated"
        echo "     Fix: add '- ${sbenv}', open PR, let Dagger pipeline run, merge argocd PR (Phase 3a)"
        overall_pass=false
    fi
    echo ""
}

# A2: identities.yaml exists and contains the three required service entries.
check_a2_identities() {
    echo "=== A2: identities.yaml exists with required service entries ==="
    local file="${repos_root}/presto-besto-manifesto/${kenv}/presto_conf/.internal/${sbenv}/identities.yaml"
    if [[ ! -f "$file" ]]; then
        echo "$FAIL File not found: ${file}"
        echo "     Fix: create identities.yaml for ${kenv}-${sbenv} (Phase 3b)"
        overall_pass=false
        echo ""
        return
    fi
    echo "$PASS File exists: ${file}"
    for svc in int-biostats-node int-nest-node int-nest-node-v1.0.0; do
        if grep -q "$svc" "$file"; then
            echo "$PASS Entry found: ${svc}"
        else
            echo "$FAIL Entry missing: ${svc}"
            overall_pass=false
        fi
    done
    echo ""
}

# A3: envfrom ConfigMap file set in argocd/apps/${kenv}/${sbenv}/ matches the
# sibling sub-env. Files present in sibling but absent in sbenv will cause
# AppSet sync failures.
check_a3_configmaps() {
    echo "=== A3: argocd envfrom ConfigMaps match sibling (${sibling}) ==="
    local sbenv_dir="${repos_root}/argocd/apps/${kenv}/${sbenv}"
    local sibling_dir="${repos_root}/argocd/apps/${kenv}/${sibling}"
    if [[ ! -d "$sbenv_dir" ]]; then
        echo "$FAIL Directory not found: ${sbenv_dir}"
        overall_pass=false
        echo ""
        return
    fi
    if [[ ! -d "$sibling_dir" ]]; then
        echo "$FAIL Sibling directory not found: ${sibling_dir}"
        overall_pass=false
        echo ""
        return
    fi
    local diff_out
    diff_out=$(diff \
        <(find "$sbenv_dir"   -maxdepth 1 -type f -exec basename {} \; | sort) \
        <(find "$sibling_dir" -maxdepth 1 -type f -exec basename {} \; | sort) 2>&1 || true)
    if [[ -z "$diff_out" ]]; then
        echo "$PASS File sets match sibling"
    else
        local missing extra
        missing=$(echo "$diff_out" | grep '^>' | sed 's/^> //' || true)
        extra=$(echo "$diff_out"   | grep '^<' | sed 's/^< //' || true)
        if [[ -n "$missing" ]]; then
            echo "$FAIL Files in sibling but missing from ${sbenv} (will cause sync failures):"
            while read -r f; do echo "     > $f"; done <<< "$missing"
            echo "     Fix: copy missing files from sibling and substitute sub-env values (Phase 4b)"
            overall_pass=false
        fi
        if [[ -n "$extra" ]]; then
            echo "$INFO Files in ${sbenv} not present in sibling (unexpected extras):"
            while read -r f; do echo "     < $f"; done <<< "$extra"
        fi
    fi
    echo ""
}

# A4: sftp-server.yaml includes sbenv. If absent, the SFTP server will not be
# deployed to this sub-env.
check_a4_sftp_server() {
    echo "=== A4: sftp-server.yaml includes ${sbenv} ==="
    local file="${repos_root}/argocd/apps/${kenv}/sftp-server.yaml"
    if [[ ! -f "$file" ]]; then
        echo "$FAIL File not found: ${file}"
        overall_pass=false
        echo ""
        return
    fi
    if grep -q "subenv: ${sbenv}" "$file"; then
        echo "$PASS subenv: ${sbenv} found in sftp-server.yaml"
    else
        echo "$FAIL subenv: ${sbenv} not in sftp-server.yaml"
        echo "     Fix: add entry (Phase 4a); kubernetes-manifests overlay (A6) must be merged first"
        overall_pass=false
    fi
    echo ""
}

# A5: all *-appset.yaml files in argocd/apps/${kenv}/ include sbenv as a
# generator entry. Any file listed here will not deploy that service to sbenv.
check_a5_appsets() {
    echo "=== A5: all AppSets include ${sbenv} ==="
    local appsets_dir="${repos_root}/argocd/apps/${kenv}"
    if [[ ! -d "$appsets_dir" ]]; then
        echo "$FAIL Directory not found: ${appsets_dir}"
        overall_pass=false
        echo ""
        return
    fi
    local total
    total=$(find "${appsets_dir}" -maxdepth 1 -name '*-appset.yaml' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$total" -eq 0 ]]; then
        echo "$SKIP No *-appset.yaml files found in ${appsets_dir}"
        echo ""
        return
    fi
    local missing_list
    missing_list=$(grep -rL "subenv: ${sbenv}" "${appsets_dir}"/*-appset.yaml 2>/dev/null || true)
    if [[ -z "$missing_list" ]]; then
        echo "$PASS All ${total} AppSet(s) include subenv: ${sbenv}"
    else
        local missing_count
        missing_count=$(echo "$missing_list" | wc -l | tr -d ' ')
        local included=$((total - missing_count))
        echo "$FAIL ${missing_count}/${total} AppSet(s) do NOT include ${sbenv} (${included} do)"
        echo "$INFO Missing AppSets (first 10):"
        echo "$missing_list" | head -10 | while read -r f; do echo "     $(basename "$f")"; done
        echo "     Fix: find and merge the auto-generated 'Enable ${kenv}-${sbenv}' argocd PR"
        overall_pass=false
    fi
    echo ""
}

# A6: kubernetes-manifests SFTP Kustomize overlay directory exists for sbenv.
# Required before sftp-server.yaml (A4) can safely be updated.
check_a6_kustomize() {
    echo "=== A6: kubernetes-manifests SFTP Kustomize overlay exists ==="
    local overlay_dir="${repos_root}/kubernetes-manifests/kustomize/sftp-server/overlays/${kenv}/${sbenv}"
    if [[ ! -d "$overlay_dir" ]]; then
        echo "$FAIL Overlay directory not found: ${overlay_dir}"
        echo "     Fix: create SFTP Kustomize overlay (Phase 5)"
        overall_pass=false
        echo ""
        return
    fi
    echo "$PASS Overlay directory exists"
    for item in kustomization.yaml patches generators; do
        if [[ -e "${overlay_dir}/${item}" ]]; then
            echo "$PASS   ${item} present"
        else
            echo "$FAIL   ${item} missing"
            overall_pass=false
        fi
    done
    echo ""
}

# A7: no stray sibling references left in the SFTP overlay (would indicate an
# incomplete substitution during setup).
check_a7_stray_refs() {
    echo "=== A7: no stray '${sibling}' references in SFTP overlay ==="
    local overlay_dir="${repos_root}/kubernetes-manifests/kustomize/sftp-server/overlays/${kenv}/${sbenv}"
    if [[ ! -d "$overlay_dir" ]]; then
        echo "$SKIP Overlay directory not found -- skipping (see A6)"
        echo ""
        return
    fi
    local hits
    hits=$(grep -r "${sibling}" "$overlay_dir" --include="*.yaml" | grep -v generators || true)
    if [[ -z "$hits" ]]; then
        echo "$PASS No stray '${sibling}' references found"
    else
        echo "$FAIL Stray '${sibling}' references found (overlay not fully substituted):"
        while read -r line; do echo "     $line"; done <<< "$hits"
        echo "     Fix: re-run the perl substitution script on the files shown (Phase 5b)"
        overall_pass=false
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Part B: Azure checks
# ---------------------------------------------------------------------------

# Returns the Key Vault name for the given env/subenv pair, mirroring the
# naming logic in terraform-infra/env/azure_key_vault.tf:
#   prod / prod3 / staging3  ->  "vozni-{env}-{subenv}"
#   all other envs           ->  "{env}-{subenv}"
# NOTE: staging is missing from the prod-like set in Terraform (known oversight).
# This function intentionally reflects the current actual naming, not the desired one.
kv_name() {
    local env="$1" subenv="$2"
    case "$env" in
        prod|prod3|staging3) echo "vozni-${env}-${subenv}" ;;
        *)                   echo "vozni-${env}" ;;
    esac
}

# B1: Key Vault, SFTP managed disk, and SFTP public IP provisioned by Terraform.
# All three should exist if the sub-env appears in terraform-infra locals.tf.
check_b1_terraform() {
    echo "=== B1: Terraform-provisioned Azure resources ==="

    local kv
    kv=$(kv_name "$kenv" "$sbenv")
    local kv_state
    kv_state=$(az keyvault show \
        --name "$kv" \
        --query "properties.provisioningState" -o tsv 2>/dev/null) || kv_state=""
    if [[ "$kv_state" == "Succeeded" ]]; then
        echo "$PASS Key Vault ${kv}: ${kv_state}"
    else
        echo "$FAIL Key Vault ${kv} not found or not provisioned (got: '${kv_state}')"
        echo "     Fix: add ${sbenv} to terraform-infra locals.tf and apply"
        overall_pass=false
    fi

    local disk_state
    disk_state=$(az disk show \
        --resource-group "vozni-${kenv}-aks-rg" \
        --name "vozni-${kenv}-${sbenv}-sftp" \
        --query "provisioningState" -o tsv 2>/dev/null) || disk_state=""
    if [[ "$disk_state" == "Succeeded" ]]; then
        echo "$PASS SFTP managed disk vozni-${kenv}-${sbenv}-sftp: ${disk_state}"
    else
        echo "$FAIL SFTP managed disk vozni-${kenv}-${sbenv}-sftp not found (got: '${disk_state}')"
        overall_pass=false
    fi

    local ip_json ip_state sftp_ip
    ip_json=$(az network public-ip show \
        --resource-group "vozni-${kenv}-aks-rg" \
        --name "vozni-${kenv}-${sbenv}-sftp" \
        --query "{state:provisioningState, ip:ipAddress}" -o json 2>/dev/null) || ip_json=""
    if [[ -n "$ip_json" ]]; then
        ip_state=$(echo "$ip_json" | jq -r '.state')
        sftp_ip=$(echo "$ip_json"  | jq -r '.ip')
        if [[ "$ip_state" == "Succeeded" ]]; then
            echo "$PASS SFTP public IP vozni-${kenv}-${sbenv}-sftp: ${ip_state} (${sftp_ip})"
        else
            echo "$FAIL SFTP public IP vozni-${kenv}-${sbenv}-sftp not ready (state: ${ip_state})"
            overall_pass=false
        fi
    else
        echo "$FAIL SFTP public IP vozni-${kenv}-${sbenv}-sftp not found"
        overall_pass=false
    fi
    echo ""
}

# B2: UAMI list. sftp-server is Terraform-managed; int-biostats-node and
# int-nest-node are created manually per the enable runbook.
check_b2_uamis() {
    echo "=== B2: Workload identity UAMIs ==="
    local uami_json
    uami_json=$(az identity list -g "${sftp_rg}" \
        --query "[?starts_with(name, '${kenv}-${sbenv}-')].{Name:name, ClientID:clientId, PrincipalID:principalId}" \
        -o json 2>/dev/null) || uami_json="[]"

    local count
    count=$(echo "$uami_json" | jq 'length')
    echo "$INFO ${count} UAMI(s) found with prefix '${kenv}-${sbenv}-'"

    for required in sftp-server int-biostats-node int-nest-node; do
        local full_name="${kenv}-${sbenv}-${required}"
        local found
        found=$(echo "$uami_json" | jq -r --arg n "$full_name" \
            '[.[] | select(.Name == $n)] | length')
        if [[ "$found" -gt 0 ]]; then
            local client_id principal_id
            client_id=$(echo "$uami_json"  | jq -r --arg n "$full_name" '.[] | select(.Name == $n) | .ClientID')
            principal_id=$(echo "$uami_json" | jq -r --arg n "$full_name" '.[] | select(.Name == $n) | .PrincipalID')
            echo "$PASS ${full_name}"
            echo "$INFO       clientId:    ${client_id}"
            echo "$INFO       principalId: ${principal_id}"
        else
            echo "$FAIL ${full_name} not found"
            if [[ "$required" == "sftp-server" ]]; then
                echo "     Fix: apply Terraform (sftp-server UAMI is Terraform-managed)"
            else
                echo "     Fix: create UAMI manually (Phase 2a)"
            fi
            overall_pass=false
        fi
    done
    echo ""
}

# B3: Federated Identity Credentials on int-biostats-node (expect 1) and
# int-nest-node (expect 2, one for each service account including v1.0.0).
check_b3_fics() {
    echo "=== B3: Federated Identity Credentials ==="

    # int-biostats-node: expect exactly one FIC
    local biostats_name="${kenv}-${sbenv}-int-biostats-node"
    local expected_biostats="system:serviceaccount:${sbenv}:${biostats_name}"
    local biostats_fics
    biostats_fics=$(az identity federated-credential list \
        --identity-name "$biostats_name" \
        --resource-group "$sftp_rg" \
        --query "[].subject" -o json 2>/dev/null) || biostats_fics="[]"
    local biostats_count
    biostats_count=$(echo "$biostats_fics" | jq 'length')
    if [[ "$biostats_count" -eq 0 ]]; then
        echo "$FAIL ${biostats_name}: no FICs configured"
        echo "     Fix: create FIC with subject ${expected_biostats} (Phase 2b)"
        overall_pass=false
    else
        local match
        match=$(echo "$biostats_fics" | jq -r --arg s "$expected_biostats" \
            '[.[] | select(. == $s)] | length')
        if [[ "$match" -gt 0 ]]; then
            echo "$PASS ${biostats_name}: FIC subject correct"
        else
            echo "$FAIL ${biostats_name}: FIC subject mismatch"
            echo "     Expected: ${expected_biostats}"
            echo "$INFO Actual:   $(echo "$biostats_fics" | jq -r '.[]')"
            overall_pass=false
        fi
    fi

    # int-nest-node: expect exactly two FICs (one per service account)
    local nest_name="${kenv}-${sbenv}-int-nest-node"
    local nest_fics
    nest_fics=$(az identity federated-credential list \
        --identity-name "$nest_name" \
        --resource-group "$sftp_rg" \
        --query "[].subject" -o json 2>/dev/null) || nest_fics="[]"
    local nest_count
    nest_count=$(echo "$nest_fics" | jq 'length')
    if [[ "$nest_count" -eq 0 ]]; then
        echo "$FAIL ${nest_name}: no FICs configured"
        echo "     Fix: create two FICs (Phase 2b)"
        overall_pass=false
    else
        for expected_subject in \
            "system:serviceaccount:${sbenv}:${nest_name}" \
            "system:serviceaccount:${sbenv}:${kenv}-${sbenv}-int-nest-node-v1-0-0"
        do
            local match
            match=$(echo "$nest_fics" | jq -r --arg s "$expected_subject" \
                '[.[] | select(. == $s)] | length')
            if [[ "$match" -gt 0 ]]; then
                echo "$PASS ${nest_name}: FIC correct: ${expected_subject}"
            else
                echo "$FAIL ${nest_name}: FIC missing for subject: ${expected_subject}"
                overall_pass=false
            fi
        done
    fi
    echo ""
}

# B4: DLDP paths exist under {kenv}/{sbenv} in the mirror storage account.
# Missing paths cause sftp-data-sync to fail silently.
check_b4_dldp() {
    echo "=== B4: DLDP paths under ${kenv}/${sbenv} in ${storage_account}/mirror ==="
    local dirs
    dirs=$(az storage fs directory list \
        --account-name "${storage_account}" \
        --file-system mirror \
        --path "${kenv}/${sbenv}" \
        --auth-mode login \
        --query "[].name" -o tsv 2>/dev/null) || dirs=""
    if [[ -z "$dirs" ]]; then
        echo "$FAIL No paths found under ${kenv}/${sbenv} in ${storage_account}/mirror"
        echo "     Fix: create DLDP paths with korioctl azure dldp create (Phase 2c)"
        overall_pass=false
    else
        local count
        count=$(echo "$dirs" | wc -l | tr -d ' ')
        echo "$PASS ${count} path(s) found:"
        while read -r d; do echo "     ${d}"; done <<< "$dirs"
        echo "$INFO Cross-check against SFTP overlay patches for missing integrations"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Part C: Runtime checks
# ---------------------------------------------------------------------------

# C1: The namespace must pre-exist; all AppSets use CreateNamespace=false.
check_c1_namespace() {
    echo "=== C1: Kubernetes namespace '${sbenv}' exists ==="
    local ns_status
    ns_status=$(kubectl get namespace "${sbenv}" --context "${kubectl_context}" \
        -o jsonpath='{.status.phase}' 2>/dev/null) || ns_status=""
    if [[ "$ns_status" == "Active" ]]; then
        echo "$PASS Namespace '${sbenv}' is Active"
    elif [[ -z "$ns_status" ]]; then
        echo "$FAIL Namespace '${sbenv}' not found"
        echo "     Fix: kubectl create namespace ${sbenv} --context ${kubectl_context}"
        overall_pass=false
    else
        echo "$FAIL Namespace '${sbenv}' found but status is: ${ns_status}"
        overall_pass=false
    fi
    echo ""
}

# C2: ArgoCD application health for all apps targeting the sbenv namespace.
# Prints per-app sync/health status and a summary. For individual app diagnosis
# run check-argocd-sync.sh.
check_c2_argocd() {
    echo "=== C2: ArgoCD application health in namespace '${sbenv}' ==="
    local apps
    apps=$(kubectl get applications -n argocd --context "${kubectl_context}" \
        -o json 2>/dev/null) || apps=""
    if [[ -z "$apps" ]]; then
        echo "$SKIP Could not retrieve ArgoCD applications -- check kubectl context and Twingate"
        echo ""
        return
    fi

    local total
    total=$(echo "$apps" | jq -r --arg ns "$sbenv" \
        '[.items[] | select(.spec.destination.namespace == $ns)] | length')
    if [[ "$total" -eq 0 ]]; then
        echo "$FAIL No ArgoCD applications found targeting namespace '${sbenv}'"
        echo "     Check A1 and A5: sub-env may not be activated in the pipeline"
        overall_pass=false
        echo ""
        return
    fi

    local synced_healthy
    synced_healthy=$(echo "$apps" | jq -r --arg ns "$sbenv" \
        '[.items[] | select(
            .spec.destination.namespace == $ns and
            .status.sync.status == "Synced" and
            .status.health.status == "Healthy"
        )] | length')
    local not_ok=$((total - synced_healthy))

    if [[ "$not_ok" -eq 0 ]]; then
        echo "$PASS All ${total} application(s) are Synced + Healthy"
    else
        echo "$FAIL ${not_ok}/${total} application(s) are NOT Synced + Healthy:"
        echo "$apps" | jq -r --arg ns "$sbenv" \
            '.items[] | select(
                .spec.destination.namespace == $ns and
                (.status.sync.status != "Synced" or .status.health.status != "Healthy")
             ) | "     \(.metadata.name)  sync=\(.status.sync.status)  health=\(.status.health.status)"'
        echo ""
        echo "| Symptom | Likely cause | Fix |"
        echo "|---|---|---|"
        echo "| No apps visible at all | Sub-env missing from subenvironments.yaml | Check A1 |"
        echo "| ComparisonError on sftp-server-${sbenv} | SFTP Kustomize overlay missing | Check A6 |"
        echo "| OutOfSync on any app | AppSet generator missing ${sbenv} | Check A5 |"
        echo "| Missing resource | Namespace doesn't exist | Check C1 |"
        echo "| Degraded pod | Workload identity failure (UAMI/FIC) | Check B2, B3 |"
        echo "| Progressing / pods Pending | Cluster out of resources | check-argocd-sync.sh Phase 4 |"
        echo "| Degraded with ImagePullBackOff | Image tag missing or incorrect | check-argocd-sync.sh Phase 5 |"
        echo "     Run: check-argocd-sync.sh ${kenv} ${sbenv} <service-name> for per-app details"
        overall_pass=false
    fi
    echo ""
}

# ---------------------------------------------------------------------------

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

    check_a1_subenvironments
    check_a2_identities
    check_a3_configmaps
    check_a4_sftp_server
    check_a5_appsets
    check_a6_kustomize
    check_a7_stray_refs

    if $skip_azure; then
        echo "=== Part B: Azure checks SKIPPED (--skip-azure) ==="
        echo ""
    else
        check_b1_terraform
        check_b2_uamis
        check_b3_fics
        check_b4_dldp
    fi

    if $skip_runtime; then
        echo "=== Part C: Runtime checks SKIPPED (--skip-runtime) ==="
        echo ""
    else
        check_c1_namespace
        check_c2_argocd
    fi

    summarize
}

main "$@"
