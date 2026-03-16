#!/usr/bin/env bash
# check-http-health.sh
#
# Diagnoses HTTP-layer issues (401/500 errors, routing misconfigurations) for a
# Korio AKS cluster. Complements check-pod-health.sh, which covers pod-level
# issues (CrashLoopBackOff, ImagePullBackOff, ExternalSecrets).
#
# For each sub-environment namespace it checks:
#   - NGINX access logs    -- 4xx/5xx counts and sample failing request paths
#   - NGINX route config   -- every $target Service in the ConfigMap exists
#   - Service endpoints    -- no Service has zero ready pods behind it
#   - auth-node logs       -- JWT / B2C / MongoDB error patterns
#   - auth-node config     -- B2C tenant, policy, client ID (no secrets printed)
#   - Ingress objects      -- each Ingress has an address assigned
#
# NOTE: NGINX pod discovery uses app labels "nginx" and "api-gateway".
#       If your deployment uses a different label, adjust NGINX_APP_LABELS below.
#       The external gateway ConfigMap is identified by containing "auth_request";
#       the internal gateway (no auth_request directives) is intentionally skipped.
#
# Usage:
#   check-http-health.sh [OPTIONS] <cluster>
#
# Arguments:
#   cluster    Cluster short name (e.g. staging, prod).
#              The kubectl context vozni-<cluster>-aks must exist.
#
# Options:
#   -n <namespace>    Check a specific sub-environment only.
#   -l <lines>        NGINX/auth-node log lines to scan per pod (default: 500).
#   -v / --verbose    Show individual failing log lines, not just counts.
#   -h / --help       Show this help.
#
# Dependencies: kubectl, jq

set -uo pipefail

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

FALLBACK_SUBENV_NAMESPACES=(configure preview validate accept my)

# App label values used to locate the NGINX gateway pod(s).
NGINX_APP_LABELS=(nginx api-gateway)

# App label for the auth-node pod.
AUTHNODE_APP_LABEL="auth-node"

# Marker that distinguishes the external NGINX ConfigMap from the internal one.
# Only the external gateway carries auth_request directives.
NGINX_EXTERNAL_CM_MARKER="auth_request"

# Regex matched against auth-node log lines to surface JWT, B2C, and
# MongoDB failures.  Intentionally broad: WARN-level output is expected.
AUTHNODE_ERROR_RE='[Ee][Rr][Rr][Oo][Rr]|401|[Uu]nauthorized|[Ee]xpired|[Ii]nvalid[Tt]oken|JWKS|jwks|[Mm]ongo|connection refused|user not found|status.*ACTIVE'

DEFAULT_LOG_LINES=500

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

# ---------------------------------------------------------------------------
# Usage / argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <cluster>

  cluster    Cluster short name (e.g. staging, prod).
             The kubectl context vozni-<cluster>-aks must exist.

Options:
  -n <namespace>    Check a specific sub-environment only.
  -l <lines>        Log lines to scan per pod (default: $DEFAULT_LOG_LINES).
  -v / --verbose    Show individual failing log lines, not just counts.
  -h / --help       Show this help.

Examples:
  $(basename "$0") prod
  $(basename "$0") -n validate prod
  $(basename "$0") -v -n validate prod
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
            -v|--verbose) verbose=true; shift ;;
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

# Print stdin with a left-margin indent, capped at an optional max line count.
# Usage: some_command | indent_output <indent_str> [max_lines]
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
# Pod discovery
# ---------------------------------------------------------------------------

# Returns newline-separated running pod names matching any app=<label> selector.
# Usage: find_running_pods <namespace> <label> [<label> ...]
find_running_pods() {
    local ns="$1"; shift
    local results=""
    local label
    for label in "$@"; do
        local batch
        batch=$(kubectl get pods -n "$ns" --context "$kubectl_context" \
            -l "app=${label}" --no-headers \
            -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
            2>/dev/null | awk '$2=="Running" {print $1}')
        [[ -n "${batch:-}" ]] && results="${results:+${results}$'\n'}${batch}"
    done
    echo "${results:-}"
}

# ---------------------------------------------------------------------------
# Identify the external NGINX ConfigMap for a namespace.
# Returns its name on stdout, or empty string if not found.
# The external gateway is distinguished from the internal one by the presence
# of auth_request directives.
# ---------------------------------------------------------------------------

