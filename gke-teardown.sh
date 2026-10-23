#!/usr/bin/env bash
#
# gke-teardown.sh — delete what gke-deploy.sh/gke-bootstrap.sh created, in dependency order:
#   1. In-cluster: stop Argo CD reconciling, then delete the Gateway (-> Google load balancer)
#      and the PostgresInstance (-> Crossplane deletes the Cloud SQL instance) and wait for both
#      to be gone - deleting the cluster first would orphan them, still billing
#   2. GKE cluster
#   3. Leftovers: any Cloud SQL instance this platform labelled, the load balancer's forwarding
#      rule on grpc-ip, network endpoint groups in the VPC, and the PVCs' persistent disks (a
#      cluster deletion leaves both behind)
#   4. Private Service Access peering + range, static IP, SSL policy, Cloud Armor policy,
#      Cloudflare A record
#   5. Firewall rules in the VPC, Cloud NAT, Cloud Router, subnet, VPC
#
# Kept by default (free or pennies, and slow/awkward to recreate) - removed with --purge:
#   Artifact Registry repo + images, Certificate Manager cert/map/DNS authorization (+ its
#   Cloudflare CNAME), Secret Manager secrets, service accounts, GitHub Workload Identity pool.
#
# Usage:
#   PROJECT_ID=k8s-dev-412419 ./gke-teardown.sh
#   PROJECT_ID=k8s-dev-412419 ./gke-teardown.sh --yes            # skip confirmation
#   PROJECT_ID=k8s-dev-412419 ./gke-teardown.sh --purge          # also the persistent resources
#   op run --env-file=.env -- env PROJECT_ID=... ./gke-teardown.sh   # + Cloudflare DNS cleanup
#
# Overridable env vars match gke-deploy.sh.
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR
cd "$(dirname "$0")"

# ---- Config ---------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required, e.g. PROJECT_ID=k8s-dev-412419 ./gke-teardown.sh}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
NODE_ZONES="${NODE_ZONES:-us-central1-a,us-central1-b,us-central1-c}"
CLUSTER="${CLUSTER:-dev-cluster}"
VPC="${VPC:-dev-vpc}"
SUBNET="${SUBNET:-dev-subnet}"
ROUTER="${ROUTER:-dev-router}"
NAT="${NAT:-dev-nat}"
REPO="${REPO:-springboot-grpc-o2}"
DOMAIN="${DOMAIN:-miqui.dev}"
API_HOST="${API_HOST:-grpc.${DOMAIN}}"

PSA_RANGE_NAME="cloudsql-psa-range"
IP_NAME="grpc-ip"
SSL_POLICY="grpc-tls"
ARMOR_POLICY="grpc-allowlist"
DNS_AUTH="grpc-dns-auth"
CERT="grpc-cert"
CERT_MAP="grpc-cert-map"
CERT_MAP_ENTRY="grpc-cert-map-entry"
SERVICE_ACCOUNTS=(gke-dev-nodes crossplane-gcp external-secrets argocd-image-updater ci-springboot-grpc-o2)
PROJECT_ROLES=(
  "gke-dev-nodes=roles/container.defaultNodeServiceAccount"
  "crossplane-gcp=roles/cloudsql.admin"
  "crossplane-gcp=roles/compute.networkUser"
)
SECRETS=(postgres-app-password grafana-admin-user grafana-admin-password
         openobserve-root-email openobserve-root-password)
WIF_POOL="github"

ASSUME_YES=0
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge)  PURGE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { echo "    not found, skipping"; }
wait_until() { # wait_until <timeout seconds> <description> <command...>: poll until command succeeds
  local deadline=$(( $(date +%s) + $1 )) what="$2"; shift 2
  until "$@"; do
    if [[ $(date +%s) -ge $deadline ]]; then echo "    WARNING: timed out waiting for $what" >&2; return 1; fi
    sleep 15
  done
}

command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found" >&2; exit 1; }

# ---- Confirmation -----------------------------------------------------------
cat <<EOF
About to DELETE the following resources in project '$PROJECT_ID':

  Cloud SQL            : the platform's instance(s) - ALL DATA IS LOST (no backups are kept)
  Load balancer        : Gateway for $API_HOST, static IP $IP_NAME, SSL policy $SSL_POLICY,
                         Cloud Armor policy $ARMOR_POLICY
  GKE cluster          : $CLUSTER (zone $ZONE)
  Persistent disks     : the PVCs' disks (OpenObserve, Trivy) - their data is lost
  Network              : NEGs, PSA peering/range, firewall rules, $NAT / $ROUTER, $SUBNET / $VPC
  DNS                  : A record $API_HOST (if CLOUDFLARE_API_TOKEN is set)
