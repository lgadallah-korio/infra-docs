# Runbook: Auth-Node / MongoDB Degradation Causing Frontend 520s

## Symptom

Users report the application is broken. The browser console shows:

- `Failed to load resource: the server responded with a status of 520`
  for JS bundles, CSS, and `manifest.json`
- `manifest.json` (or other JSON assets) appears to contain
  `<!doctype html>` — i.e. HTML content instead of JSON
- The page skeleton (HTML shell) may render, but the app does not
  initialise because the JS bundle never loads

## Why this is misleading

The symptom looks like a routing misconfiguration or a missing build
artifact. The actual cause is typically MongoDB performance degradation
cascading through auth-node.

Every external NGINX location block includes `auth_request
/_auth-via-auth-node`, which makes a subrequest to auth-node before
proxying any request — including requests for static assets. If
auth-node cannot respond in time (because its MongoDB connection pool
is exhausted or queries are slow), NGINX returns 5xx for all requests.
Cloudflare converts an unexpected 5xx from the origin into a 520.

The HTML shell loads because it may be served from the browser cache
or arrived before the DB degraded. Everything fetched after that point
— JS, CSS, `manifest.json` — fails.

---

## Set variables before starting

```bash
export kenv="prod"     # environment (dev | test | platform | staging | prod | ...)
export sbenv="my"      # sub-environment (configure | preview | validate | accept | my)
```

---

## Phase 1: Rule out a routing or build artifact problem

Before assuming a DB issue, confirm whether the 520s are truly
blanket (all assets failing) or selective (only specific paths).

### Step 1a: Reproduce the 520 directly

Bypass the browser cache and check the raw response from outside
Cloudflare:

```bash
# Check the Content-Type and status of a failing asset:
curl -sI "https://my.korioclinical.com/app-<client>/manifest.json"
# 520 with Content-Type: text/html -> origin returned HTML; go to Phase 2
# 404 -> asset path is wrong; check NGINX routing config
# 200 with Content-Type: application/json -> browser cache issue; hard-refresh
```

### Step 1b: Check whether all assets are failing or just some

If only `manifest.json` fails but JS/CSS load, the issue is specific
to that path — investigate the NGINX location block for that path.

If all assets under `/app-<client>/` fail, the auth layer is the most
likely cause. Continue to Phase 2.

---

## Phase 2: Check auth-node health

### Step 2a: Check auth-node pod status

```bash
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep auth-node
# Expected: STATUS=Running, RESTARTS not climbing
```

If auth-node pods are in `CrashLoopBackOff` or restarting frequently,
consult the [pod health runbook](pod-health-troubleshooting.md) for
the crash cause before continuing here.

### Step 2b: Check auth-node logs for MongoDB errors

```bash
# Get the auth-node pod name:
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  -l app=auth-node -o name | head -1

# Then tail its logs:
kubectl logs <pod-name> -n "${sbenv}" --context "vozni-${kenv}-aks" \
  --tail=100
```

Look for:

| Log pattern | What it means |
|---|---|
| `MongooseError: buffering timed out` | Mongoose waited too long for a connection from the pool |
| `MongoNetworkError` / `connection refused` | Atlas is unreachable from the pod |
| `MongoServerSelectionError` | Atlas node selection timed out (cluster under stress) |
| `MongoPoolClosedError` | Connection pool was closed due to repeated failures |
| Repeated slow `auth/verify` request log lines | auth-node is responding but slowly |

If you see pool or timeout errors, proceed to Phase 3.

### Step 2c: Verify the auth endpoint from inside the cluster

Exec into any running pod in the same namespace and probe auth-node
directly:

```bash
kubectl exec -n "${sbenv}" --context "vozni-${kenv}-aks" \
  -it <any-running-pod> -- \
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" \
  "http://auth-node.${sbenv}.svc.cluster.local:8080/api/v1/auth/verify"
```

- **401 in < 1s** — auth-node is healthy; the token was absent/invalid
  but the service responded promptly. The problem is elsewhere.
- **401/500 after several seconds** — auth-node is alive but slow;
  MongoDB is likely the bottleneck.
- **Connection refused / no route to host** — auth-node is not
  accepting connections; check pod status (Phase 2a).

---

## Phase 3: Check MongoDB Atlas

### Step 3a: Check Atlas alerts

Log in to MongoDB Atlas and navigate to the cluster for `${kenv}`. Check:

- **Active alerts** — any `CONNECTIONS_PERCENT > 80%` or `HOST_DOWN`
  alerts are directly relevant (these are the configured alert
  thresholds in `terraform-infra/env-monitor/atlas_alerts.tf`)
- **Real-time performance panel** — look at the Operations/sec, Query
  Targeting, and Connection counts graphs over the incident window

### Step 3b: Check connection count

In Atlas > Cluster > Metrics > Connections:

