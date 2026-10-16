# GKE Operations Notes

Short explanations of cluster events that look alarming but aren't. The cluster has a zonal
control plane (`us-central1-a`) and multi-zone workers: `e2-standard-2` nodes in
`us-central1-a/b/c`, autoscaling 3..6 nodes in total, balanced across zones (`gke-deploy.sh`).

## Multi-zone workers: what survives what

| Failure | Effect on the gRPC API |
|---|---|
| One node | Its replica is rescheduled; the other two keep serving (hostname spread). |
| One zone (`b` or `c`) | Two replicas in the other zones keep serving; the Gateway's NEGs drop the dead zone's endpoints; the autoscaler adds a node elsewhere if needed. |
| Zone `a` | The data plane keeps serving, but the control plane is down: no scheduling, scaling or `kubectl` until it recovers. A regional cluster removes this, at the cost of GKE's free-tier credit. |
| Node drain / upgrade | `k8s/pdb.yaml` keeps >= 2 replicas available. |

Still single-zone, so a zone outage can still hurt: Hazelcast (`replicas: 1`), Cloud SQL (zonal
unless `availabilityType: REGIONAL`), and PVC-backed tools (OpenObserve, Trivy - a zonal disk
pins its pod to one zone).

```bash
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -l app=job-manager-api -o wide \
  | awk 'NR>1{print $7}' | xargs -I{} kubectl get node {} -L topology.kubernetes.io/zone --no-headers
kubectl get pdb job-manager-api
```

## Spreading an existing cluster across zones

`gke-deploy.sh` only sets `--node-locations` when it creates the cluster; on an existing one it
warns and leaves the pool alone. The clean path is a rebuild (`gke-teardown.sh`, then
`gke-deploy.sh`). In place, order matters:

```bash
# 1. Switch autoscaling to pool-wide totals first. Per-zone --min-nodes=3 x 3 zones would
#    otherwise force 9 nodes.
gcloud container node-pools update default-pool --cluster $CLUSTER --zone $ZONE \
  --enable-autoscaling --location-policy=BALANCED --total-min-nodes=3 --total-max-nodes=6
# 2. Check regional CPU quota: each new zone starts with the pool's current per-zone node count
#    (4 nodes today -> up to 12 x e2-standard-2 = 24 vCPU until the autoscaler scales down).
gcloud compute regions describe us-central1 --format=json \
  | jq '.quotas[] | select(.metric=="CPUS")'
# 3. Add the zones. Nodes in the new zones come up, then the autoscaler trims back to balanced.
gcloud container clusters update $CLUSTER --zone $ZONE \
  --node-locations=us-central1-a,us-central1-b,us-central1-c
# 4. Existing pods don't move on their own; restart the API so the zone spread takes effect.
kubectl rollout restart deployment/job-manager-api
```

## API replicas stacked in one zone (soft zone spread) - fix documented, not applied

**Observed 2026-10-16** on the first multi-zone build (`gke-architecture-zones.drawio`):

- 16:01 a Trivy scan pod triggered a scale-up in `us-central1-a` (the b and c nodes were 75-85%
  CPU-requested).
- 16:02 an API rollout put **all 3 `job-manager-api` replicas in zone a**, two of them on the new,
  empty node.
- 16:27 the autoscaler drained that node. The PDB let one pod go at a time, and the two
  replacements landed in b and c (1/1/1), because those zones now had room.

**Why:** the zone constraint in `k8s/deployment.yaml` is `whenUnsatisfiable: ScheduleAnyway`, so
it only affects the scheduler's *scoring*, as one factor among several. Here the preference for an
empty node won. The spread holds only when every zone has spare CPU, so the next scan burst or
rollout can stack the replicas again. A zone-a outage at such a moment would take out every replica
along with Cloud SQL.

**How to check:** the node name encodes the zone's instance group, or use:

