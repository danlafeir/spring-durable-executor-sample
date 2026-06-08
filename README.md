# spring-durable-executor-sample

An order-processing service that demonstrates and chaos-tests the
[durable-executor](../durable-executor) library.

Every submitted order goes through a four-step workflow
(VALIDATING → RESERVED → CHARGED → FULFILLED). Each step updates a row in
PostgreSQL and then sleeps for a configurable delay so there is always work
in-flight when pods are killed. The library's `@Durable` annotation ensures
every in-flight order is retried to completion even after arbitrary pod kills,
regardless of which step the JVM was executing when it died.

---

## How `@Durable` is used

### The durability gap problem

A naïve design calls the processing method with `@Async` and returns the HTTP
202 immediately. If the pod dies between the DB write and the async task being
picked up from the thread-pool queue, the order sits in `CREATED` forever —
no durable record was ever written, so nothing recovers it.

### Two-layer `@Durable` pattern

This sample closes the gap with two `@Durable` annotations on two different
methods, each covering a different window:

```
POST /orders
  │
  ├─ orderService.create()          writes order row, status = CREATED
  │
  ├─ orderDispatcher.dispatch()     ← @Durable (layer 1)
  │    │  aspect writes dispatch record BEFORE proceeding
  │    │  dispatch() body submits processOrder() to thread pool
  │    │  dispatch() returns → aspect deletes dispatch record
  │    └─ HTTP 202 goes out         record was on disk before this line
  │
  └─ processOrder() on thread pool  ← @Durable (layer 2)
       aspect writes processOrder record BEFORE the workflow begins
       VALIDATING → sleep → RESERVED → sleep → CHARGED → sleep → FULFILLED
       on success: record deleted
       on failure: record kept → DurableRecovery retries on next startup
                                 → if retry also fails: moves to DLQ
```

**Layer 1 (`OrderDispatcher.dispatch`)** — `dispatch()` is synchronous. The
`@Durable` aspect writes a record before the method body runs, so the record
exists on disk before the 202 is returned. If the pod dies before `dispatch()`
returns the record survives and recovery re-submits `processOrder` on the next
boot.

**Layer 2 (`OrderProcessingService.processOrder`)** — covers a pod kill that
happens after `dispatch()` has already returned (and its record deleted) but
while `processOrder` is still running in the thread pool. The record exists for
the entire duration of the workflow.

The narrow window between the two records (after the dispatch record is deleted
and before the processOrder record is written) is sub-millisecond and is the
only unrecoverable window that remains without a transactional outbox.

---

## Repository layout

```
k8s/
  postgres.yaml       StatefulSet + headless service for Postgres
  app.yaml            ConfigMap, services, and 3-replica StatefulSet for the app

src/main/java/com/example/orderservice/
  controller/
    OrderController.java     POST /orders, GET /orders, GET /orders/{id}
    AdminController.java     GET /admin/audit, GET /admin/executions, GET /admin/stuck
  service/
    OrderService.java        Creates Order rows; no durable logic
    OrderDispatcher.java     @Durable layer 1 — writes record before 202 goes out
    OrderProcessingService.java  @Durable layer 2 — four-step workflow with delays

load-test.sh    Submits orders continuously at a configurable rate
chaos.sh        Kills a random order-service pod every N seconds;
                every POSTGRES_KILL_EVERY kills also kills postgres to
                drive recovery failures into the DLQ
validate.sh     Polls /admin/audit until all orders are FULFILLED or times out
```

---

## Automated test (agent-friendly)

`run-chaos-test.sh` orchestrates the full cycle — build, deploy, load + chaos,
wait for recovery, validate, write results — in a single unattended invocation:

```bash
# Full run (build image, deploy, test, validate)
./run-chaos-test.sh

# Skip build and deploy when the cluster is already running
./run-chaos-test.sh --skip-build --skip-deploy

# Tune parameters
./run-chaos-test.sh \
  --load-rate 0.5 \        # seconds between orders (0.5 = 2/s)
  --chaos-interval 8 \     # seconds between pod kills
  --chaos-pg-every 5 \     # kill postgres on every 5th app kill
  --duration 180 \         # seconds to run load+chaos
  --validate-timeout 600   # seconds to wait for all orders to FULFILL
```

