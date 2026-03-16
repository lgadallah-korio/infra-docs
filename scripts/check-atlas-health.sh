#!/usr/bin/env bash
# check-atlas-health.sh
#
# Diagnoses MongoDB Atlas connectivity issues for a Korio AKS cluster.
# Complements check-pod-health.sh (pod-level) and check-http-health.sh
# (HTTP/NGINX layer).
#
# Checks two layers:
#
#   In-cluster (always run, requires kubectl access):
#     - ExternalSecret sync status for MongoDB-related secrets
#     - auth-node log analysis, classifying MongoDB errors into two buckets:
#         AUTH errors      --> Atlas database user missing or wrong password
#         CONNECTIVITY errors --> network / Private Link / Atlas cluster down
#
#   Atlas API (run when Atlas credentials are available):
#     - Atlas cluster state (IDLE, REPAIRING, etc.)
#     - Database user existence -- Terraform manages one user per sub-env;
#       the expected username is the sub-environment name (e.g. "validate")
#     - Azure Private Link endpoint service status
#
# Atlas credentials can be provided as flags or pre-exported env vars:
#   export ATLAS_PROJECT_ID=<hex-project-id>
#   export ATLAS_PUBLIC_KEY=<api-public-key>
#   export ATLAS_PRIVATE_KEY=<api-private-key>
#
# Atlas cluster naming convention (from terraform-infra/env/atlas_clusters.tf):
#   Per-subenv cluster (prod, staging, prod3, staging3):  vozni-{env}-{subenv}
#   Shared cluster     (dev, test, platform, sandbox):     vozni-{env}
# The script tries the per-subenv name first and falls back to the shared name.
#
# Database user naming convention:
#   Terraform creates one user per sub-env; username == sub-env name.
#   e.g. for prod-validate the user is "validate".
#   Override with -u if a different user was manually created.
#
# Usage:
#   check-atlas-health.sh [OPTIONS] <cluster>
#
# Arguments:
#   cluster    Cluster short name (e.g. staging, prod).
#              The kubectl context vozni-<cluster>-aks must exist.
#
# Options:
#   -n <namespace>      Sub-environment to check (e.g. validate).
#                       When omitted all discovered sub-envs are checked.
#   -p <project-id>     Atlas project ID (overrides $ATLAS_PROJECT_ID).
#   -k <public-key>     Atlas API public key (overrides $ATLAS_PUBLIC_KEY).
#   -s <private-key>    Atlas API private key (overrides $ATLAS_PRIVATE_KEY).
#   -u <db-username>    Expected Atlas DB username to verify. Defaults to the
#                       sub-env name when -n is given, otherwise skipped.
#   -l <lines>          auth-node log lines to scan (default: 500).
#   -h / --help         Show this help.
#
# Dependencies: kubectl, jq, curl (curl required only for Atlas API checks)

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FALLBACK_SUBENV_NAMESPACES=(configure preview validate accept my)

AUTHNODE_APP_LABEL="auth-node"

DEFAULT_LOG_LINES=500

# MongoDB error classification patterns for auth-node log analysis.
# Auth errors point to a missing/wrong-password Atlas database user.
MONGO_AUTH_ERR_RE='bad auth|Authentication failed|not authorized on|AuthenticationFailed|not allowed to do action|MONGODB-AWS|MongoServerError.*auth'

# Connectivity errors point to network, Private Link, or Atlas cluster issues.
MONGO_CONN_ERR_RE='ECONNREFUSED|ENOTFOUND|connection timed out|MongoNetworkError|MongoTimeoutError|MongoServerSelectionError|getaddrinfo.*ENOTFOUND|failed to connect|topology.*closed'

# Catch-all for any MongoDB-related log line, used to scope the output.
MONGO_ANY_RE='[Mm]ongo[Dd][Bb]|MongoError|MongoServer[A-Z]|MONGO_|MongoNetwork|MongoTimeout'

# Atlas API base URL and Accept header.
ATLAS_API_BASE="https://cloud.mongodb.com/api/atlas/v2"
ATLAS_API_ACCEPT="application/vnd.atlas.2023-01-01+json"

PASS="[PASS]"
FAIL="[FAIL]"
WARN="[WARN]"
INFO="[INFO]"

# ---------------------------------------------------------------------------
# Globals set by parse_args()
# ---------------------------------------------------------------------------