```bash
kubectl get pods -l app=job-manager-api -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers \
  | while read p n; do echo "$p $(kubectl get node $n -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"; done
# Kubernetes Events expire after ~1 h; autoscaler decisions stay in Cloud Logging for 30 days:
gcloud logging read 'logName="projects/k8s-dev-412419/logs/container.googleapis.com%2Fcluster-autoscaler-visibility" AND (jsonPayload.decision.scaleUp:* OR jsonPayload.decision.scaleDown:*)' \
  --freshness=1d --limit 20 \
  --format='table(timestamp, jsonPayload.decision.scaleUp.increasedMigs[0].mig.zone, jsonPayload.decision.scaleDown.nodesToBeRemoved[0].node.name)'
```

**The fix (not applied; the cluster runs with the soft spread):** make the zone constraint a hard
filter. Leave the hostname constraint soft, since 6 replicas on 3 nodes have to share nodes anyway.

```yaml
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule      # was ScheduleAnyway
          nodeTaintsPolicy: Honor               # required, see below
          matchLabelKeys: [pod-template-hash]   # balance each rollout's ReplicaSet on its own
          labelSelector:
            matchLabels:
              app: job-manager-api
```

- `DoNotSchedule`: a pod that would make the zones uneven by more than 1 is not placed. If the
  zone it needs is full, the pod stays Pending, and the cluster autoscaler (which simulates topology
  spread) adds a node in *that* zone.
- `nodeTaintsPolicy: Honor`: **don't use `DoNotSchedule` without it.** When a whole zone fails,
  Kubernetes evicts its pods at the normal rate. It only pauses evictions on small clusters when a
  zone is *partly* unhealthy. The evicted pod's replacement then needs a zone, but the dead zone's
  NotReady nodes still count as a domain with 0 pods. Placing the pod in b or c would make the skew
  2, so it would stay Pending for the whole outage. `Honor` drops nodes with taints the pod doesn't
  tolerate (`node.kubernetes.io/unreachable:NoSchedule`) from the count.
- `matchLabelKeys: [pod-template-hash]`: during a rollout, old and new pods aren't counted together,
  so the new ReplicaSet ends up 1/1/1.

**Trade-offs:** an HPA scale-out into a full zone waits ~1-2 min for a node instead of starting
elsewhere. A zone out of `e2-standard-2` capacity leaves the pods that zone needs Pending (the other
zones still take theirs). At the HPA max of 6, the replicas fit as 2/2/2 (each zone allows up to 4 nodes).

**To verify after applying:** cordon zone b's node, then delete the zone-b API pod. Its replacement
should stay Pending, not go to a or c, until you uncordon the node.

## HA plan for the short-lived dev cluster (proposed, not applied)