- If the connection count is at or near the cluster's maximum, the
  pool is exhausted. Every new request is waiting for a connection to
  free up.
- The maximum connection count for the cluster tier is shown in Atlas
  under Cluster > ... > Connection String.

### Step 3c: Check slow queries

In Atlas > Performance Advisor or the Profiler:

- Look for queries with high execution time in the `auth` or user
  lookup collection
- A missing index on the field auth-node queries (`emails[0]` or the
  equivalent user lookup key) can cause full collection scans that
  degrade under concurrent load

### Step 3d: Check Datadog MongoDB dashboard

The Datadog MongoDB integration (configured in
`terraform-infra/env/helm/datadog-mongodb.tpl.yaml`) streams Atlas
metrics via the PrivateLink endpoint. Check the MongoDB dashboard in
Datadog for `${kenv}`:

- Query latency p95/p99
- Connection pool utilisation
- Operation rates

---

## Phase 4: Remediate

The appropriate action depends on what Phase 3 revealed.

### If connections are exhausted (CONNECTIONS_PERCENT alert or high count)

**Short-term:** Restart auth-node pods to flush in-flight connections
and let the pool re-establish cleanly:

```bash
kubectl rollout restart deployment/auth-node \
  -n "${sbenv}" --context "vozni-${kenv}-aks"

# Watch until rollout completes:
kubectl rollout status deployment/auth-node \
  -n "${sbenv}" --context "vozni-${kenv}-aks"
```

This does not fix the underlying load problem, but it clears stuck
connections and restores service while you investigate the root cause.

**Longer-term:** Investigate what caused the connection spike —
abnormal query volume, a missing index, or a client bug issuing
excessive requests. Resolve the root cause before closing the incident.

### If a slow query or missing index is identified

Create the index in Atlas (can be done online without downtime for
most collection sizes). Confirm with Performance Advisor that the slow
query no longer appears after the index is in place.

### If Atlas itself is degraded (HOST_DOWN alert or Atlas status page incident)

This is outside your control. Monitor the [MongoDB Atlas status page](https://status.mongodb.com/)
and wait for Atlas to recover. Communicate status to stakeholders.
Consider whether a temporary maintenance page is appropriate.

---

## Phase 5: Verify recovery

After remediation, confirm end-to-end recovery:

```bash
# Confirm auth-node is healthy:
kubectl get pods -n "${sbenv}" --context "vozni-${kenv}-aks" \
  | grep auth-node
# Expected: Running, RESTARTS not climbing

# Confirm asset loading is restored:
curl -sI "https://my.korioclinical.com/app-<client>/manifest.json"
# Expected: HTTP/2 200, Content-Type: application/json

# Confirm auth endpoint response time is normal:
kubectl exec -n "${sbenv}" --context "vozni-${kenv}-aks" \
  -it <any-running-pod> -- \
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" \
  "http://auth-node.${sbenv}.svc.cluster.local:8080/api/v1/auth/verify"
# Expected: 401 in < 0.5s (401 is correct — no token was provided)
```

---

## Quick-reference decision tree

```
Symptom: 520s on static assets / manifest.json returns HTML
          |
          +-- Step 1a: curl the failing asset directly
          |     404 -> routing problem; check NGINX location blocks
          |     200 -> browser cache; hard-refresh
          |     520 with text/html body -> origin returned an error; continue
          |
          +-- Step 1b: selective or blanket failures?
          |     Only manifest.json -> investigate that specific NGINX location
          |     All assets under /app-<client>/ -> auth layer suspect; continue
          |
          +-- Phase 2: check auth-node
          |     CrashLoopBackOff -> pod-health-troubleshooting.md
          |     Running but logs show MongooseError/timeout -> Phase 3
          |     Running, no errors, fast response -> not auth-node; investigate
          |       NGINX config or Cloudflare routing
          |
          +-- Phase 3: check Atlas
                CONNECTIONS_PERCENT alert or high count -> Phase 4 (restart auth-node)
                Slow queries, missing index -> create index; monitor
                Atlas HOST_DOWN / external incident -> wait; communicate status
```

---

## Summary: commands used and their purpose

| Command | Purpose |
|---|---|
| `curl -sI <asset-url>` | Check HTTP status and Content-Type of a failing asset, bypassing browser cache |
| `kubectl get pods -n <ns> -l app=auth-node` | Check auth-node pod health and restart count |
| `kubectl logs <pod> -n <ns> --tail=100` | Read auth-node logs for MongoDB error patterns |
| `kubectl exec ... -- curl ... auth-node:8080/api/v1/auth/verify` | Probe auth-node response time from inside the cluster |
| `kubectl rollout restart deployment/auth-node` | Restart auth-node to flush exhausted connections |
| `kubectl rollout status deployment/auth-node` | Confirm rollout completes successfully |