find_external_nginx_cm() {
    local ns="$1"
    kubectl get configmap -n "$ns" --context "$kubectl_context" \
        -o json 2>/dev/null | \
    jq -r --arg marker "$NGINX_EXTERNAL_CM_MARKER" '
        .items[] |
        select(.data != null) |
        select(
            .data | to_entries |
            map(.value | contains($marker)) |
            any
        ) |
        .metadata.name
    ' | head -1
}

# ---------------------------------------------------------------------------
# 1. NGINX access log analysis
# ---------------------------------------------------------------------------

check_nginx_logs() {
    local ns="$1"

    echo ""
    echo "  -- NGINX access log analysis --"

    local pods
    pods=$(find_running_pods "$ns" "${NGINX_APP_LABELS[@]}")

    if [[ -z "${pods:-}" ]]; then
        printf "  %s  No running pods found for labels: %s\n" \
            "$WARN" "${NGINX_APP_LABELS[*]}"
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

        # Match 4xx/5xx in both structured JSON-style ("status":"4xx") and
        # standard nginx combined log format (... 401 <bytes> ...) forms.
        local n_4xx n_5xx
        n_4xx=$(echo "$raw" | \
            grep -cE '"status"[[:space:]]*:[[:space:]]*"?4[0-9]{2}|[[:space:]]4[0-9]{2}[[:space:]]' \
            || true)
        n_5xx=$(echo "$raw" | \
            grep -cE '"status"[[:space:]]*:[[:space:]]*"?5[0-9]{2}|[[:space:]]5[0-9]{2}[[:space:]]' \
            || true)

        local marker
        [[ $n_4xx -eq 0 && $n_5xx -eq 0 ]] && marker="$PASS" || marker="$FAIL"
        printf "    %s  Scanned %d lines  |  4xx: %d  5xx: %d\n" \
            "$marker" "$total" "$n_4xx" "$n_5xx"

        if [[ $n_4xx -gt 0 ]]; then
            if $verbose; then
                printf "\n    4xx entries (last 5):\n"
                echo "$raw" | \
                    grep -E '"status"[[:space:]]*:[[:space:]]*"?4[0-9]{2}|[[:space:]]4[0-9]{2}[[:space:]]' | \
                    tail -5 | indent_output "      "
            else
                printf "\n    4xx paths (last 5 unique):\n"
                echo "$raw" | \
                    grep -E '"status"[[:space:]]*:[[:space:]]*"?4[0-9]{2}|[[:space:]]4[0-9]{2}[[:space:]]' | \
                    grep -oE '"InURI"[[:space:]]*:[[:space:]]*"[^"]*"|(GET|POST|PUT|PATCH|DELETE|HEAD)[[:space:]]+[^[:space:]]+' | \
                    sort -u | tail -5 | indent_output "      "
            fi
        fi

        if [[ $n_5xx -gt 0 ]]; then
            if $verbose; then
                printf "\n    5xx entries (last 5):\n"
                echo "$raw" | \
                    grep -E '"status"[[:space:]]*:[[:space:]]*"?5[0-9]{2}|[[:space:]]5[0-9]{2}[[:space:]]' | \
                    tail -5 | indent_output "      "
            else
                printf "\n    5xx paths (last 5 unique):\n"
                echo "$raw" | \
                    grep -E '"status"[[:space:]]*:[[:space:]]*"?5[0-9]{2}|[[:space:]]5[0-9]{2}[[:space:]]' | \
                    grep -oE '"InURI"[[:space:]]*:[[:space:]]*"[^"]*"|(GET|POST|PUT|PATCH|DELETE|HEAD)[[:space:]]+[^[:space:]]+' | \
                    sort -u | tail -5 | indent_output "      "
            fi
        fi

    done <<< "$pods"
}

# ---------------------------------------------------------------------------
# 2. NGINX ConfigMap route validation
# ---------------------------------------------------------------------------