EOF
if [[ "$PURGE" -eq 1 ]]; then
  cat <<EOF
  --purge              : Artifact Registry $REPO (ALL IMAGES), certificate $CERT + map + DNS
                         authorization, Secret Manager secrets, service accounts
EOF
else
  echo "  Kept (use --purge) : Artifact Registry, certificate, secrets, service accounts, WIF pool"
fi
echo
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Proceed? Type 'delete' to confirm: " CONFIRM
  [[ "$CONFIRM" == "delete" ]] || { echo "Aborted."; exit 0; }
fi

gcloud config set project "$PROJECT_ID"
API_IP=$(gcloud compute addresses describe "$IP_NAME" --global --format='value(address)' 2>/dev/null || true)

# ---- 1. In-cluster cleanup ----------------------------------------------------
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" &>/dev/null; then
  gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1 || true
  if command -v kubectl >/dev/null 2>&1 && kubectl get --raw /readyz >/dev/null 2>&1; then
    log "Stopping Argo CD reconciliation (so it doesn't recreate what's deleted next)"
    kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 2>/dev/null || skip

    log "Deleting the Gateway (Google load balancer for $API_HOST)"
    kubectl delete gateway grpc -n default --ignore-not-found --wait=true --timeout=5m || true
    if [[ -n "$API_IP" ]]; then
      wait_until 900 "the load balancer's forwarding rules to be removed" \
        bash -c "[[ -z \"\$(gcloud compute forwarding-rules list --global --filter='IPAddress=$API_IP' --format='value(name)')\" ]]" \
        || true
    fi

    log "Deleting PostgresInstances (Crossplane deletes the Cloud SQL instance; ~5 min)"
    if kubectl get crd postgresinstances.platform.miqui.dev >/dev/null 2>&1; then
      kubectl delete postgresinstances --all -A --wait=false || true
      wait_until 1200 "Cloud SQL managed resources to be deleted" \
        bash -c '[[ -z "$(kubectl get databaseinstances.sql.gcp.m.upbound.io -A --no-headers 2>/dev/null)" ]]' \
        || true
    else
      skip
    fi
  else
    echo "WARNING: cluster exists but its API is unreachable (IP changed?); skipping in-cluster" >&2
    echo "         cleanup - the leftover checks after cluster deletion will catch Cloud SQL and" >&2
    echo "         the forwarding rule, but other load balancer parts may need manual cleanup." >&2
  fi
fi

# ---- 2. GKE cluster ---------------------------------------------------------
log "Deleting cluster: $CLUSTER (this takes several minutes)"
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" &>/dev/null; then
  # GKE rejects the delete ("Cluster is running incompatible operation") while another
  # operation runs - typically a cluster-autoscaler resize triggered by the workload deletions
  # above. Wait for those to finish (up to 20 min) first. The targetLink match covers the
  # cluster and its node pools (a grouped `(/|$)` anchor matched nothing when tested).
  for _ in $(seq 1 80); do
    running=$(gcloud container operations list --zone="$ZONE" \
      --filter="status!=DONE AND targetLink~/clusters/$CLUSTER" --format='value(operationType)' 2>/dev/null || true)
    [[ -z "$running" ]] && break
    echo "    waiting for running cluster operation(s): $(tr '\n' ' ' <<<"$running")"
    sleep 15
  done
  gcloud container clusters delete "$CLUSTER" --zone="$ZONE" --quiet
else
  skip
fi

# ---- 3. Leftovers the in-cluster cleanup should have removed -----------------------
log "Checking for leftover Cloud SQL instances (label platform=gke-quarkus-grpc-o2)"
LEFTOVER_SQL=$(gcloud sql instances list --filter="settings.userLabels.platform=gke-quarkus-grpc-o2" \
  --format='value(name)' 2>/dev/null || true)
if [[ -n "$LEFTOVER_SQL" ]]; then
  for inst in $LEFTOVER_SQL; do
    echo "    deleting $inst"
    gcloud sql instances delete "$inst" --quiet
  done
else
  echo "    none"
fi

if [[ -n "$API_IP" ]]; then
  log "Checking for leftover forwarding rules on $IP_NAME ($API_IP)"
  LEFTOVER_FR=$(gcloud compute forwarding-rules list --global --filter="IPAddress=$API_IP" --format='value(name)' || true)
  if [[ -n "$LEFTOVER_FR" ]]; then
    for fr in $LEFTOVER_FR; do gcloud compute forwarding-rules delete "$fr" --global --quiet; done
  else
    echo "    none"
  fi