The cluster runs for a couple of hours at a time to prove high availability and resilience. That
changes the trade-offs: cost per hour and slower scale-outs barely matter, and a demo that fails
for an avoidable reason does. Ordered by value to the demo. Background:
[Mastering topology spread constraints and pod affinity](https://cast.ai/blog/mastering-topology-spread-constraints-and-pod-affinity/).

**Recommended first:** 1, 5 and 10 together give a repeatable "lose a zone under load, zero failed
requests" result.

### Spread constraints

1. **Apply the hard zone spread** from the section above (`DoNotSchedule` + `nodeTaintsPolicy:
   Honor` + `matchLabelKeys: [pod-template-hash]`). The cost, a 1-2 min wait for a node on
   scale-out, doesn't matter on a demo cluster. The soft spread can stack all replicas in one zone,
   as it did on 2026-10-16.
2. **Don't add `minDomains: 3`.** With `Honor`, a dead zone drops out of the count, leaving 2
   domains. That's under `minDomains`, so the scheduler treats the global minimum as 0 and the
   replacement pod stays Pending for the whole outage. `BALANCED` autoscaling with
   `total-min-nodes=3` already keeps a node in every zone.
3. **Keep the hostname constraint soft.** At the HPA max of 6 replicas on as few as 3 nodes, pods
   have to share nodes.
4. **No `podAffinity` from the API to Hazelcast.** With one Hazelcast replica it would pull every
   API pod into one zone.

### Single points of failure

5. **Hazelcast `replicas: 1`.** Run 3 members with Kubernetes discovery and
   `partition-group: ZONE_AWARE` (backups in another zone), the same hard zone spread, and a PDB.
   Or keep one member and explicitly show the API degrading gracefully when the cache is lost.
6. **Cloud SQL `availabilityType: ZONAL`** (`k8s/platform/postgres-composition.yaml`). `REGIONAL`
   costs little extra for a 2-hour cluster and gives a real failover to run under load
   (`gcloud sql instances failover`).
7. **Zonal control plane.** The reason for staying zonal is GKE's free-tier credit; a regional
   cluster adds about $0.10/hour (check current pricing), which is negligible here. It makes the
   "zone a" row of the table above survivable.

### Fast, observable failover

8. **Spare capacity per zone (balloon pods).** The 2026-10-16 stacking happened because zones b and
   c were 75-85% CPU-requested. A low-priority `pause` Deployment (negative `PriorityClass`, ~1 per
   zone, zone-spread) gets preempted by failover pods, which then start in seconds instead of
   waiting for a node.
9. **Rebalance after recovery.** Spread constraints apply only at scheduling time, so after a zone
   returns the replicas stay 2/1/0. Either install the descheduler with
   `RemovePodsViolatingTopologySpreadConstraint` to show self-healing, or make
   `kubectl rollout restart deployment/job-manager-api` a runbook step.
10. **Scripted failure drill**, the same on every cluster run, each under k6 load with error rate and
    p99 recorded to `experiments/`:

    ```bash
    # Zone loss: evicts the zone's pods and exercises nodeTaintsPolicy: Honor
    kubectl taint nodes -l topology.kubernetes.io/zone=us-central1-b node.kubernetes.io/unreachable=:NoExecute
    kubectl taint nodes -l topology.kubernetes.io/zone=us-central1-b node.kubernetes.io/unreachable=:NoSchedule
    # ...observe, then recover:
    kubectl taint nodes -l topology.kubernetes.io/zone=us-central1-b node.kubernetes.io/unreachable:NoSchedule-
    kubectl taint nodes -l topology.kubernetes.io/zone=us-central1-b node.kubernetes.io/unreachable:NoExecute-
    # Voluntary disruption: the PDB keeps >= 2 replicas serving
    kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
    # Database failover (needs item 6)
    gcloud sql instances failover <instance>
    ```

### Optional

11. **Enforce spread with Kyverno.** A policy requiring (or injecting) a zone spread on any
    Deployment with `replicas > 1` keeps new workloads from reintroducing the stacking problem.
12. **Leave single-zone tools alone.** OpenObserve, Trivy, Grafana and Prometheus aren't under test;
    their zonal disks pin them to one zone, and that's accepted.

## "Cluster Autoscaler skipped scaling up default-pool" for `node-collector-*`

Seen as a `NotTriggerScaleUp` note, e.g.:

> The pod node-collector-6cdc7f778f-265nh has a nodeSelector or nodeAffinity block configured...
> Because the default-pool node pool does not carry the matching labels... the Cluster Autoscaler
> skipped scaling up this pool.

**Benign - no action needed.**

- `node-collector` is Trivy Operator's per-node scan job ([TRIVY.md](TRIVY.md)). The operator pins
  each one to a single node with a `kubernetes.io/hostname` nodeSelector.
- A pod pinned to one node cannot run on any other, and a new node has a different hostname, so
  adding nodes never helps. The autoscaler correctly reports this and skips the scale-up.
- It typically appears when the target node is being removed. The first scan pass scans every
  workload at once and can briefly add a node; once idle, the autoscaler scales it back down
  (`ScaleDown ... marked the node as toBeDeleted/unschedulable`). A collector job pinned to that
  node becomes unschedulable and is deleted with it.
- The `NodeRegistrationCheckerDidNotRunChecks` warning on such a node is noise; its message says
  the node was ready and registered.

### Verify

```bash
kubectl get nodes                                             # one node Ready,SchedulingDisabled = scale-down in progress
kubectl get events -A --sort-by=.lastTimestamp | grep -E "node-collector|ScaleDown"
kubectl get pods -A --field-selector=status.phase=Pending     # expect none
kubectl get pods -n trivy-system                              # operator + trivy-server-0 Running
```

If no `node-collector-*` job shows up after the next scan cycle, check
`kubectl logs deploy/trivy-operator -n trivy-system`.

## gcloud checks for a fresh cluster

Read-only commands used to validate a rebuild (`gke-deploy.sh` + `gke-bootstrap.sh`). Project
`k8s-dev-412419`, zone `us-central1-a`, cluster `dev-cluster`.

```bash
export PROJECT=k8s-dev-412419 ZONE=us-central1-a CLUSTER=dev-cluster

# Before a rebuild: confirm the account, project, and that nothing is left over
gcloud auth list
gcloud config get-value project
gcloud container clusters list --project $PROJECT             # empty = fresh start
gcloud sql instances list --project $PROJECT                  # empty = no leftover Cloud SQL

# CI prerequisites (shared WIF provider, this project's CI service account)
gcloud projects describe $PROJECT --format='value(projectNumber)'
gcloud iam workload-identity-pools providers describe github-oidc \
  --workload-identity-pool=github --location=global --project $PROJECT --format='value(name,state)'
gcloud iam service-accounts describe ci-springboot-grpc-o2@$PROJECT.iam.gserviceaccount.com \
  --format='value(email)'

# Secrets External Secrets reads (seeded by gke-secrets-seed.sh)
gcloud secrets list --project $PROJECT --format='value(name)'

# Image pushed by CI (Argo CD Image Updater picks the highest tag)
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/$PROJECT/springboot-grpc-o2/job-manager-api \
  --include-tags --format='value(tags,createTime)'

# Node pool: machine type, boot disk, initial size; and the actual per-node disks
gcloud container node-pools describe default-pool --cluster $CLUSTER --zone $ZONE --project $PROJECT \
  --format='value(config.diskSizeGb,config.diskType,config.machineType,initialNodeCount)'
gcloud compute disks list --project $PROJECT --filter="name~gke-$CLUSTER" \
  --format='table(name,sizeGb,type.basename())'

# Public edge: certificate state and the API's static IP
gcloud certificate-manager certificates describe grpc-cert --format='value(managed.state)'
gcloud compute addresses describe grpc-ip --global --format='value(address)'
```

## Why the cluster runs 4 nodes, not 3

Observed on the 2026-10-05 rebuild: `TriggeredScaleUp ... 3->4 (max: 5)` caused by a Trivy
`scan-vulnerabilityreport-*` pod. The autoscaler works on **requests**, not usage: with the full
platform synced, the three `e2-standard-2` nodes (~1.93 CPU allocatable each) were 83-93%
CPU-requested, so the scan pod fit nowhere. Total requests (~6.5 CPU) exceed three nodes, so the
fourth node stays after the scans finish. To get back to 3, lower platform CPU requests or limit
Trivy's concurrent scan jobs.

```bash
kubectl get events -A --field-selector reason=TriggeredScaleUp \
  -o custom-columns='T:.lastTimestamp,NS:.metadata.namespace,OBJ:.involvedObject.name,MSG:.message'
kubectl describe nodes | grep -A8 "Allocated resources" | grep -E "cpu|memory"
```

## Symptoms seen on the first rebuild (2026-10-05) and their fixes

### API pods `Init:CreateContainerConfigError` for ~10 minutes after bootstrap

`secret "postgres-credentials" not found`, then `couldn't find key privateIP in Secret
default/cloudsql-connection`. **Benign:** Crossplane is still creating Cloud SQL, and the pods
start on their own once the instance and its connection secret exist. `postgres-exporter` shows
the same error for the same reason. A one-off Kyverno `disallow-latest-tag` audit event on the
first pods is also expected: they start from `:latest` until Image Updater pins the CI tag.

```bash
kubectl get postgresinstance -A                 # READY False -> True when Cloud SQL is up
```

### Trivy: no VulnerabilityReport for the `job-manager-api` container

Scan jobs failed with `DENIED: Permission 'artifactregistry.repositories.downloadArtifacts' denied
on resource ... repositories/springboot-grpc-o2`. Scan jobs authenticate with the Workload
Identity token of KSA `trivy-system/trivy-operator`, and that principal had no access to the repo.

**Fix:** `gke-deploy.sh` grants it `roles/artifactregistry.reader` on the repo. On an existing
cluster, run the same binding by hand:

```bash
gcloud artifacts repositories add-iam-policy-binding springboot-grpc-o2 --location=us-central1 --project=k8s-dev-412419 --role=roles/artifactregistry.reader --member="principal://iam.googleapis.com/projects/220906294299/locations/global/workloadIdentityPools/k8s-dev-412419.svc.id.goog/subject/ns/trivy-system/sa/trivy-operator"
```

Keep it on one line: a terminal that wraps a long command can add line breaks when you copy it,
and the shell then runs the pieces as separate commands (`argument --member --role: Must be
specified`).

The next attempt got past the registry and was **OOMKilled**
(`"container":"job-manager-api","status.reason":"OOMKilled"` in the operator log): the Quarkus
fast-jar is ~150 jars, and the 500M chart default isn't enough to analyse them.
**Fix:** `trivy.resources.limits.memory: 1Gi` in `k8s/trivy-operator/trivy-operator-values.yaml`,
with the request left at 100M so scheduling is unchanged.

**Force a rescan.** Reports are labelled with the **ReplicaSet** name, not the Deployment
name, so `-l trivy-operator.resource.name=job-manager-api` matches nothing:

```bash
RS=$(kubectl get rs -n default -l app=job-manager-api -o jsonpath='{.items[?(@.status.replicas>0)].metadata.name}')
kubectl delete vulnerabilityreports -n default -l trivy-operator.resource.name=$RS
kubectl get vulnerabilityreports -n default -o wide | grep job-manager-api   # expect a row for the job-manager-api container
kubectl logs -n trivy-system deploy/trivy-operator --since=10m | grep '"container":"job-manager-api"'   # errors, if any
```

### Trivy: OpenObserve scan jobs fail on every attempt

`unable to find the specified image "o2cr.ai/openobserve/openobserve:v0.92.2" ... GET
https://public.ecr.aws/v2/zinclabs/openobserve/manifests/v0.92.2: DENIED: Not Authorized`.
`o2cr.ai` redirects to public ECR, which refuses Trivy's pull (the kubelet pulls fine).
**Fix:** we don't scan it: `trivyOperator.excludeImages: "o2cr.ai/openobserve/*"`.

### Prometheus OOMKilled once during bootstrap

`Last State: Terminated, Reason: OOMKilled` on the prometheus pod, preceded in its log by
`Failed to send batch, retrying` and `Remote storage resharding from=1 to=44`. OpenObserve wasn't
accepting writes yet, so remote_write scaled up to 44 shards, each buffering samples in memory,
and Prometheus went past its 512Mi limit. **Fix:** `queue_config` caps remote_write at 4 shards
x 2500 samples (`k8s/observability/config/prometheus.yml`), and the memory limit is now 768Mi.
See PROMETHEUS.md section 7.

```bash
kubectl get pod -n observability -l app=prometheus          # RESTARTS 0
kubectl describe pod -n observability -l app=prometheus | grep -A3 "Last State"
```

### Argo CD `observability` stuck OutOfSync after a Prometheus config change

Message: `one or more objects failed to apply, reason: configmaps "prometheus-config-<old-hash>"
not found. Retrying attempt #N`. The Prometheus config is a `configMapGenerator` ConfigMap, so
every change gives it a new name. The new ConfigMap and Deployment were applied fine and
Prometheus was running the new config. But the self-heal sync had listed the *old* ConfigMap
among its resources, and once that was pruned, every retry failed on it. A hard refresh doesn't
clear it, because the running operation keeps its resource list.

**Fix:** terminate the operation, then start a normal sync, in the Argo CD UI (*Terminate*, then
*Sync*) or:

```bash
kubectl patch application observability -n argocd --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl patch application observability -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'
kubectl get application observability -n argocd   # Synced / Healthy
```
