#!/usr/bin/env bash
# check-credentials.sh
#
# Scans all Korio environment clusters for ExternalSecret sync failures,
# classifies the root cause (expired credentials, auth failure, missing
# Key Vault key), and suggests remediation.
#
# For each environment it checks:
#   - ClusterSecretStore and SecretStore health
#   - ExternalSecret sync status, grouped by namespace
#   - Root cause of failures (sampled once per namespace to avoid
#     making hundreds of kubectl describe calls)
#
# Usage:
#   check-credentials.sh [OPTIONS]
#
# Options:
#   -e <env,...>        Comma-separated list of envs to check (default: all).
#   -x / --check-expiry Show credential expiry dates for all envs, regardless
#                       of whether they are currently failing. Also enriches
#                       expired-credential errors with the exact expiry date.
#                       Requires: az (logged in), jq.
#   -v / --verbose      Show raw error message for failing namespaces.
#   -h / --help         Show this help.
#
# Dependencies: kubectl
#               az, jq  (only required when -x is used or expired credentials
#                        are detected and az is available)

set -uo pipefail

ALL_ENVS=(dev test platform platform3 staging staging3 prod prod3 sandbox)
# Sub-environment namespaces to probe when looking for kv-app-credentials.
SUBENV_NAMESPACES=(configure preview validate accept my)

PASS="[PASS]"
FAIL="[FAIL]"
INFO="[INFO]"
WARN="[WARN]"

verbose=false
check_expiry=false
target_envs=()

# ---------------------------------------------------------------------------
# Usage / argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -e <env,...>        Comma-separated list of envs to check (default: all).
  -x / --check-expiry Show credential expiry dates for all envs (requires az, jq).
  -v / --verbose      Show raw error message for failing namespaces.
  -h / --help         Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") -e staging,prod
  $(basename "$0") -x -e staging,prod
  $(basename "$0") -v -e staging