fi

# Container-native load balancing leaves zonal network endpoint groups (one per Service port)
# behind when the cluster goes before the NEG controller has cleaned up; any NEG in this VPC
# blocks deleting it ("is already being used by .../networkEndpointGroups/k8s1-...").
log "Checking for leftover network endpoint groups in $VPC"
LEFTOVER_NEG=$(gcloud compute network-endpoint-groups list --filter="network~/${VPC}\$" \
  --format='value(name,zone.basename())' 2>/dev/null || true)
if [[ -n "$LEFTOVER_NEG" ]]; then
  while read -r neg zone; do
    gcloud compute network-endpoint-groups delete "$neg" --zone="$zone" --quiet
  done <<<"$LEFTOVER_NEG"
else
  echo "    none"
fi

# Deleting a GKE cluster does NOT delete the persistent disks behind its PVCs (OpenObserve's
# and the Trivy server's here); they'd keep billing. Some GKE versions label them with the
# cluster name; others (1.35.6, 2026-09-27) set no labels and only record the PVC in the
# disk's description (`"storage.gke.io/created-by":"pd.csi.storage.gke.io"`, name `pvc-...`).
# Match either, in any zone the nodes ran in (a PVC's disk is created in its first pod's zone);
# only unattached disks are touched.
log "Checking for leftover PVC disks (unattached pvc-* disks from the PD CSI driver in $NODE_ZONES)"
LEFTOVER_DISKS=$(gcloud compute disks list \
  --filter="-users:* AND zone:(${NODE_ZONES//,/ }) AND (labels.goog-k8s-cluster-name=$CLUSTER OR (name~^pvc- AND description:pd.csi.storage.gke.io))" \
  --format='value(name,zone.basename())' 2>/dev/null || true)
if [[ -n "$LEFTOVER_DISKS" ]]; then
  while read -r disk zone; do
    gcloud compute disks delete "$disk" --zone="$zone" --quiet
  done <<<"$LEFTOVER_DISKS"
else
  echo "    none"
fi

# ---- 4. PSA, edge, DNS -------------------------------------------------------------------
# Deleting the consumer side of the peering works even while the producer side still holds
# on to a just-deleted Cloud SQL instance (which blocks `gcloud services vpc-peerings delete`).
log "Removing Private Service Access peering + range"
if gcloud compute networks describe "$VPC" &>/dev/null && \
   gcloud compute networks peerings list --network="$VPC" --format='value(peerings.name)' 2>/dev/null | grep -q servicenetworking; then
  gcloud compute networks peerings delete servicenetworking-googleapis-com --network="$VPC" --quiet
else
  skip
fi
if gcloud compute addresses describe "$PSA_RANGE_NAME" --global &>/dev/null; then
  gcloud compute addresses delete "$PSA_RANGE_NAME" --global --quiet
fi

log "Releasing static IP $IP_NAME, SSL policy $SSL_POLICY and Cloud Armor policy $ARMOR_POLICY"
if [[ -n "$API_IP" ]]; then gcloud compute addresses delete "$IP_NAME" --global --quiet; else skip; fi
if gcloud compute ssl-policies describe "$SSL_POLICY" --global &>/dev/null; then
  gcloud compute ssl-policies delete "$SSL_POLICY" --global --quiet || \
    echo "    WARNING: $SSL_POLICY still in use by a leftover target proxy; delete it later" >&2
fi
if gcloud compute security-policies describe "$ARMOR_POLICY" &>/dev/null; then
  gcloud compute security-policies delete "$ARMOR_POLICY" --quiet || \
    echo "    WARNING: $ARMOR_POLICY still in use by a leftover backend service; delete it later" >&2
fi

# A released IP goes back into Google's pool and can be handed to someone else; a DNS record
# still pointing at it would send $API_HOST traffic to them. Remove it.
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  log "Removing Cloudflare A record for $API_HOST"
  # shellcheck source=scripts/cloudflare-dns.sh
  source scripts/cloudflare-dns.sh
  cf_delete "$DOMAIN" A "$API_HOST" || true
else
  echo
  echo "    NOTE: delete the Cloudflare A record for $API_HOST now (or set CLOUDFLARE_API_TOKEN):"
  echo "          $API_IP is released and may be reassigned to another Google Cloud customer."
