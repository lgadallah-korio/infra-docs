#!/usr/bin/env bash
# check-argocd-sync.sh
#
# Diagnoses ArgoCD sync failures for a specific service in a given env/sub-env.
# Corresponds to argocd-sync-failures.md. Runs Phase 0 and repo checks without
# any login; runtime checks require kubectl access to the kenv cluster.
#
# Usage:
#   check-argocd-sync.sh [OPTIONS] <kenv> <sbenv> <service>
#
# Arguments:
#   kenv     environment name  (dev | test | staging | prod | ...)
#   sbenv    sub-environment   (configure | validate | accept | my | preview)
#   service  service name matching AppSet metadata.name, e.g. int-nest-node
#
# Options:
#   --repos-root <path>   parent directory containing presto-besto-manifesto
#                         and argocd repo clones (default: current working directory)
#   --context <name>      kubectl context name (default: kenv value)
#   --skip-runtime        skip runtime checks (no kubectl required)
#
# Repo checks cover Phase 0 (subenvironments.yaml) and the AppSet file.
# Runtime checks cover app sync/health status, ExternalSecrets, and pod events
# (Phases 1-5 of the runbook).
#
# Dependencies: kubectl (runtime checks), jq (runtime checks)

set -uo pipefail

PASS="[PASS]"
FAIL="[FAIL]"
SKIP="[SKIP]"
INFO="[INFO]"
WARN="[WARN]"

# Globals set by parse_args()
kenv=""
sbenv=""
svc=""
repos_root="."
kubectl_context=""
skip_runtime=false
app_name=""      # derived: ${svc}-${sbenv}
appset_file=""   # derived

# Updated to false by any check that fails
overall_pass=true

# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <kenv> <sbenv> <service>

  kenv     environment name  (dev | test | staging | prod | ...)
  sbenv    sub-environment   (configure | validate | accept | my | preview)
  service  service name, e.g. int-nest-node

Options:
  --repos-root <path>   parent directory containing repo clones (default: .)
  --context <name>      kubectl context name (default: kenv value)
  --skip-runtime        skip runtime checks (no kubectl required)
EOF
    exit 1
}

parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repos-root)   repos_root="$2";       shift 2 ;;
            --context)      kubectl_context="$2";   shift 2 ;;
            --skip-runtime) skip_runtime=true;      shift   ;;
            --)             shift; positional+=("$@"); break ;;
            -*)             echo "Unknown option: $1" >&2; usage ;;
            *)              positional+=("$1"); shift ;;
        esac
    done
    [[ ${#positional[@]} -lt 3 ]] && usage
    kenv="${positional[0]}"
    sbenv="${positional[1]}"
    svc="${positional[2]}"
    [[ -z "$kubectl_context" ]] && kubectl_context="$kenv"
    app_name="${svc}-${sbenv}"
    appset_file="${repos_root}/argocd/apps/${kenv}/${svc}-appset.yaml"
}

print_header() {
    echo ""
    echo "ArgoCD sync failure diagnosis"
    echo "  env:          ${kenv}"
    echo "  subenv:       ${sbenv}"
    echo "  service:      ${svc}"
    echo "  app name:     ${app_name}"
    echo "  appset:       ${appset_file}"
    echo "  repos root:   ${repos_root}"
    echo "  skip-runtime: ${skip_runtime}"
    echo ""
}

# ---------------------------------------------------------------------------
# Repo checks
# ---------------------------------------------------------------------------

# Phase 0: subenvironments.yaml pre-check. If sbenv is absent, no ArgoCD
# Applications will exist for it and all downstream symptoms follow from this.
check_phase0_subenvironments() {
    echo "=== Phase 0: ${sbenv} registered in subenvironments.yaml ==="
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
        echo "$FAIL ${sbenv} not in subenvironments.yaml"
        echo "     No ArgoCD Applications will exist for this sub-env until it is added"
        echo "     Fix: add '- ${sbenv}', open PR, let Dagger pipeline run, merge argocd PR"
        overall_pass=false
    fi
    echo ""
}

# AppSet repo check: file exists, sbenv is in the generator, targetRevision is
# a stable ref. A feature branch targetRevision is a common cause of Helm
# rendering errors (Phase 3 of the runbook).
check_repo_appset() {
    echo "=== Repo: AppSet for ${svc} ==="
    if [[ ! -f "$appset_file" ]]; then
        echo "$FAIL AppSet file not found: ${appset_file}"
        overall_pass=false
        echo ""
        return
    fi
    echo "$PASS AppSet file exists: ${appset_file}"

    if grep -q "subenv: ${sbenv}" "$appset_file"; then
        echo "$PASS subenv: ${sbenv} present in AppSet generator"
    else
        echo "$FAIL subenv: ${sbenv} not in AppSet generator -- service will not deploy to ${sbenv}"
        echo "     Fix: merge the auto-generated 'Enable ${kenv}-${sbenv}' argocd PR"
        overall_pass=false
    fi

    local target_rev
    target_rev=$(grep "targetRevision" "$appset_file" | head -1 | awk '{print $NF}' | tr -d '"')
    echo "$INFO targetRevision: ${target_rev}"
    if [[ "$target_rev" =~ ^release/ ]] || [[ "$target_rev" =~ ^v[0-9] ]]; then
        echo "$PASS targetRevision looks like a stable ref"
    else
        echo "$WARN targetRevision '${target_rev}' may be a feature branch"
        echo "     Feature branches can cause Helm rendering errors (ComparisonError / Unknown)"
        echo "     See argocd-sync-failures.md Phase 3 if the app shows Unknown or SyncFailed"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Runtime checks
# ---------------------------------------------------------------------------

# Phase 1a: ArgoCD Application sync and health status. The combination of
# sync.status and health.status narrows down the failure mode.
check_runtime_app_status() {
    echo "=== Runtime: ArgoCD application status for '${app_name}' ==="
    local app_json
    app_json=$(kubectl get application "${app_name}" -n argocd \
        --context "${kubectl_context}" -o json 2>/dev/null) || app_json=""
    if [[ -z "$app_json" ]]; then
        echo "$FAIL Application '${app_name}' not found in namespace 'argocd'"
        echo "     Check Phase 0 and Repo checks -- app may not be generated yet"
        overall_pass=false
        echo ""
        return
    fi

    local sync_status health_status
    sync_status=$(echo  "$app_json" | jq -r '.status.sync.status   // "Unknown"')
    health_status=$(echo "$app_json" | jq -r '.status.health.status // "Unknown"')
    echo "$INFO sync.status:   ${sync_status}"
    echo "$INFO health.status: ${health_status}"

    if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
        echo "$PASS Application is Synced + Healthy"
    else
        echo "$FAIL Application is not Synced + Healthy"
        # Hint based on the status combination
        if [[ "$sync_status" == "Unknown" || "$sync_status" == "SyncFailed" ]]; then
            echo "$INFO Likely cause: Helm rendering error (feature branch or template bug)"
            echo "     See argocd-sync-failures.md Phase 3"
        elif [[ "$health_status" == "Progressing" ]]; then
            echo "$INFO Likely cause: pods stuck Pending -- possible cluster resource exhaustion"
            echo "     See argocd-sync-failures.md Phase 4"
        fi
        local conditions
        conditions=$(echo "$app_json" | jq -r '.status.conditions[]?.message // empty' 2>/dev/null || true)
        if [[ -n "$conditions" ]]; then
            echo "$INFO Condition message(s):"
            while read -r c; do echo "     ${c}"; done <<< "$conditions"
        fi
        overall_pass=false
    fi
    echo ""
}

# Phase 1b: ExternalSecret status. A SecretSyncedError means a Key Vault key
# referenced in the AppSet's externalSecret block does not exist in the vault.
check_runtime_externalsecrets() {
    echo "=== Runtime: ExternalSecret status for '${svc}' in namespace '${sbenv}' ==="
    local es_json
    es_json=$(kubectl get externalsecret -n "${sbenv}" \
        --context "${kubectl_context}" \
        -l "app.kubernetes.io/name=${svc}" -o json 2>/dev/null) || es_json=""
    if [[ -z "$es_json" ]]; then
        echo "$SKIP Could not retrieve ExternalSecrets -- check kubectl access"
        echo ""
        return
    fi

    local total
    total=$(echo "$es_json" | jq '.items | length')
    if [[ "$total" -eq 0 ]]; then
        echo "$INFO No ExternalSecrets found with label app.kubernetes.io/name=${svc}"
        echo "$INFO (May use a different label -- check manually with:"
        echo "$INFO  kubectl get externalsecret -n ${sbenv} --context ${kubectl_context})"
        echo ""
        return
    fi

    local failed_list
    failed_list=$(echo "$es_json" | jq -r \
        '.items[] | select(.status.conditions[]?.reason == "SecretSyncedError") | .metadata.name' \
        2>/dev/null || true)

    if [[ -z "$failed_list" ]]; then
        echo "$PASS All ${total} ExternalSecret(s) are Ready"
    else
        echo "$FAIL ExternalSecret(s) in SecretSyncedError state:"
        while read -r es_name; do
            local msg
            msg=$(echo "$es_json" | jq -r --arg n "$es_name" \
                '.items[] | select(.metadata.name == $n) |
                 .status.conditions[]? | select(.reason == "SecretSyncedError") | .message' \
                2>/dev/null || true)
            echo "     ${es_name}"
            [[ -n "$msg" ]] && echo "       ${msg}"
        done <<< "$failed_list"
        echo "     Fix: create missing Key Vault secret(s) in vozni-${kenv}-${sbenv}"
        echo "     See argocd-sync-failures.md Phase 2"
        overall_pass=false
    fi
    echo ""
}

# Phase 1d: Pod events. Identifies the most common runtime failure modes:
# cluster resource exhaustion (Pending), image pull failures (ImagePullBackOff),
# and rolling-update false alarms (old pod Terminating while new one starts).
check_runtime_pods() {
    echo "=== Runtime: Pod status for '${svc}' in namespace '${sbenv}' ==="
    local pods_json
    pods_json=$(kubectl get pods -n "${sbenv}" \
        --context "${kubectl_context}" \
        -l "app.kubernetes.io/name=${svc}" -o json 2>/dev/null) || pods_json=""
    if [[ -z "$pods_json" ]]; then
        echo "$SKIP Could not retrieve pods -- check kubectl access"
        echo ""
        return
    fi

    local total
    total=$(echo "$pods_json" | jq '.items | length')
    if [[ "$total" -eq 0 ]]; then
        echo "$INFO No pods found with label app.kubernetes.io/name=${svc}"
        echo ""
        return
    fi

    echo "$INFO Found ${total} pod(s):"
    echo "$pods_json" | jq -r \
        '.items[] | "     \(.metadata.name)  phase=\(.status.phase // "-")  \(if .metadata.deletionTimestamp then "[Terminating]" else "" end)"'

    local found_issue=false

    # Check: pods stuck Pending (cluster resource exhaustion)
    local pending_count
    pending_count=$(echo "$pods_json" | jq \
        '[.items[] | select(.status.phase == "Pending")] | length')
    if [[ "$pending_count" -gt 0 ]]; then
        echo ""
        echo "$FAIL ${pending_count} pod(s) stuck in Pending -- likely cluster resource exhaustion"
        echo "     Confirm with:"
        echo "       kubectl describe pod -n ${sbenv} --context ${kubectl_context} \\"
        echo "         -l app.kubernetes.io/name=${svc} | grep -A5 Events:"
        echo "     Look for: '0/N nodes available: N Insufficient cpu' or 'Insufficient memory'"
        echo "     Fix: scale up AKS node pool -- see argocd-sync-failures.md Phase 4"
        overall_pass=false
        found_issue=true
    fi

    # Check: image pull failures
    local image_pull_count
    image_pull_count=$(echo "$pods_json" | jq \
        '[.items[].status.containerStatuses[]? |
          select(.state.waiting.reason == "ImagePullBackOff" or
                 .state.waiting.reason == "ErrImagePull")] | length' \
        2>/dev/null || echo 0)
    if [[ "$image_pull_count" -gt 0 ]]; then
        echo ""
        echo "$FAIL ${image_pull_count} container(s) with image pull failure:"
        echo "$pods_json" | jq -r \
            '.items[].status.containerStatuses[]? |
             select(.state.waiting.reason == "ImagePullBackOff" or
                    .state.waiting.reason == "ErrImagePull") |
             "     container=\(.name)  reason=\(.state.waiting.reason)\n     image=\(.image)"' \
            2>/dev/null || true
        echo "     Fix: verify the image tag exists in the registry and correct the AppSet"
        echo "     See argocd-sync-failures.md Phase 5"
        overall_pass=false
        found_issue=true
    fi

    # Check: pods stuck Terminating (possible rolling-update false alarm)
    local terminating_count
    terminating_count=$(echo "$pods_json" | jq \
        '[.items[] | select(.metadata.deletionTimestamp != null)] | length')
    if [[ "$terminating_count" -gt 0 ]]; then
        echo ""
        echo "$WARN ${terminating_count} pod(s) in Terminating state"
        echo "     If a new pod is also Pending or ContainerCreating, this is a rolling update"
        echo "     in progress -- not a real failure. Wait for termination to complete."
        echo "     If the pod is stuck Terminating, force-delete it:"
        echo "$pods_json" | jq -r \
            '.items[] | select(.metadata.deletionTimestamp != null) |
             "     kubectl delete pod \(.metadata.name) -n '"${sbenv}"' --context '"${kubectl_context}"' --grace-period=0 --force"' \
            2>/dev/null || true
    fi

    if [[ "$found_issue" == false ]]; then
        local running_count
        running_count=$(echo "$pods_json" | jq \
            '[.items[] | select(.status.phase == "Running")] | length')
        echo ""
        echo "$PASS ${running_count}/${total} pod(s) Running"
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

    check_phase0_subenvironments
    check_repo_appset

    if $skip_runtime; then
        echo "=== Runtime checks SKIPPED (--skip-runtime) ==="
        echo ""
    else
        check_runtime_app_status
        check_runtime_externalsecrets
        check_runtime_pods
    fi

    summarize
}

main "$@"