check_nginx_routes() {
    local ns="$1"

    echo ""
    echo "  -- NGINX route validation (external gateway ConfigMap) --"

    local cm_name
    cm_name=$(find_external_nginx_cm "$ns")

    if [[ -z "${cm_name:-}" ]]; then
        printf "  %s  No external NGINX ConfigMap found in namespace '%s'\n" \
            "$WARN" "$ns"
        printf "       (Expected a ConfigMap whose data contains '%s'.)\n" \
            "$NGINX_EXTERNAL_CM_MARKER"
        return
    fi

    printf "  %s  ConfigMap: %s\n" "$INFO" "$cm_name"

    # Concatenate all ConfigMap data values into one blob for parsing.
    local cm_data
    cm_data=$(kubectl get configmap "$cm_name" -n "$ns" \
        --context "$kubectl_context" -o json 2>/dev/null | \
        jq -r '.data // {} | to_entries[] | .value')

    if [[ -z "${cm_data:-}" ]]; then
        printf "  %s  ConfigMap has no data\n" "$WARN"
        return
    fi

    # Extract <svc>.<namespace> pairs from:
    #   set $target http://<svc>.<ns>.svc.cluster.local[:port];
    local targets_file
    targets_file=$(mktemp)
    echo "$cm_data" | \
        grep -oE 'http://[a-z0-9-]+\.[a-z0-9-]+\.svc\.cluster\.local' | \
        sed 's|http://||' | \
        sort -u > "$targets_file"

    local total_targets
    total_targets=$(count_lines "$targets_file")

    if [[ "$total_targets" -eq 0 ]]; then
        printf "  %s  No svc.cluster.local upstream targets found in ConfigMap\n" "$WARN"
        rm -f "$targets_file"
        return
    fi

    printf "  %s  %d unique upstream target(s) referenced\n" "$INFO" "$total_targets"

    local missing=0 checked=0
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        local svc_name target_ns
        svc_name=$(echo "$target" | awk -F'.' '{print $1}')
        target_ns=$(echo "$target"  | awk -F'.' '{print $2}')
        checked=$(( checked + 1 ))
        if ! kubectl get svc "$svc_name" -n "$target_ns" \
                --context "$kubectl_context" &>/dev/null; then
            printf "  %s  Service not found: %-50s  (namespace: %s)\n" \
                "$FAIL" "$svc_name" "$target_ns"
            missing=$(( missing + 1 ))
        fi
    done < "$targets_file"
    rm -f "$targets_file"

    if [[ $missing -eq 0 ]]; then
        printf "  %s  All %d target Services exist in-cluster\n" "$PASS" "$checked"
    else
        printf "  %s  %d/%d target Services are missing\n" "$FAIL" "$missing" "$checked"
    fi
}

# ---------------------------------------------------------------------------
# 3. Service endpoint health
# ---------------------------------------------------------------------------