Results are written to `output/run-TIMESTAMP/`:
- `summary.md` — pass/fail verdict, DLQ count, liveness probe failures, configuration
- `chaos.log`, `load-test.log`, `validate.log` — raw output from each phase
- `audit-pre-validate.json`, `audit-final.json` — DB state snapshots
- `dlq-pre-validate.json`, `dlq-final.json` — dead letter queue snapshots

Exit codes: `0` = all orders FULFILLED, `1` = orders remain incomplete, `2` = pre-flight failure.

**What to check in `summary.md`:**

| Check | Expected |
|---|---|
| `validate.sh` | FAIL is normal if CREATED orphans exist (pre-dispatch window); PASS means zero incomplete orders |
| `DLQ populated` | YES when postgres is killed during startup recovery — confirms the DLQ path works |
| `Liveness probe deaths` | NONE — any value > 0 means concurrent startup recovery is not working |

---

## Building and deploying

The Dockerfile uses a composite Gradle build. Both this repo and the
`durable-executor` library must be siblings under the same parent directory.
Run `docker build` from that parent:

```bash
# from the directory that contains both durable-executor/ and spring-durable-executor-sample/
docker build -f spring-durable-executor-sample/Dockerfile -t order-service:latest .
```

Deploy to a local Kubernetes cluster (Rancher Desktop, kind, or minikube):

```bash
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/app.yaml
kubectl rollout status statefulset/postgres
kubectl rollout status statefulset/order-service
```

The `order-service` LoadBalancer stays `<pending>` on local clusters. Use
port-forward to reach it:

```bash
# auto-reconnects when a pod is killed
while true; do kubectl port-forward svc/order-service 8080:80; sleep 1; done
```

---

## Running the chaos test

```
terminal 1 — submit orders continuously
  ./load-test.sh http://localhost:8080 0.5      # 2 orders/sec

terminal 2 — kill a random pod every 8 s; kill postgres every 5th kill
  ./chaos.sh order-service 8

  (run for 2–3 minutes, then Ctrl-C both)

terminal 3 — wait for all pods to stabilise, then validate
  kubectl rollout status statefulset/order-service
  ./validate.sh http://localhost:8080 600
```

`validate.sh` exits 0 only when every order in the database has reached
`FULFILLED` and all durable stores are empty.

### What to observe

| Endpoint | What it shows |
|---|---|
| `GET /admin/audit` | Total orders, counts by status, pending executions, `allComplete` flag |
| `GET /admin/executions` | All currently open durable records on the responding pod |
| `GET /admin/stuck` | Executions whose `createdAt` is older than 5 minutes |
| `GET /durable/dlq` | Executions that failed recovery and were moved to the dead letter queue |

### Expected outcomes

**Orders in VALIDATING / RESERVED / CHARGED** — pod was killed mid-workflow.
On the next restart `DurableRecovery` picks up the record and retries the
method from the beginning. Because all status updates are idempotent the order
advances and eventually reaches FULFILLED.

**Orders stuck in CREATED with no durable record** — the pod was killed after
the DB write but before `dispatch()` wrote its record. This is the remaining
pre-dispatch window. The client received a TCP reset rather than a 202, so no
durability promise was ever made.

**DLQ entries** — `processOrder` was retried during startup recovery but the
retry itself failed (typically because postgres was also down at that moment).
The library moves the record to the dead letter store rather than retrying
indefinitely. DLQ entries appear reliably when `chaos.sh` kills both an
order-service pod and postgres at the same time and the pod's readiness probe
initialDelay is short enough that recovery fires before postgres finishes
restarting.

---

## Key configuration knobs

Set via the ConfigMap in `k8s/app.yaml`:

| Env var | Default | Effect |
|---|---|---|
| `ORDER_STEP_DELAY_MS` | `3000` | Sleep between workflow steps (ms). Longer = more time in-flight per pod kill. |
| `DURABLE_STORE_PATH` | `/app/data/durable-executions` | Directory for pending durable records (on the pod's PVC). |
| `DURABLE_DEAD_LETTER_PATH` | `/app/data/durable-dlq` | Directory for failed executions. |
| `DURABLE_DLQ_ENDPOINT_ENABLED` | `true` | Expose `GET /durable/dlq`. |
| `DURABLE_STUCK_GRACE_PERIOD` | `PT10S` | `-deleted` files older than this are treated as stuck and moved to DLQ on next boot. |
| `DURABLE_RETRY_THREADS` | `2` | Thread pool size for concurrent startup/scheduled recovery. |