cluster=""
kubectl_context=""
target_namespace=""
verbose=false
log_lines=$DEFAULT_LOG_LINES

# Atlas API credentials (populated from flags or env vars in main()).
atlas_project_id=""
atlas_public_key=""
atlas_private_key=""
atlas_db_username_override=""   # empty = derive from sub-env name

# ---------------------------------------------------------------------------
# Usage / argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <cluster>

  cluster    Cluster short name (e.g. staging, prod).
             The kubectl context vozni-<cluster>-aks must exist.

Options:
  -n <namespace>      Check a specific sub-environment only (e.g. validate).
  -p <project-id>     Atlas project ID (overrides \$ATLAS_PROJECT_ID).
  -k <public-key>     Atlas API public key (overrides \$ATLAS_PUBLIC_KEY).
  -s <private-key>    Atlas API private key (overrides \$ATLAS_PRIVATE_KEY).
  -u <db-username>    Expected Atlas database username to verify.
                      Defaults to the sub-env name (Terraform convention).
  -l <lines>          auth-node log lines to scan (default: $DEFAULT_LOG_LINES).
  -h / --help         Show this help.

Atlas credentials can also be set as environment variables before calling:
  export ATLAS_PROJECT_ID=...
  export ATLAS_PUBLIC_KEY=...
  export ATLAS_PRIVATE_KEY=...

Examples:
  $(basename "$0") prod
  $(basename "$0") -n validate prod
  $(basename "$0") -n validate -p 6...f -k abc123 -s xyz789 prod
EOF
    exit "${1:-1}"
}

parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)           [[ -z "${2-}" ]] && { echo "Error: -n requires an argument" >&2; usage 1; }
                          target_namespace="$2"; shift 2 ;;
            -l)           [[ -z "${2-}" ]] && { echo "Error: -l requires an argument" >&2; usage 1; }
                          log_lines="$2"; shift 2 ;;
            -p)           [[ -z "${2-}" ]] && { echo "Error: -p requires an argument" >&2; usage 1; }
                          atlas_project_id="$2"; shift 2 ;;
            -k)           [[ -z "${2-}" ]] && { echo "Error: -k requires an argument" >&2; usage 1; }
                          atlas_public_key="$2"; shift 2 ;;
            -s)           [[ -z "${2-}" ]] && { echo "Error: -s requires an argument" >&2; usage 1; }
                          atlas_private_key="$2"; shift 2 ;;
            -u)           [[ -z "${2-}" ]] && { echo "Error: -u requires an argument" >&2; usage 1; }
                          atlas_db_username_override="$2"; shift 2 ;;
            -h|--help)    usage 0 ;;
            --)           shift; positional+=("$@"); break ;;
            -*)           echo "Unknown option: $1" >&2; usage 1 ;;
            *)            positional+=("$1"); shift ;;
        esac
    done
    [[ ${#positional[@]} -lt 1 ]] && { echo "Error: cluster name required" >&2; usage 1; }
    cluster="${positional[0]}"
    kubectl_context="vozni-${cluster}-aks"
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

namespace_exists() {
    kubectl get ns "$1" --context "$kubectl_context" &>/dev/null
}

# Portable line count (avoids wc -l leading-space quirk on macOS).
count_lines() {
    awk 'END{print NR}' "$1"
}

# Print stdin with a left-margin indent, capped at optional max line count.
indent_output() {
    local indent="$1"
    local max="${2:-0}"
    local n=0
    while IFS= read -r line; do
        if [[ $max -gt 0 && $n -ge $max ]]; then
            printf "%s  ... (truncated)\n" "$indent"
            break
        fi
        printf "%s%s\n" "$indent" "$line"
        n=$(( n + 1 ))
    done
}

# ---------------------------------------------------------------------------
# Atlas API helper
# ---------------------------------------------------------------------------

# Perform an Atlas API GET and return the JSON body on stdout.
# Returns 1 and prints an error if the call fails or returns non-2xx.
atlas_api_get() {
    local path="$1"
    local url="${ATLAS_API_BASE}${path}"
    local http_code body

    # Write body to a temp file so we can capture both body and status code.
    local tmp
    tmp=$(mktemp)
    http_code=$(curl -s -w "%{http_code}" -o "$tmp" \
        --digest \
        -u "${atlas_public_key}:${atlas_private_key}" \
        -H "Accept: ${ATLAS_API_ACCEPT}" \
        "$url" 2>/dev/null) || { rm -f "$tmp"; return 1; }

    body=$(cat "$tmp")
    rm -f "$tmp"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        local err_detail
        err_detail=$(echo "$body" | jq -r '.detail // .error // "unknown error"' 2>/dev/null || true)
        printf "  %s  Atlas API %s -> HTTP %s: %s\n" \
            "$FAIL" "$path" "$http_code" "$err_detail" >&2
        return 1
    fi
    echo "$body"
}

# Returns true if all three Atlas API credentials are set.
atlas_creds_available() {
    [[ -n "${atlas_project_id:-}" \
       && -n "${atlas_public_key:-}" \
       && -n "${atlas_private_key:-}" ]]
}

# Derive the Atlas cluster name for a given sub-environment.
# Convention from atlas_clusters.tf:
#   Per-subenv cluster (prod, staging, prod3, staging3): vozni-{env}-{subenv}
#   Shared cluster     (dev, test, platform, sandbox):   vozni-{env}
atlas_cluster_name() {
    local env="$1"
    local subenv="$2"
    case "$env" in
        prod|staging|prod3|staging3) echo "vozni-${env}-${subenv}" ;;
        *)                           echo "vozni-${env}" ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. MongoDB ExternalSecret sync check (in-cluster)
# ---------------------------------------------------------------------------

check_mongo_externalsecrets() {
    local ns="$1"

    echo ""
    echo "  -- MongoDB ExternalSecret sync --"

    local raw
    raw=$(kubectl get externalsecret -n "$ns" \
        --context "$kubectl_context" --no-headers 2>/dev/null) || return 0
    [[ -z "${raw:-}" ]] && { printf "  %s  No ExternalSecrets found\n" "$INFO"; return; }

    # Inspect each ES to find ones referencing mongo-related Key Vault keys.
    local found_mongo=false
    while IFS= read -r line; do
        local es_name es_status
        es_name=$(echo "$line"   | awk '{print $1}')
        es_status=$(echo "$line" | awk '{print $4}')

        # Check if any remote key in this ES references "mongo" (case-insensitive).
        local has_mongo_ref
        has_mongo_ref=$(kubectl get externalsecret "$es_name" -n "$ns" \
            --context "$kubectl_context" -o json 2>/dev/null | \
            jq -r '
                [
                  (.spec.data // [])[] | .remoteRef.key |
                  select(. != null) | ascii_downcase |
                  select(contains("mongo"))
                ] | length
            ')

        [[ "${has_mongo_ref:-0}" -eq 0 ]] && continue
        found_mongo=true

        if [[ "$es_status" == "SecretSynced" ]]; then
            printf "  %s  %-45s  SecretSynced\n" "$PASS" "$es_name"
        else
            # Fetch the failing reason from describe output.
            local desc attempt_info missing_key
            desc=$(kubectl describe externalsecret "$es_name" \
                -n "$ns" --context "$kubectl_context" 2>/dev/null)
            missing_key=$(echo "$desc" \
                | grep -oE 'key: [^,]+, err: Secret does not exist' \
                | head -1 | sed 's/key: //; s/, err: Secret does not exist//')
            attempt_info=$(echo "$desc" \
                | grep 'UpdateFailed' | tail -1 \
                | grep -oE 'x[0-9]+ over [0-9a-z]+' || true)

            printf "  %s  %-45s  %s" "$FAIL" "$es_name" "$es_status"
            [[ -n "${attempt_info:-}" ]] && printf "  (%s)" "$attempt_info"
            printf "\n"
            [[ -n "${missing_key:-}" ]] \
                && printf "         Missing Key Vault key: %s\n" "$missing_key"
        fi
    done <<< "$raw"

    $found_mongo || printf "  %s  No ExternalSecrets reference MongoDB keys\n" "$INFO"
}

# ---------------------------------------------------------------------------
# 2. auth-node log analysis -- MongoDB error classification (in-cluster)
# ---------------------------------------------------------------------------

check_mongo_logs() {
    local ns="$1"

    echo ""
    echo "  -- auth-node MongoDB log analysis --"

    local pods
    pods=$(kubectl get pods -n "$ns" --context "$kubectl_context" \
        -l "app=${AUTHNODE_APP_LABEL}" --no-headers \
        -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
        2>/dev/null | awk '$2=="Running" {print $1}')

    if [[ -z "${pods:-}" ]]; then
        printf "  %s  No running auth-node pods found (app=%s)\n" \
            "$WARN" "$AUTHNODE_APP_LABEL"
        return
    fi

    local pod
    while IFS= read -r pod; do
        [[ -z "$pod" ]] && continue
        printf "\n    Pod: %s\n" "$pod"

        local raw
        raw=$(kubectl logs "$pod" -n "$ns" --context "$kubectl_context" \
            --tail="$log_lines" 2>/dev/null || true)

        if [[ -z "${raw:-}" ]]; then
            printf "    %s  No logs available\n" "$WARN"
            continue
        fi

        local total
        total=$(echo "$raw" | awk 'END{print NR}')

        local n_auth n_conn n_any
        n_auth=$(echo "$raw" | grep -cEi "$MONGO_AUTH_ERR_RE" || true)
        n_conn=$(echo "$raw" | grep -cEi "$MONGO_CONN_ERR_RE" || true)
        n_any=$(echo  "$raw" | grep -cE  "$MONGO_ANY_RE"      || true)

        printf "    %s  Scanned %d lines  |  MongoDB auth errors: %d  connectivity errors: %d\n" \
            "$( [[ $n_auth -eq 0 && $n_conn -eq 0 ]] && echo "$PASS" || echo "$FAIL" )" \
            "$total" "$n_auth" "$n_conn"

        if [[ $n_auth -gt 0 ]]; then
            printf "\n    AUTH errors (bad password / user missing in Atlas -- last 5):\n"
            echo "$raw" | grep -Ei "$MONGO_AUTH_ERR_RE" | tail -5 | indent_output "      "
        fi

        if [[ $n_conn -gt 0 ]]; then
            printf "\n    CONNECTIVITY errors (network / Private Link / Atlas cluster -- last 5):\n"
            echo "$raw" | grep -Ei "$MONGO_CONN_ERR_RE" | tail -5 | indent_output "      "
        fi

        if [[ $n_auth -eq 0 && $n_conn -eq 0 && $n_any -gt 0 ]]; then
            printf "\n    Other MongoDB log lines (last 5 -- no classified errors found):\n"
            echo "$raw" | grep -E "$MONGO_ANY_RE" | tail -5 | indent_output "      "
        fi

        if [[ $n_auth -eq 0 && $n_conn -eq 0 && $n_any -eq 0 ]]; then
            printf "    %s  No MongoDB-related lines found in last %d log lines\n" \
                "$INFO" "$log_lines"
        fi

    done <<< "$pods"
}

# ---------------------------------------------------------------------------
# 3. Atlas cluster status (Atlas API)
# ---------------------------------------------------------------------------

check_atlas_cluster() {
    local ns="$1"

    echo ""
    echo "  -- Atlas cluster status --"

    local cluster_name
    cluster_name=$(atlas_cluster_name "$cluster" "$ns")

    local body
    if ! body=$(atlas_api_get "/groups/${atlas_project_id}/clusters/${cluster_name}"); then
        # atlas_api_get already printed the error.
        # Try the shared cluster name as a fallback.
        local shared_name="vozni-${cluster}"
        if [[ "$cluster_name" != "$shared_name" ]]; then
            printf "  %s  Retrying with shared cluster name: %s\n" "$INFO" "$shared_name"
            body=$(atlas_api_get "/groups/${atlas_project_id}/clusters/${shared_name}") || return
            cluster_name="$shared_name"
        else
            return
        fi
    fi

    local state_name mongo_version disk_gb
    state_name=$(echo   "$body" | jq -r '.stateName    // "UNKNOWN"')
    mongo_version=$(echo "$body" | jq -r '.mongoDBVersion // "unknown"')
    disk_gb=$(echo       "$body" | jq -r '.diskSizeGB   // "unknown"')

    local marker
    [[ "$state_name" == "IDLE" ]] && marker="$PASS" || marker="$FAIL"

    printf "  %s  Cluster: %-40s  state: %-12s  MongoDB: %s  disk: %s GB\n" \
        "$marker" "$cluster_name" "$state_name" "$mongo_version" "$disk_gb"

    if [[ "$state_name" != "IDLE" ]]; then
        printf "         Non-IDLE state: '%s' means the cluster is unavailable or being modified.\n" \
            "$state_name"
    fi
}

# ---------------------------------------------------------------------------
# 4. Atlas database user check (Atlas API)
# ---------------------------------------------------------------------------

check_atlas_db_user() {
    local ns="$1"

    echo ""
    echo "  -- Atlas database user check --"

    # Determine the expected username.
    # Terraform convention (atlas_clusters.tf): username == sub-env name.
    local username
    if [[ -n "${atlas_db_username_override:-}" ]]; then
        username="$atlas_db_username_override"
        printf "  %s  Checking for user: %s (override via -u)\n" "$INFO" "$username"
    elif [[ -n "$ns" ]]; then
        username="$ns"
        printf "  %s  Checking for user: %s (Terraform convention: username = sub-env name)\n" \
            "$INFO" "$username"
    else
        printf "  %s  No -n or -u specified; listing all users instead\n" "$INFO"
        local body
        body=$(atlas_api_get "/groups/${atlas_project_id}/databaseUsers") || return
        echo "$body" | jq -r '
            .results[] |
            "  \(.username)  (authDb: \(.databaseName))"
        ' | sort | indent_output "    "
        return
    fi

    # Check for the specific user.
    # Atlas API: GET /groups/{groupId}/databaseUsers/{dbName}/{username}
    # The auth database for Terraform-managed users is "admin".
    local body
    if ! body=$(atlas_api_get "/groups/${atlas_project_id}/databaseUsers/admin/${username}"); then
        # 404 means user does not exist -- already reported by atlas_api_get.
        printf "  %s  User '%s' is NOT present in Atlas.\n" "$FAIL" "$username"
        printf "       This is consistent with Terraform having removed a manually-added user.\n"
        printf "       Fix: add '%s' to the Terraform sub_environments list for %s,\n" \
            "$username" "$cluster"
        printf "       or run 'terraform import mongodbatlas_database_user.app_users[\"%s\"] %s-%s'\n" \
            "$username" "${atlas_project_id}" "$username"
        printf "       to bring it under Terraform management, then re-apply.\n"
        return
    fi

    local auth_db roles_summary
    auth_db=$(echo      "$body" | jq -r '.databaseName // "unknown"')
    roles_summary=$(echo "$body" | jq -r '
        .roles | map("\(.roleName)@\(.databaseName)") | join(", ")
    ')

    printf "  %s  User '%s' exists  (authDb: %s)\n" "$PASS" "$username" "$auth_db"
    printf "         Roles: %s\n" "$roles_summary"

    # Check that the expected databases are covered.
    # Terraform grants readWrite + dbAdmin on "{env}-{subenv}" and "{env}-{subenv}-{extra_db}".
    local expected_db
    expected_db="${cluster}-${ns}"
    local has_expected
    has_expected=$(echo "$body" | jq -r --arg db "$expected_db" '
        .roles | map(select(.databaseName == $db)) | length
    ')
    if [[ "${has_expected:-0}" -eq 0 ]]; then
        printf "  %s  User has no roles on database '%s'.\n" \
            "$WARN" "$expected_db"
        printf "       This database should be covered by the Terraform dynamic roles block.\n"
    else
        printf "  %s  User has roles on expected database '%s'\n" \
            "$PASS" "$expected_db"
    fi
}

# ---------------------------------------------------------------------------
# 5. Atlas Azure Private Link endpoint status (Atlas API)
# ---------------------------------------------------------------------------

check_atlas_private_link() {
    echo ""
    echo "  -- Atlas Azure Private Link status --"

    local body
    body=$(atlas_api_get \
        "/groups/${atlas_project_id}/privateEndpoint/AZURE/endpointService") || return

    local total
    total=$(echo "$body" | jq '.results | length')

    if [[ "$total" -eq 0 ]]; then
        printf "  %s  No Azure Private Link endpoint services found for this project.\n" \
            "$FAIL"
        printf "       Expected at least one (managed by atlas_privatelink_azure.tf).\n"
        return
    fi

    echo "$body" | jq -c '.results[]' | while IFS= read -r item; do
        local svc_name status id
        svc_name=$(echo "$item" | jq -r '.endpointServiceName // "(unnamed)"')
        status=$(echo   "$item" | jq -r '.status              // "UNKNOWN"')
        id=$(echo       "$item" | jq -r '._id                 // ""')

        local marker
        [[ "$status" == "AVAILABLE" ]] && marker="$PASS" || marker="$FAIL"

        printf "  %s  %-45s  status: %-20s  id: %s\n" \
            "$marker" "$svc_name" "$status" "$id"

        if [[ "$status" != "AVAILABLE" ]]; then
            printf "         Status '%s' means AKS cannot reach Atlas via Private Link.\n" \
                "$status"
            printf "         Expected: AVAILABLE.  Others: INITIATING, WAITING_FOR_USER,\n"
            printf "         FAILED, DELETING.  Re-run 'terraform apply' on the env workspace\n"
            printf "         to reconcile if this was caused by Terraform drift.\n"
        fi
    done
}

# ---------------------------------------------------------------------------
# Sub-environment namespace discovery (mirrors check-pod-health.sh)
# ---------------------------------------------------------------------------

discover_subenv_namespaces() {
    kubectl get ns --context "$kubectl_context" \
        --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
        | grep '^rabbitmq-' \
        | sed 's/^rabbitmq-//' \
        | sort
}

# ---------------------------------------------------------------------------
# Per-namespace driver
# ---------------------------------------------------------------------------

check_namespace() {
    local ns="$1"

    echo ""
    echo "=== Sub-environment: $ns ==="

    if ! namespace_exists "$ns"; then
        printf "  %s  (namespace not found)\n" "$INFO"
        return
    fi

    # In-cluster checks (always run).
    check_mongo_externalsecrets "$ns"
    check_mongo_logs            "$ns"

    # Atlas API checks (only when credentials are set).
    if atlas_creds_available; then
        check_atlas_cluster      "$ns"
        check_atlas_db_user      "$ns"
        # Private Link is project-wide, so only run once (for first namespace).
        # Caller guards this via a flag -- see main().
        if [[ "${_atlas_private_link_done:-false}" == "false" ]]; then
            check_atlas_private_link
            _atlas_private_link_done=true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    # Merge flag values with env vars (flags take precedence).
    [[ -z "$atlas_project_id" ]] && atlas_project_id="${ATLAS_PROJECT_ID:-}"
    [[ -z "$atlas_public_key"  ]] && atlas_public_key="${ATLAS_PUBLIC_KEY:-}"
    [[ -z "$atlas_private_key" ]] && atlas_private_key="${ATLAS_PRIVATE_KEY:-}"

    for dep in kubectl jq; do
        command -v "$dep" &>/dev/null \
            || { echo "Error: $dep is required but not installed" >&2; exit 1; }
    done

    if atlas_creds_available; then
        command -v curl &>/dev/null \
            || { echo "Error: curl is required for Atlas API checks" >&2; exit 1; }
    fi

    kubectl config get-contexts "$kubectl_context" &>/dev/null \
        || { echo "Error: kubectl context '$kubectl_context' not found" >&2; exit 1; }

    echo ""
    echo "=== Korio Atlas / MongoDB Health Check ==="
    echo "  Cluster : $cluster"
    echo "  Context : $kubectl_context"
    echo "  Time    : $(date)"
    echo "  Log scan: last $log_lines lines per pod"
    [[ -n "$target_namespace" ]] \
        && echo "  Scope   : namespace '$target_namespace'"
    if atlas_creds_available; then
        echo "  Atlas   : project ${atlas_project_id} (API checks enabled)"
    else
        echo "  Atlas   : no credentials -- API checks SKIPPED"
        echo "            (set ATLAS_PROJECT_ID / ATLAS_PUBLIC_KEY / ATLAS_PRIVATE_KEY"
        echo "             or use -p / -k / -s flags to enable)"
    fi
    echo ""

    local subenvs=()
    if [[ -n "$target_namespace" ]]; then
        subenvs=("$target_namespace")
    else
        while IFS= read -r ns; do
            [[ -n "$ns" ]] && subenvs+=("$ns")
        done < <(discover_subenv_namespaces)

        if [[ ${#subenvs[@]} -eq 0 ]]; then
            echo "Warning: namespace discovery returned nothing; using defaults" >&2
            subenvs=("${FALLBACK_SUBENV_NAMESPACES[@]}")
        fi
    fi

    _atlas_private_link_done=false
    for ns in "${subenvs[@]}"; do
        check_namespace "$ns"
    done

    echo ""
    echo "=== Done ==="
    echo ""
}

main "$@"