check_service_endpoints() {
    local ns="$1"

    echo ""
    echo "  -- Service endpoint health --"

    local eps_json
    eps_json=$(kubectl get endpoints -n "$ns" --context "$kubectl_context" \
        -o json 2>/dev/null)

    local total
    total=$(echo "$eps_json" | jq '.items | length')

    if [[ "$total" -eq 0 ]]; then
        printf "  %s  No Services found in namespace\n" "$INFO"
        return
    fi

    # Collect Services with zero ready addresses.
    # Skips the "kubernetes" endpoint (cluster-internal, not application-owned).
    local empty_file
    empty_file=$(mktemp)

    echo "$eps_json" | jq -r '
        .items[] |
        select(.metadata.name != "kubernetes") |
        (.metadata.name) as $name |
        (
            [ (.subsets // [])[] | (.addresses // []) | length ] | add // 0
        ) as $ready |
        select($ready == 0) |
        $name
    ' > "$empty_file" 2>/dev/null

    local n_empty
    n_empty=$(count_lines "$empty_file")

    if [[ $n_empty -eq 0 ]]; then
        printf "  %s  All %d Services have ready endpoints\n" "$PASS" "$total"
    else
        printf "  %s  %d Service(s) with no ready endpoints:\n" "$FAIL" "$n_empty"
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            printf "         - %s\n" "$svc"
        done < "$empty_file"
    fi
    rm -f "$empty_file"
}

# ---------------------------------------------------------------------------
# 4. auth-node log error analysis
# ---------------------------------------------------------------------------

check_authnode_logs() {
    local ns="$1"

    echo ""
    echo "  -- auth-node log analysis --"

    local pods
    pods=$(find_running_pods "$ns" "$AUTHNODE_APP_LABEL")

    if [[ -z "${pods:-}" ]]; then
        printf "  %s  No running pods found for app=%s\n" \
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

        local total n_errors
        total=$(echo "$raw" | awk 'END{print NR}')
        n_errors=$(echo "$raw" | grep -cE "$AUTHNODE_ERROR_RE" || true)

        local marker
        [[ $n_errors -eq 0 ]] && marker="$PASS" || marker="$WARN"
        printf "    %s  Scanned %d lines  |  %d line(s) match error/auth patterns\n" \
            "$marker" "$total" "$n_errors"

        if [[ $n_errors -gt 0 ]]; then
            local sample n_sample
            sample=$(echo "$raw" | grep -E "$AUTHNODE_ERROR_RE" | tail -10)
            n_sample=$(echo "$sample" | awk 'END{print NR}')
            printf "\n    Last %d matching line(s):\n" "$n_sample"
            echo "$sample" | indent_output "      " 10
        fi

    done <<< "$pods"
}

# ---------------------------------------------------------------------------
# 5. auth-node B2C configuration (envfrom ConfigMap)
# ---------------------------------------------------------------------------

check_authnode_config() {
    local ns="$1"

    echo ""
    echo "  -- auth-node B2C configuration (envfrom ConfigMap) --"

    local cm_list
    cm_list=$(kubectl get configmap -n "$ns" --context "$kubectl_context" \
        --no-headers \
        -o custom-columns='NAME:.metadata.name' 2>/dev/null | \
        grep 'auth-node' || true)

    if [[ -z "${cm_list:-}" ]]; then
        printf "  %s  No ConfigMap matching 'auth-node' found in namespace '%s'\n" \
            "$WARN" "$ns"
        return
    fi

    local cm
    while IFS= read -r cm; do
        [[ -z "$cm" ]] && continue
        printf "\n  ConfigMap: %s\n" "$cm"

        # Print non-secret key=value pairs sorted alphabetically.
        # Redacts any key containing SECRET, KEY, PASSWORD, or TOKEN.
        kubectl get configmap "$cm" -n "$ns" --context "$kubectl_context" \
            -o json 2>/dev/null | \
        jq -r '
            .data // {} |
            to_entries[] |
            select(.key | test("SECRET|KEY|PASSWORD|TOKEN"; "i") | not) |
            "    \(.key) = \(.value)"
        ' | sort | indent_output "  "

    done <<< "$cm_list"
}

# ---------------------------------------------------------------------------
# 6. Ingress object status
# ---------------------------------------------------------------------------

check_ingress() {
    local ns="$1"

    echo ""
    echo "  -- Ingress status --"

    local ingress_json
    ingress_json=$(kubectl get ingress -n "$ns" --context "$kubectl_context" \
        -o json 2>/dev/null)

    local total
    total=$(echo "$ingress_json" | jq '.items | length')

    if [[ "$total" -eq 0 ]]; then
        printf "  %s  No Ingress objects in namespace\n" "$INFO"
        return
    fi

    local ingress_names
    ingress_names=$(echo "$ingress_json" | jq -r '.items[].metadata.name')

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local host addr
        host=$(echo "$ingress_json" | jq -r \
            --arg n "$name" '
                .items[] | select(.metadata.name == $n) |
                .spec.rules[0].host //
                (.spec.tls[0].hosts[0] // "(no host)")
            ')
        addr=$(echo "$ingress_json" | jq -r \
            --arg n "$name" '
                .items[] | select(.metadata.name == $n) |
                .status.loadBalancer.ingress[0].ip //
                .status.loadBalancer.ingress[0].hostname //
                ""
            ')

        if [[ -z "$addr" ]]; then
            printf "  %s  %-50s  host: %-35s  address: (unassigned)\n" \
                "$FAIL" "$name" "$host"
        else
            printf "  %s  %-50s  host: %-35s  addr: %s\n" \
                "$PASS" "$name" "$host" "$addr"
        fi
    done <<< "$ingress_names"
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

    check_nginx_logs        "$ns"
    check_nginx_routes      "$ns"
    check_service_endpoints "$ns"
    check_authnode_logs     "$ns"
    check_authnode_config   "$ns"
    check_ingress           "$ns"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    for dep in kubectl jq awk grep sed; do
        command -v "$dep" &>/dev/null \
            || { echo "Error: $dep is required but not installed" >&2; exit 1; }
    done

    kubectl config get-contexts "$kubectl_context" &>/dev/null \
        || { echo "Error: kubectl context '$kubectl_context' not found" >&2; exit 1; }

    echo ""
    echo "=== Korio HTTP Health Check ==="
    echo "  Cluster : $cluster"
    echo "  Context : $kubectl_context"
    echo "  Time    : $(date)"
    echo "  Log scan: last $log_lines lines per pod"
    [[ -n "$target_namespace" ]] \
        && echo "  Scope   : namespace '$target_namespace'"
    $verbose && echo "  Mode    : verbose" || true
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

    for ns in "${subenvs[@]}"; do
        check_namespace "$ns"
    done

    echo ""
    echo "=== Done ==="
    echo ""
}

main "$@"
