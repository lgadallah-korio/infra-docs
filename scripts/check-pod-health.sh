#!/usr/bin/env bash
# check-pod-health.sh
#
# Diagnoses unhealthy pods across AKS namespaces for a Korio cluster.
# Corresponds to pod-health-troubleshooting.md.
#
# For each sub-environment namespace it checks:
#   - ExternalSecret sync status (SecretSyncedError -> missing Key Vault key)
#   - Pod health (CrashLoopBackOff, ImagePullBackOff, Pending, high restarts)
#   - RabbitMQ namespace pod health (rabbitmq-<subenv>)
#
# Infrastructure namespaces (argocd, datadog, external-secrets, grafana,
# dev-tools) are always checked for pod health regardless of -n scope.
#
# Usage:
#   check-pod-health.sh [OPTIONS] <cluster>
#
# Arguments:
#   cluster    Cluster short name (e.g. staging, prod).
#              The kubectl context vozni-<cluster>-aks must exist.
#
# Options:
#   -n <namespace>    Check a specific sub-environment only (e.g. validate).
#                     Both <namespace> and rabbitmq-<namespace> are checked.
#                     Infrastructure namespaces are always included.
#   -v / --verbose    Show more log lines for crashing/unstable pods.
#   -h / --help       Show this help.
#
# Dependencies: kubectl, jq

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INFRA_NAMESPACES=(argocd datadog external-secrets grafana dev-tools)
FALLBACK_SUBENV_NAMESPACES=(configure preview validate accept my)

RESTART_WARN_THRESHOLD=50    # minimum restarts to flag a Running pod as WARN
RECENT_RESTART_HOURS=24      # restarts within this window are treated as active
LOG_TAIL_SUMMARY=20
LOG_TAIL_VERBOSE=50

PASS="[PASS]"
FAIL="[FAIL]"
WARN="[WARN]"
INFO="[INFO]"

# ---------------------------------------------------------------------------
# Globals set by parse_args()
# ---------------------------------------------------------------------------

cluster=""
kubectl_context=""
target_namespace=""   # empty = all discovered sub-env namespaces
verbose=false
log_tail=$LOG_TAIL_SUMMARY
tmpdir=""             # set in main(), shared across check_pods() calls

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
                    Both <namespace> and rabbitmq-<namespace> are checked.
                    Infrastructure namespaces are always included.
  -v / --verbose    Show more log lines for crashing/unstable pods.
  -h / --help       Show this help.

Examples:
  $(basename "$0") staging
  $(basename "$0") -n validate staging
  $(basename "$0") -v prod
EOF
    exit "${1:-1}"
}

parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n)           [[ -z "${2-}" ]] && { echo "Error: -n requires an argument" >&2; usage 1; }
                          target_namespace="$2"; shift 2 ;;
            -v|--verbose) verbose=true;             shift   ;;
            -h|--help)    usage 0                           ;;
            --)           shift; positional+=("$@"); break  ;;
            -*)           echo "Unknown option: $1" >&2; usage 1 ;;
            *)            positional+=("$1"); shift          ;;
        esac
    done
    [[ ${#positional[@]} -lt 1 ]] && { echo "Error: cluster name required" >&2; usage 1; }
    cluster="${positional[0]}"
    kubectl_context="vozni-${cluster}-aks"
    $verbose && log_tail=$LOG_TAIL_VERBOSE || true
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# Portable ISO8601 timestamp -> Unix epoch.
# Tries macOS -j syntax first, falls back to GNU --date.
iso_to_epoch() {
    local ts="$1"
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null \
        || date --date="$ts" "+%s" 2>/dev/null \
        || echo "0"
}

secs_to_age() {
    local secs="$1"
    if   [[ $secs -lt 3600  ]]; then echo "$((secs / 60))m"
    elif [[ $secs -lt 86400 ]]; then echo "$((secs / 3600))h"
    else                              echo "$((secs / 86400))d"
    fi
}

# Return 0 if the given Unix epoch is within RECENT_RESTART_HOURS of now.
is_recent_epoch() {
    local epoch="$1"
    [[ "$epoch" -eq 0 ]] && return 1
    local diff=$(( $(date +%s) - epoch ))
    [[ $diff -lt $((RECENT_RESTART_HOURS * 3600)) ]]
}

# Portable line count (avoids wc -l leading-space quirk on macOS).
count_lines() {
    awk 'END{print NR}' "$1"
}

namespace_exists() {
    kubectl get ns "$1" --context "$kubectl_context" &>/dev/null
}

# ---------------------------------------------------------------------------
# jq filter: derive the kubectl STATUS string from a single pod's JSON object.
# Usage: echo "$pod_json" | pod_status_jq
# ---------------------------------------------------------------------------

pod_status_jq() {
    jq -r '
      (.status.containerStatuses // []) as $cs |
      (.status.phase) as $phase |

      if   $phase == "Succeeded" then "Completed"
      elif $phase == "Failed"    then "Error"
      elif $phase == "Unknown"   then "ContainerStatusUnknown"
      elif $phase == "Pending"   then
        ( $cs | map(.state.waiting.reason // "") |
          if   any(. == "ImagePullBackOff")  then "ImagePullBackOff"
          elif any(. == "ErrImagePull")      then "ErrImagePull"
          elif any(. == "ContainerCreating") then "ContainerCreating"
          else "Pending"
          end )
      else
        ( $cs | map(
            if   .state.waiting.reason != null then .state.waiting.reason
            elif .state.terminated != null then
              if .state.terminated.exitCode == 0 then "Completed"
              else (.state.terminated.reason // "Error")
              end
            elif .state.running == null and .state.waiting == null
                 and .lastState.terminated != null
                 then "ContainerStatusUnknown"
            elif .state.running != null then "Running"
            else "Unknown"
            end
          ) |
          if   any(. == "CrashLoopBackOff")      then "CrashLoopBackOff"
          elif any(. == "ImagePullBackOff")       then "ImagePullBackOff"
          elif any(. == "ErrImagePull")           then "ErrImagePull"
          elif any(. == "OOMKilled")              then "OOMKilled"
          elif any(. == "Error")                  then "Error"
          elif any(. == "ContainerStatusUnknown") then "ContainerStatusUnknown"
          elif all(. == "Running" or . == "Completed")
               and any(. == "Running")           then "Running"
          elif all(. == "Completed")              then "Completed"
          else "Unknown"
          end )
      end
    '
}

# ---------------------------------------------------------------------------
# ExternalSecret checks (application namespaces only)
# ---------------------------------------------------------------------------

check_externalsecrets() {
    local ns="$1"

    local raw
    raw=$(kubectl get externalsecret -n "$ns" \
        --context "$kubectl_context" --no-headers 2>/dev/null) || return 0
    [[ -z "$raw" ]] && return 0

    local found_failure=false
    while IFS= read -r line; do
        local es_name es_status
        es_name=$(echo "$line" | awk '{print $1}')
        # Columns (no-headers): NAME STORE REFRESH_INTERVAL STATUS READY
        # "REFRESH INTERVAL" is two words, so STATUS is $4, READY is $5.
        # Checking STATUS directly avoids the off-by-one ambiguity.
        es_status=$(echo "$line" | awk '{print $4}')
        [[ "$es_status" == "SecretSynced" ]] && continue

        found_failure=true
        local desc missing_key attempt_info
        desc=$(kubectl describe externalsecret "$es_name" \
            -n "$ns" --context "$kubectl_context" 2>/dev/null)
        missing_key=$(echo "$desc" \
            | grep -oE 'key: [^,]+, err: Secret does not exist' \
            | head -1 | sed 's/key: //; s/, err: Secret does not exist//')
        attempt_info=$(echo "$desc" \
            | grep 'UpdateFailed' | tail -1 \
            | grep -oE 'x[0-9]+ over [0-9a-z]+' || true)

        printf "  %s  externalsecret/%-40s  SecretSyncedError" \
            "$FAIL" "$es_name"
        [[ -n "${attempt_info:-}" ]] && printf "  (%s)" "$attempt_info"
        printf "\n"
        [[ -n "${missing_key:-}" ]] \
            && printf "         Missing key: %s\n" "$missing_key"
    done <<< "$raw"

    $found_failure || printf "  %s  all ExternalSecrets synced\n" "$PASS"
}

# ---------------------------------------------------------------------------
# Pod diagnosis helpers
# ---------------------------------------------------------------------------

# Print the Events: section from kubectl describe pod (up to 5 lines).
print_events() {
    local pod_name="$1" ns="$2"
    local events
    events=$(kubectl describe pod "$pod_name" -n "$ns" \
        --context "$kubectl_context" 2>/dev/null \
        | awk '/^Events:/,0' | tail -n +3 | grep -v '^[[:space:]]*$' | head -5)
    if [[ -n "${events:-}" ]]; then
        printf "         Events:\n"
        while IFS= read -r ev; do
            printf "           %s\n" "$ev"
        done <<< "$events"
    fi
}

# Print container logs, trying --previous first (captures the crash),
# falling back to current container output.
print_logs() {
    local pod_name="$1" ns="$2"
    local logs
    logs=$(kubectl logs --previous "$pod_name" -n "$ns" \
               --context "$kubectl_context" --tail="$log_tail" 2>/dev/null \
           || kubectl logs "$pod_name" -n "$ns" \
               --context "$kubectl_context" --tail="$log_tail" 2>/dev/null \
           || true)
    if [[ -n "${logs:-}" ]]; then
        printf "         Logs:\n"
        while IFS= read -r line; do
            printf "           %s\n" "$line"
        done <<< "$logs"
    else
        printf "         Logs: (unavailable -- node may have been replaced)\n"
    fi
}

# ---------------------------------------------------------------------------
# Core pod health check for a single namespace
# ---------------------------------------------------------------------------

check_pods() {
    local ns="$1"
    local now
    now=$(date +%s)

    # One API call for all pod data in this namespace.
    local pods_json
    pods_json=$(kubectl get pods -n "$ns" \
        --context "$kubectl_context" -o json 2>/dev/null)

    local total
    total=$(echo "$pods_json" | jq '.items | length')
    if [[ "$total" -eq 0 ]]; then
        printf "  %s  (no pods)\n" "$INFO"
        return 0
    fi

    # Build a list of app labels that have at least one Running pod.
    # Written to a temp file so the nested has_running_counterpart() function
    # can grep it without needing an associative array (bash 3 compatible).
    local running_labels_file
    running_labels_file="$tmpdir/running_labels_${ns//\//_}"
    echo "$pods_json" | jq -r '
        .items[] |
        select(.status.phase == "Running") |
        (.metadata.labels.app //
         .metadata.labels["app.kubernetes.io/name"] // "")
    ' | grep -v '^$' | sort -u > "$running_labels_file"

    # Returns 0 if the given app label has a Running pod in this namespace.
    has_running_counterpart() {
        [[ -z "$1" ]] && return 1
        grep -qxF "$1" "$running_labels_file"
    }

    # Category files -- one record per line, pipe-delimited.
    # Using files instead of arrays avoids bash 4 associative arrays and
    # keeps grouping logic simple with sort/awk.
    local f_crash f_pull f_pending f_unknown f_warn f_stale
    f_crash="$tmpdir/crash_${ns//\//_}"
    f_pull="$tmpdir/pull_${ns//\//_}"
    f_pending="$tmpdir/pending_${ns//\//_}"
    f_unknown="$tmpdir/unknown_${ns//\//_}"
    f_warn="$tmpdir/warn_${ns//\//_}"
    f_stale="$tmpdir/stale_${ns//\//_}"
    : > "$f_crash"; : > "$f_pull"; : > "$f_pending"
    : > "$f_unknown"; : > "$f_warn"; : > "$f_stale"

    local healthy=0 stale=0 count i
    count=$(echo "$pods_json" | jq '.items | length')

    for i in $(seq 0 $((count - 1))); do
        local pod_json pod_name app_label created_epoch age_str status
        pod_json=$(echo "$pods_json" | jq ".items[$i]")
        pod_name=$(echo   "$pod_json" | jq -r '.metadata.name')
        app_label=$(echo  "$pod_json" | jq -r '
            .metadata.labels.app //
            .metadata.labels["app.kubernetes.io/name"] // ""')
        created_epoch=$(iso_to_epoch \
            "$(echo "$pod_json" | jq -r '.metadata.creationTimestamp')")
        age_str=$(secs_to_age $(( now - created_epoch )))
        status=$(echo "$pod_json" | pod_status_jq)

        local total_restarts last_restart_ts last_restart_epoch
        total_restarts=$(echo "$pod_json" | jq '
            [(.status.containerStatuses // [])[] | .restartCount] | add // 0')
        last_restart_ts=$(echo "$pod_json" | jq -r '
            [(.status.containerStatuses // [])[] |
             .lastState.terminated.finishedAt // ""] |
            map(select(. != "")) | sort | last // ""')
        last_restart_epoch=0
        [[ -n "$last_restart_ts" ]] \
            && last_restart_epoch=$(iso_to_epoch "$last_restart_ts")

        case "$status" in
            Running)
                if [[ $total_restarts -ge $RESTART_WARN_THRESHOLD ]] \
                   && is_recent_epoch "$last_restart_epoch"; then
                    local lr_age
                    lr_age=$(secs_to_age $(( now - last_restart_epoch )))
                    printf '%s|%s|%s|%s\n' \
                        "$pod_name" "$total_restarts" "$lr_age" "$age_str" \
                        >> "$f_warn"
                else
                    healthy=$(( healthy + 1 ))
                fi
                ;;
            Completed)
                if has_running_counterpart "$app_label"; then
                    printf '%s|%s|Completed\n' \
                        "$app_label" "$age_str" >> "$f_stale"
                    stale=$(( stale + 1 ))
                else
                    # One-shot job or init that completed normally.
                    healthy=$(( healthy + 1 ))
                fi
                ;;
            Error)
                if has_running_counterpart "$app_label"; then
                    printf '%s|%s|Error\n' \
                        "$app_label" "$age_str" >> "$f_stale"
                    stale=$(( stale + 1 ))
                else
                    printf '%s|Error|%s|%s\n' \
                        "$pod_name" "$total_restarts" "$age_str" >> "$f_crash"
                fi
                ;;
            ContainerStatusUnknown)
                if has_running_counterpart "$app_label"; then
                    # Orphaned from a node disruption; superseded by a live pod.
                    printf '%s|%s|ContainerStatusUnknown\n' \
                        "$app_label" "$age_str" >> "$f_stale"
                    stale=$(( stale + 1 ))
                else
                    # No running counterpart -- node disruption on the only replica.
                    printf '%s|ContainerStatusUnknown|%s|%s\n' \
                        "$pod_name" "$total_restarts" "$age_str" >> "$f_unknown"
                fi
                ;;
            CrashLoopBackOff|OOMKilled)
                printf '%s|%s|%s|%s\n' \
                    "$pod_name" "$status" "$total_restarts" "$age_str" \
                    >> "$f_crash"
                ;;
            ImagePullBackOff|ErrImagePull)
                printf '%s|%s|%s\n' \
                    "$pod_name" "$status" "$age_str" >> "$f_pull"
                ;;
            Pending|ContainerCreating|PodInitializing)
                printf '%s|%s|%s\n' \
                    "$pod_name" "$status" "$age_str" >> "$f_pending"
                ;;
            *)
                printf '%s|%s|%s|%s\n' \
                    "$pod_name" "$status" "$total_restarts" "$age_str" \
                    >> "$f_unknown"
                ;;
        esac
    done

    # --- Crashing pods (CrashLoopBackOff, Error without counterpart, OOMKilled) ---
    if [[ -s "$f_crash" ]]; then
        printf "\n  Crashing pods:\n"
        while IFS='|' read -r pname pstatus prc page; do
            printf "  %s  %-55s  status:%-20s  %s restarts  age:%s\n" \
                "$FAIL" "$pname" "$pstatus" "$prc" "$page"
            print_events "$pname" "$ns"
            print_logs   "$pname" "$ns"
            printf "\n"
        done < "$f_crash"
    fi

    # --- Image pull failures ---
    if [[ -s "$f_pull" ]]; then
        printf "\n  Image pull failures:\n"
        while IFS='|' read -r pname pstatus page; do
            printf "  %s  %-55s  age:%s\n" "$FAIL" "$pname" "$page"
            local desc image pull_event
            desc=$(kubectl describe pod "$pname" -n "$ns" \
                --context "$kubectl_context" 2>/dev/null)
            image=$(echo      "$desc" | awk '/^  *Image:/{print $2; exit}')
            pull_event=$(echo "$desc" \
                | grep -E 'Back-off pulling|Failed to pull' \
                | tail -1 | sed 's/^[[:space:]]*//')
            [[ -n "${image:-}"      ]] && printf "         Image: %s\n" "$image"
            [[ -n "${pull_event:-}" ]] && printf "         Event: %s\n" "$pull_event"
            printf "\n"
        done < "$f_pull"
    fi

    # --- Pending pods ---
    if [[ -s "$f_pending" ]]; then
        printf "\n  Pending pods:\n"
        while IFS='|' read -r pname pstatus page; do
            printf "  %s  %-55s  status:%-20s  age:%s\n" \
                "$WARN" "$pname" "$pstatus" "$page"
            local sched_event
            sched_event=$(kubectl describe pod "$pname" -n "$ns" \
                --context "$kubectl_context" 2>/dev/null \
                | awk '/^Events:/,0' \
                | grep -E 'FailedScheduling|Insufficient' \
                | tail -2 | sed 's/^[[:space:]]*//')
            [[ -n "${sched_event:-}" ]] && while IFS= read -r ev; do
                printf "         %s\n" "$ev"
            done <<< "$sched_event"
            printf "\n"
        done < "$f_pending"
    fi

    # --- Unknown / ContainerStatusUnknown without a running counterpart ---
    if [[ -s "$f_unknown" ]]; then
        printf "\n  Unknown state (no running counterpart):\n"
        while IFS='|' read -r pname pstatus prc page; do
            printf "  %s  %-55s  status:%-25s  %s restarts  age:%s\n" \
                "$WARN" "$pname" "$pstatus" "$prc" "$page"
        done < "$f_unknown"
        printf "\n"
    fi

    # --- Running pods with high recent restart counts ---
    if [[ -s "$f_warn" ]]; then
        printf "\n  High restart count (running but recently unstable):\n"
        while IFS='|' read -r pname prc lr_age page; do
            printf "  %s  %-55s  %s restarts  last: %s ago  age:%s\n" \
                "$WARN" "$pname" "$prc" "$lr_age" "$page"
            print_logs "$pname" "$ns"
            printf "\n"
        done < "$f_warn"
    fi

    # --- Stale replicas grouped by app label ---
    if [[ -s "$f_stale" ]]; then
        printf "\n  Stale replicas (superseded by a running pod -- not actionable):\n"
        sort "$f_stale" | awk -F'|' '
            { counts[$1]++; statuses[$1] = $3 }
            END {
                for (l in counts)
                    printf "  [STALE]  %-45s  %d pod(s)  (%s)\n",
                        l, counts[l], statuses[l]
            }
        '
        printf "\n"
    fi

    # --- Per-namespace summary line ---
    local n_crash n_pull n_pending n_unknown n_warn issues
    n_crash=$(count_lines "$f_crash");   n_pull=$(count_lines   "$f_pull")
    n_pending=$(count_lines "$f_pending"); n_unknown=$(count_lines "$f_unknown")
    n_warn=$(count_lines "$f_warn")
    issues=$(( n_crash + n_pull + n_pending + n_unknown + n_warn ))

    if [[ $issues -eq 0 ]]; then
        printf "  %s  %d pods healthy" "$PASS" $(( healthy + stale ))
        [[ $stale -gt 0 ]] && printf "  (%d stale replicas)" "$stale"
        printf "\n"
    else
        printf "  %s  %d issue(s)  |  %d pods healthy  |  %d stale replicas\n" \
            "$FAIL" "$issues" "$healthy" "$stale"
    fi
}

# ---------------------------------------------------------------------------
# Sub-environment namespace discovery
# ---------------------------------------------------------------------------

# Identifies sub-environment namespaces by looking for their rabbitmq-<name>
# counterparts -- the paired naming is a reliable signal for application
# sub-environments vs. infrastructure namespaces.
discover_subenv_namespaces() {
    kubectl get ns --context "$kubectl_context" \
        --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
        | grep '^rabbitmq-' \
        | sed 's/^rabbitmq-//' \
        | sort
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    for dep in kubectl jq; do
        command -v "$dep" &>/dev/null \
            || { echo "Error: $dep is required but not installed" >&2; exit 1; }
    done

    kubectl config get-contexts "$kubectl_context" &>/dev/null \
        || { echo "Error: kubectl context '$kubectl_context' not found" >&2; exit 1; }

    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    echo ""
    echo "=== Korio Pod Health Check ==="
    echo "  Cluster : $cluster"
    echo "  Context : $kubectl_context"
    echo "  Time    : $(date)"
    [[ -n "$target_namespace" ]] \
        && echo "  Scope   : namespace '$target_namespace' + infra"
    $verbose && echo "  Mode    : verbose  (log tail: $log_tail lines)" || true
    echo ""

    # --- Infrastructure namespaces (always checked, pods only) ---
    echo "=== Infrastructure Namespaces ==="
    for ns in "${INFRA_NAMESPACES[@]}"; do
        echo ""
        echo "  -- $ns --"
        if ! namespace_exists "$ns"; then
            printf "  %s  (namespace not found)\n" "$INFO"
            continue
        fi
        check_pods "$ns"
    done

    # --- Sub-environment namespaces ---
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

    for subenv in "${subenvs[@]}"; do
        echo ""
        echo "=== Sub-environment: $subenv ==="

        # Application namespace: ExternalSecrets + pods
        echo ""
        echo "  -- $subenv --"
        if namespace_exists "$subenv"; then
            echo ""
            echo "  ExternalSecrets:"
            check_externalsecrets "$subenv"
            echo ""
            echo "  Pods:"
            check_pods "$subenv"
        else
            printf "  %s  (namespace not found)\n" "$INFO"
        fi

        # RabbitMQ namespace: pods only
        local rmq_ns="rabbitmq-${subenv}"
        echo ""
        echo "  -- $rmq_ns --"
        if namespace_exists "$rmq_ns"; then
            check_pods "$rmq_ns"
        else
            printf "  %s  (namespace not found)\n" "$INFO"
        fi
    done

    echo ""
    echo "=== Done ==="
    echo ""
}

main "$@"