EOF
    exit "${1:-1}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e)  [[ -z "${2-}" ]] && { echo "Error: -e requires an argument" >&2; usage 1; }
                 IFS=',' read -ra target_envs <<< "$2"; shift 2 ;;
            -x|--check-expiry) check_expiry=true; shift ;;
            -v|--verbose) verbose=true; shift ;;
            -h|--help) usage 0 ;;
            -*)  echo "Unknown option: $1" >&2; usage 1 ;;
            *)   echo "Unexpected argument: $1" >&2; usage 1 ;;
        esac
    done
    [[ ${#target_envs[@]} -eq 0 ]] && target_envs=("${ALL_ENVS[@]}")
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Classify an ExternalSecret failure from 'kubectl describe' output.
# Prints one of: expired-credentials, auth-failure, missing-key, unknown.
classify_error() {
    local desc="$1"
    if echo "$desc" | grep -q 'AADSTS7000222'; then
        echo "expired-credentials"
    elif echo "$desc" | grep -q 'StatusCode=401\|401 Unauthorized'; then
        echo "auth-failure"
    elif echo "$desc" | grep -q 'Secret does not exist\|SecretNotFound'; then
        echo "missing-key"
    else
        echo "unknown"
    fi
}

# Portable ISO8601 -> Unix epoch.
iso_to_epoch() {
    local ts
    # Strip sub-seconds and timezone offset to get a plain UTC datetime.
    ts=$(echo "$1" | sed 's/\.[0-9]*//' | sed 's/+[0-9:]*//' | sed 's/Z$//')
    date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" "+%s" 2>/dev/null \
        || date --date="$ts" "+%s" 2>/dev/null \
        || echo "0"
}

# Format a single ISO8601 expiry date as a human-readable status string,
# e.g. "[EXPIRED]  2026-03-22  (2d ago)" or "[OK]  2027-09-01  (in 520d)".
format_expiry_date() {
    local end_dt="$1"
    local now end_epoch diff days label
    now=$(date +%s)
    end_epoch=$(iso_to_epoch "$end_dt")
    # Trim to date-only for display.
    local end_display
    end_display=$(echo "$end_dt" | sed 's/T.*//')

    if [[ "$end_epoch" -eq 0 ]]; then
        echo "[????]  ${end_display}  (could not parse date)"
        return
    fi

    diff=$(( end_epoch - now ))
    days=$(( diff / 86400 ))

    if [[ $diff -lt 0 ]]; then
        label="[EXPIRED]  ${end_display}  ($(( -days ))d ago)"
    elif [[ $days -lt 30 ]]; then
        label="[WARN]     ${end_display}  (in ${days}d)"
    else
        label="[OK]       ${end_display}  (in ${days}d)"
    fi
    echo "$label"
}

# Print credential expiry lines for the given app ID (UUID).
# Calls 'az ad app credential list'; silently skips if az is unavailable
# or not logged in.
print_credential_expiry() {
    local app_id="$1" indent="$2"
    command -v az  &>/dev/null || return 0
    command -v jq  &>/dev/null || return 0

    local creds
    creds=$(az ad app credential list --id "$app_id" 2>/dev/null) || return 0
    [[ -z "$creds" || "$creds" == "[]" ]] && return 0

    echo "$creds" | jq -c '.[]' | while IFS= read -r cred; do
        local name end_dt status_str
        name=$(   echo "$cred" | jq -r '.displayName // .hint // "unnamed"')
        end_dt=$( echo "$cred" | jq -r '.endDateTime')
        status_str=$(format_expiry_date "$end_dt")
        printf "%s%-12s  %s\n" "$indent" "$name" "$status_str"
    done
}

# Return the ClientID stored in kv-app-credentials for the given context,
# probing sub-environment namespaces in order until one responds.
get_client_id() {
    local ctx="$1"
    local ns client_id
    for ns in "${SUBENV_NAMESPACES[@]}"; do
        client_id=$(kubectl get secret kv-app-credentials -n "$ns" \
            --context "$ctx" \
            -o jsonpath='{.data.ClientID}' 2>/dev/null \
            | base64 -d 2>/dev/null || true)
        [[ -n "${client_id:-}" ]] && { echo "$client_id"; return; }
    done
}

# ---------------------------------------------------------------------------
# Per-environment checks
# ---------------------------------------------------------------------------

check_secret_stores() {
    local ctx="$1"
    local css_issues=0 ss_issues=0

    # ClusterSecretStore (no -A): NAME AGE STATUS CAPABILITIES READY
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local status ready
        status=$(echo "$line" | awk '{print $3}')
        ready=$( echo "$line" | awk '{print $5}')
        [[ "$status" != "Valid" || "$ready" != "True" ]] \
            && css_issues=$(( css_issues + 1 ))
    done < <(kubectl get clustersecretstore --context "$ctx" \
                 --no-headers 2>/dev/null || true)

    # SecretStore (-A): NAMESPACE NAME AGE STATUS CAPABILITIES READY
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local status ready
        status=$(echo "$line" | awk '{print $4}')
        ready=$( echo "$line" | awk '{print $6}')
        [[ "$status" != "Valid" || "$ready" != "True" ]] \
            && ss_issues=$(( ss_issues + 1 ))
    done < <(kubectl get secretstore -A --context "$ctx" \
                 --no-headers 2>/dev/null || true)

    # Return as colon-delimited string (avoids subshell variable scoping).
    echo "${css_issues}:${ss_issues}"
}

check_env() {
    local env="$1"
    local ctx="vozni-${env}-aks"

    if ! kubectl config get-contexts "$ctx" &>/dev/null; then
        printf "  %s  context not found, skipping\n\n" "$INFO"
        return
    fi

    # --- SecretStore health ---
    local store_result css_issues ss_issues
    store_result=$(check_secret_stores "$ctx")
    css_issues="${store_result%%:*}"
    ss_issues="${store_result##*:}"

    if [[ "$css_issues" -gt 0 || "$ss_issues" -gt 0 ]]; then
        printf "  %s  SecretStores: %d ClusterSecretStore(s), %d SecretStore(s) not valid\n" \
            "$FAIL" "$css_issues" "$ss_issues"
    else
        printf "  %s  SecretStores: all valid\n" "$PASS"
    fi

    # --- ExternalSecret sync status ---
    # With -A, columns are: NAMESPACE NAME STORE REFRESH STATUS READY
    # STATUS is $5.
    local all_es total failing
    all_es=$(kubectl get externalsecret -A --context "$ctx" \
                 --no-headers 2>/dev/null || true)

    if [[ -z "$all_es" ]]; then
        printf "  %s  ExternalSecrets: none found\n\n" "$INFO"
        return
    fi

    total=$(   echo "$all_es" | awk 'END{print NR}')
    failing=$( echo "$all_es" | awk '$5 != "SecretSynced" {c++} END{print c+0}')

    if [[ "$failing" -eq 0 ]]; then
        printf "  %s  ExternalSecrets: all %d synced\n" "$PASS" "$total"
        if $check_expiry; then
            local client_id
            client_id=$(get_client_id "$ctx")
            if [[ -n "${client_id:-}" ]]; then
                printf "  %s  Credential expiry  (app: %s):\n" "$INFO" "$client_id"
                print_credential_expiry "$client_id" "         "
            else
                printf "  %s  Credential expiry: could not read ClientID from cluster\n" "$WARN"
            fi
        fi
        printf "\n"
        return
    fi

    printf "  %s  ExternalSecrets: %d / %d failing\n" "$FAIL" "$failing" "$total"

    # Sample one failing ES per namespace to classify the root cause.
    # This keeps kubectl describe calls to O(namespaces) rather than O(ESes).
    local prev_ns=""
    while IFS= read -r line; do
        local ns es_name status
        ns=$(      echo "$line" | awk '{print $1}')
        es_name=$( echo "$line" | awk '{print $2}')
        status=$(  echo "$line" | awk '{print $5}')

        [[ "$status" == "SecretSynced" ]] && continue
        [[ "$ns" == "$prev_ns"         ]] && continue  # already sampled this ns
        prev_ns="$ns"

        local ns_total ns_failing
        ns_total=$(  echo "$all_es" | awk -v n="$ns" '$1==n           {c++} END{print c+0}')
        ns_failing=$(echo "$all_es" | awk -v n="$ns" '$1==n && $5!="SecretSynced" {c++} END{print c+0}')

        local desc error_type
        desc=$(kubectl describe externalsecret "$es_name" -n "$ns" \
            --context "$ctx" 2>/dev/null)
        error_type=$(classify_error "$desc")

        printf "         %-12s  %d / %d failing  --  " "$ns" "$ns_failing" "$ns_total"

        case "$error_type" in
            expired-credentials)
                local app_id
                app_id=$(echo "$desc" | grep -oE "app '[a-f0-9-]+'" \
                    | head -1 | sed "s/app '//; s/'//")
                printf "expired service principal credentials"
                [[ -n "${app_id:-}" ]] && printf "  (app: %s)" "$app_id"
                printf "\n"
                if [[ -n "${app_id:-}" ]]; then
                    print_credential_expiry "$app_id" "                        "
                fi
                printf "                        Fix: cd terraform-infra/env\n"
                printf "                             terraform workspace select %s\n" "$env"
                printf "                             terraform taint 'azuread_application_password.apps[\"aks-external-secrets\"]'\n"
                printf "                             terraform apply\n"
                printf "                             kubectl rollout restart deployment external-secrets -n external-secrets --context %s\n" "$ctx"
                ;;
            auth-failure)
                printf "authentication failure (401) -- check SecretStore credentials\n"
                ;;
            missing-key)
                local key
                key=$(echo "$desc" | grep -oE 'key: [^,]+, err: Secret does not exist' \
                    | head -1 | sed 's/key: //; s/, err: Secret does not exist//')
                printf "missing Key Vault key"
                [[ -n "${key:-}" ]] && printf ": %s" "$key"
                printf "\n"
                ;;
            *)
                printf "unknown -- run: check-pod-health.sh -n %s %s\n" "$ns" "$env"
                ;;
        esac

        if $verbose; then
            local raw_msg
            raw_msg=$(echo "$desc" | grep 'Message:' | tail -1 \
                | sed 's/^[[:space:]]*Message:[[:space:]]*//')
            [[ -n "${raw_msg:-}" ]] \
                && printf "                        Message: %s\n" "$raw_msg"
        fi
    done <<< "$all_es"

    if $check_expiry; then
        local client_id
        client_id=$(get_client_id "$ctx")
        if [[ -n "${client_id:-}" ]]; then
            printf "  %s  Credential expiry  (app: %s):\n" "$INFO" "$client_id"
            print_credential_expiry "$client_id" "         "
        else
            printf "  %s  Credential expiry: could not read ClientID from cluster\n" "$WARN"
        fi
    fi

    printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    command -v kubectl &>/dev/null \
        || { echo "Error: kubectl is required but not installed" >&2; exit 1; }

    if $check_expiry; then
        command -v az  &>/dev/null \
            || { echo "Error: az is required for -x but not installed" >&2; exit 1; }
        command -v jq  &>/dev/null \
            || { echo "Error: jq is required for -x but not installed" >&2; exit 1; }
    fi

    echo ""
    echo "=== Korio Credential Health Check ==="
    echo "  Envs : ${target_envs[*]}"
    echo "  Time : $(date)"
    $check_expiry && echo "  Mode : expiry dates enabled"
    echo ""

    for env in "${target_envs[@]}"; do
        echo "  -- $env --"
        check_env "$env"
    done

    echo "=== Done ==="
    echo ""
}

main "$@"
