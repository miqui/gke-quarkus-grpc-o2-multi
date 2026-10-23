# Security review

**Full-repo review, 2026-10-23.** Scope: the gRPC services, the repository/SQL layer, error
handling, the Hazelcast client, the Gateway, NetworkPolicies, RBAC, IAM and Workload Identity
Federation in `gke-deploy.sh`, secrets handling, the Dockerfile and both CI workflows.

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | High | Unauthenticated, internet-facing API; worker identity is self-asserted | **1a fixed** (Cloud Armor allowlist); 1b-1d open |
| L1 | Low | Prometheus ClusterRole grants `nodes/proxy` | Open |
| L2 | Low | Hazelcast JMX agent jar downloaded with no checksum | Open |
| L3 | Low | `DB_SSLMODE=require` doesn't verify the Cloud SQL server certificate | Open |

## Vuln 1: unauthenticated API, worker IDs anyone can claim (High)

`k8s/gateway.yaml`, `src/main/java/dev/miqui/jobmanager/service/Workers.java` (`held()`)

`grpc.miqui.dev:443` routes every RPC to the pods: all of `JobService`, all of `WorkerService`
and gRPC reflection. No interceptor checks who the caller is. A worker's identity is just the
`worker_id` string in the request. `Workers.held()` only compares it with `lease_owner`, and
`GetJob`/`ListJobs` return `lease_owner` to anyone (`job_service.proto`, `Job.lease_owner`).

**Exploit scenario.** `grpcurl grpc.miqui.dev:443 list` gives the full schema through
reflection. From there an attacker can:

- read every job's `spec`, `result` and `error` with `ListJobs`;
- call `DeleteJob` or `CancelJob` on any job;
- read a RUNNING job's `lease_owner`, then call `CompleteJob` with that `worker_id` and a forged
  `result`, or `FailJob` to kill it;
- call `ClaimJob` in a loop to take work away from real workers.

**Fixes, in order of effort:**

- **1a. Network allowlist (done).** A Cloud Armor security policy, `grpc-allowlist`, is attached
  to the `job-manager-api` backend through a `GCPBackendPolicy` (`k8s/gateway.yaml`). It allows
  `API_ALLOWED_CIDRS` (comma-separated, at most 10; default: the operator's IP detected by
  `gke-deploy.sh`) and denies everything else with 403, which gRPC clients see as
  `PERMISSION_DENIED`. `gke-deploy.sh` rewrites the allow rule on every run, so re-running it after
  an IP change re-authorizes the new IP. The summary also prints the one-line `gcloud` update.
  `gke-teardown.sh` deletes the policy. This closes the API to the internet but is not
  authentication: anyone inside an allowed range still has full access.
- **1b. Authentication.** A Quarkus gRPC `ServerInterceptor` that validates a bearer token (OIDC
  JWT via `quarkus-oidc`, or a per-client API key held in Secret Manager), with separate scopes for
  clients and workers.
- **1c. Server-derived worker identity.** Take the worker identity from the token, not from
  `request.worker_id`. Otherwise a valid client can still pose as any worker.
- **1d. Reflection.** Turn off `quarkus.grpc.server.enable-reflection-service` in `%prod`, or allow
  it only for authenticated callers.

**Verify 1a** after `gke-deploy.sh` and an Argo CD sync:

```bash
gcloud compute backend-services list --global \
  --format='table(name, securityPolicy.basename())'     # the job-manager-api backend -> grpc-allowlist
grpcurl grpc.miqui.dev:443 grpc.health.v1.Health/Check  # from an allowed IP: SERVING
# From any other IP (e.g. a phone hotspot): Code: PermissionDenied
```

## Lower severity (defense in depth)

- **L1. Prometheus `nodes/proxy`** (`k8s/observability/prometheus-rbac.yaml`). The ClusterRole
  grants `get` on `nodes/proxy`, which gives full access to the kubelet API through the API server.
  `get` on `nodes/proxy` is a known route to exec in pods on the node, so a compromised Prometheus
  would get node-level access. *Fix:* drop `nodes/proxy`. `nodes/metrics` plus the
  `/metrics/cadvisor` non-resource URL are enough for kubelet and cAdvisor scraping.
- **L2. Unverified javaagent download** (`k8s/hazelcast-deployment.yaml`, init container). The JMX
  exporter jar comes from Maven Central on every start, over HTTPS at a pinned version but with no
  checksum check, and is loaded with `-javaagent` into the cache JVM. *Fix:* check a pinned
  SHA-256, or bake the jar into an image. Baking it in also lets the `0.0.0.0/0:443` egress rule go.
- **L3. Cloud SQL certificate not verified** (`application.properties`, `DB_SSLMODE=require`).
  pgjdbc's `require` encrypts the connection but does not verify the server certificate. The risk
  is low because the connection uses Cloud SQL's private IP. *Fix:* Crossplane already writes the
  server CA to `cloudsql-connection`. Mount it and use `sslmode=verify-ca` with `sslrootcert=`.

## Checked and found solid

- **SQL:** every query is a `PreparedStatement` with bound parameters, including the dynamic
  `WHERE` in `JobRepository.where()`.
- **Error handling:** unexpected exceptions become a generic `INTERNAL`
  (`GrpcErrorHandler`), so no stack traces or SQL text reach clients.
- **Input bounds:** a 64 KiB max inbound message size, plus per-field size limits on JSON and text.
- **Network:** default-deny ingress and egress in `default`. The API accepts traffic only from
  Google's load-balancer ranges. Hazelcast, which has no authentication, is reachable only from
  the API pods. The only internet ingress is the Gateway.
- **Cluster access:** private nodes, and the control plane is limited to the operator's `/32`.
  Workload Identity is used throughout. The node service account has minimal roles, not the
  default Editor account.
- **CI:** keyless Workload Identity Federation. The provider condition requires the owner's repos
  on `refs/heads/main`, and the impersonation binding names one repo. PRs never get
  `id-token: write`. Downloaded CLIs are checksum-verified.
- **Secrets:** 1Password `op://` references go into Secret Manager and reach the cluster through
  External Secrets. The ESO service account has `secretAccessor` on each secret, not project-wide.
  The only committed password is the local docker-compose default.
- **Containers:** non-root UID 10001, read-only root filesystem, all capabilities dropped,
  `seccomp: RuntimeDefault`, all enforced by Kyverno.

**Not security, but a bug (fixed):** `gke-deploy.sh` defaulted `GITHUB_REPO` to
`miqui/gke-quarkus-grpc-o2` (the original repo), so this repo's CI couldn't impersonate the push
service account and the original repo's main branch could. It now defaults to this repo. Re-running
`gke-deploy.sh` adds this repo's binding but doesn't remove the original's. Once the original repo
should no longer push here:

```bash
gcloud iam service-accounts remove-iam-policy-binding \
  ci-springboot-grpc-o2@k8s-dev-412419.iam.gserviceaccount.com --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe k8s-dev-412419 --format='value(projectNumber)')/locations/global/workloadIdentityPools/github/attribute.repository/miqui/gke-quarkus-grpc-o2"
```