fi

# ---- 5. Network ------------------------------------------------------------------------------
# The VPC is dedicated to this platform, so every firewall rule in it is ours: the webhook rule
# from gke-deploy.sh plus anything GKE (health checks, Gateway) failed to clean up.
log "Deleting firewall rules in $VPC"
FW_RULES=$(gcloud compute firewall-rules list --filter="network~/${VPC}\$" --format='value(name)' 2>/dev/null || true)
if [[ -n "$FW_RULES" ]]; then
  # shellcheck disable=SC2086
  gcloud compute firewall-rules delete $FW_RULES --quiet
else
  skip
fi

log "Deleting Cloud NAT: $NAT"
if gcloud compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" &>/dev/null; then
  gcloud compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" --quiet
else
  skip
fi

log "Deleting Cloud Router: $ROUTER"
if gcloud compute routers describe "$ROUTER" --region="$REGION" &>/dev/null; then
  gcloud compute routers delete "$ROUTER" --region="$REGION" --quiet
else
  skip
fi

# Retry: NAT IP release and NEG cleanup can lag briefly behind their deletion.
log "Deleting subnet: $SUBNET"
if gcloud compute networks subnets describe "$SUBNET" --region="$REGION" &>/dev/null; then
  for attempt in 1 2 3 4; do
    if gcloud compute networks subnets delete "$SUBNET" --region="$REGION" --quiet; then
      break
    fi
    if [[ "$attempt" -eq 4 ]]; then
      echo "ERROR: could not delete subnet $SUBNET after 4 attempts." >&2
      echo "Something may still be using it (network endpoint groups, reserved IPs, other VMs):" >&2
      echo "  gcloud compute network-endpoint-groups list --filter='subnetwork~$SUBNET'" >&2
      exit 1
    fi
    echo "    retrying in 30s..."
    sleep 30
  done
else
  skip
fi

log "Deleting VPC: $VPC"
if gcloud compute networks describe "$VPC" &>/dev/null; then
  gcloud compute networks delete "$VPC" --quiet
else
  skip
fi

# ---- 6. --purge: persistent resources -----------------------------------------------------------
if [[ "$PURGE" -eq 1 ]]; then
  log "Purging Artifact Registry repo: $REPO"
  if gcloud artifacts repositories describe "$REPO" --location="$REGION" &>/dev/null; then
    gcloud artifacts repositories delete "$REPO" --location="$REGION" --quiet
  else
    skip
  fi

  log "Purging Certificate Manager resources"
  ACME_NAME=$(gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" \
    --format='value(dnsResourceRecord.name)' 2>/dev/null || true)
  gcloud certificate-manager maps entries delete "$CERT_MAP_ENTRY" --map="$CERT_MAP" --quiet 2>/dev/null || true
  gcloud certificate-manager maps delete "$CERT_MAP" --quiet 2>/dev/null || true
  gcloud certificate-manager certificates delete "$CERT" --quiet 2>/dev/null || true
  gcloud certificate-manager dns-authorizations delete "$DNS_AUTH" --quiet 2>/dev/null || true
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "$ACME_NAME" ]]; then
    cf_delete "$DOMAIN" CNAME "${ACME_NAME%.}" || true
  fi

  log "Purging Secret Manager secrets"
  for s in "${SECRETS[@]}"; do
    gcloud secrets delete "$s" --quiet 2>/dev/null && echo "    $s" || true
  done

  log "Purging service accounts"
  for pair in "${PROJECT_ROLES[@]}"; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${pair%%=*}@${PROJECT_ID}.iam.gserviceaccount.com" \
      --role="${pair#*=}" --condition=None --quiet >/dev/null 2>&1 || true
  done
  for sa in "${SERVICE_ACCOUNTS[@]}"; do
    gcloud iam service-accounts delete "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet 2>/dev/null \
      && echo "    $sa" || true
  done

  # The Workload Identity pool "$WIF_POOL" is shared by every project (each has its own binding
  # and CI service account), so it is never purged here.
fi

# ---- Summary ----------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32mTeardown complete.\033[0m') Billable cluster, database, load balancer and network resources are deleted.
EOF
if [[ "$PURGE" -ne 1 ]]; then
  cat <<EOF

  Still present (by design, for the next gke-deploy.sh): Artifact Registry $REPO, certificate
  $CERT (+ map, DNS authorization and its Cloudflare CNAME), Secret Manager secrets, service
  accounts. Remove them with --purge (the shared WIF pool is never removed).
EOF
fi
