#!/usr/bin/env bash
#
# gke-deploy.sh — provision the GCP side of the dev platform. Everything *inside* the cluster is
# installed afterwards by gke-bootstrap.sh (Argo CD, then everything else via GitOps).
#
# Architecture:
#   - Zonal control plane (us-central1-a) with multi-zone workers: the node pool spans
#     us-central1-a/b/c (--node-locations), e2-standard-2, autoscaling 3..6 nodes in total,
#     balanced across zones. A zone outage takes nodes down but not the whole data plane;
#     the control plane itself stays single-zone (a regional one forfeits GKE's free-tier credit)
#   - Dedicated VPC + subnet with Private Google Access
#   - Private nodes (no external IPs); control plane locked to operator's IP
#   - Cloud Router + Cloud NAT for node/pod egress (public images, Hazelcast's JMX agent download)
#   - Dataplane V2 (NetworkPolicy enforcement), Workload Identity, Gateway API, Shielded Nodes
#   - Dedicated least-privilege node service account (not the Editor-role default compute SA)
#   - Private Service Access range + peering so Cloud SQL (created by Crossplane) gets a private IP
#   - Artifact Registry repo in-region (image streaming; pulls bypass NAT) with a cleanup policy
#   - Workload Identity GSAs for in-cluster controllers: Crossplane, External Secrets, Image Updater
#   - Keyless GitHub Actions → Artifact Registry push (Workload Identity Federation, no JSON keys)
#   - Public edge for the API: global static IP, SSL policy (TLS 1.2+), Certificate Manager cert
#     (DNS authorization) + cert map, used by the Gateway in k8s/gateway.yaml
#   - DNS on Cloudflare: A + validation CNAME upserted via API when CLOUDFLARE_API_TOKEN is set,
#     otherwise printed for manual entry
#
# Usage:
#   PROJECT_ID=k8s-dev-412419 ./gke-deploy.sh
#   op run --env-file=.env -- env PROJECT_ID=k8s-dev-412419 ./gke-deploy.sh   # with DNS automation
#
# Overridable env vars: REGION, ZONE, NODE_ZONES, CLUSTER, VPC, SUBNET, ROUTER, NAT, REPO, MACHINE_TYPE,
#                       MIN_NODES, MAX_NODES, NODE_DISK_SIZE_GB, DOMAIN, API_HOST, GITHUB_REPO,
#                       CLOUDFLARE_API_TOKEN
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR
cd "$(dirname "$0")"

# ---- Config ---------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required, e.g. PROJECT_ID=k8s-dev-412419 ./gke-deploy.sh}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"   # control plane location; also the cluster's --zone handle
# Zones the worker nodes run in (comma-separated, must include $ZONE). Changeable on a live
# cluster; see "Existing cluster" in section 6.
NODE_ZONES="${NODE_ZONES:-us-central1-a,us-central1-b,us-central1-c}"
CLUSTER="${CLUSTER:-dev-cluster}"
VPC="${VPC:-dev-vpc}"
SUBNET="${SUBNET:-dev-subnet}"
ROUTER="${ROUTER:-dev-router}"
NAT="${NAT:-dev-nat}"
REPO="${REPO:-springboot-grpc-o2}"   # one Artifact Registry repo per project
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-2}"
# Autoscaling bounds for the whole pool, across all of NODE_ZONES (--total-*-nodes), not per
# zone. 3 = one node per zone; 6 leaves headroom for the 4th node the platform usually needs
# (GKE-OPS.md) plus Trivy scan bursts.
MIN_NODES="${MIN_NODES:-3}"
MAX_NODES="${MAX_NODES:-6}"
# Node boot disk (GKE default is 100 GB). Holds COS, system pods and all pulled images (no image
# streaming); 30 GB is ample for this stack. Creation-time only for the default node pool.
NODE_DISK_SIZE_GB="${NODE_DISK_SIZE_GB:-30}"
DOMAIN="${DOMAIN:-miqui.dev}"
API_HOST="${API_HOST:-grpc.${DOMAIN}}"
GITHUB_REPO="${GITHUB_REPO:-miqui/gke-quarkus-grpc-o2}"

SUBNET_RANGE="10.0.0.0/20"
PODS_RANGE="10.4.0.0/14"
SERVICES_RANGE="10.8.0.0/20"
# Private Service Access range for Cloud SQL. Referenced by the default-namespace NetworkPolicies
# (k8s/networkpolicies.yaml) - keep them in sync.
PSA_RANGE_NAME="cloudsql-psa-range"
PSA_RANGE_START="10.16.0.0"
PSA_RANGE_PREFIX="20"

# Service accounts. The in-cluster ones are bound to fixed Kubernetes ServiceAccounts that the
# Helm values / Crossplane DeploymentRuntimeConfig in k8s/ name explicitly.
NODE_SA="gke-dev-nodes"
CROSSPLANE_SA="crossplane-gcp"          # KSA crossplane-system/provider-gcp
ESO_SA="external-secrets"               # KSA external-secrets/external-secrets
IMAGE_UPDATER_SA="argocd-image-updater" # KSA argocd/argocd-image-updater
CI_SA="ci-springboot-grpc-o2"   # one CI service account per project
WIF_POOL="github"
WIF_PROVIDER="github-oidc"

# Public edge (names referenced by k8s/gateway.yaml)
IP_NAME="grpc-ip"
SSL_POLICY="grpc-tls"
ARMOR_POLICY="grpc-allowlist"
DNS_AUTH="grpc-dns-auth"
CERT="grpc-cert"
CERT_MAP="grpc-cert-map"
CERT_MAP_ENTRY="grpc-cert-map-entry"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { echo "    already exists, skipping"; }
sa_email() { echo "$1@${PROJECT_ID}.iam.gserviceaccount.com"; }

command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }

# ---- 0. Project setup -----------------------------------------------------
log "Setting project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# ---- 0b. Preflight: verify effective IAM permissions ------------------------
# Uses resourcemanager.testIamPermissions, which accounts for permissions
# inherited from the org, folders, and group memberships (not just direct
# project bindings). Skip with IAM_CHECK=0.
IAM_CHECK="${IAM_CHECK:-1}"
if [[ "$IAM_CHECK" == "1" ]]; then
  ACCOUNT=$(gcloud config get-value account)
  log "Checking IAM permissions for $ACCOUNT"

  REQUIRED_PERMS=(
    resourcemanager.projects.get
    resourcemanager.projects.setIamPolicy
    serviceusage.services.enable
    compute.networks.create
    compute.subnetworks.create
    compute.routers.create
    compute.globalAddresses.create
    compute.firewalls.create
    compute.sslPolicies.create
    compute.securityPolicies.create
    compute.securityPolicies.update
    servicenetworking.services.addPeering
    container.clusters.create
    container.clusters.getCredentials
    artifactregistry.repositories.create
    artifactregistry.repositories.setIamPolicy
    iam.serviceAccounts.create
    iam.serviceAccounts.setIamPolicy
    iam.workloadIdentityPools.create
    iam.workloadIdentityPoolProviders.create
    certificatemanager.certs.create
    certificatemanager.dnsauthorizations.create
    certificatemanager.certmaps.create
  )

  PERMS_JSON=$(printf '"%s",' "${REQUIRED_PERMS[@]}")
  RESPONSE=$(curl -s --max-time 15 -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    -d "{\"permissions\":[${PERMS_JSON%,}]}" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" || true)

  if [[ -z "$RESPONSE" || "$RESPONSE" == *'"error"'* ]]; then
    echo "ERROR: IAM permission check failed (does $ACCOUNT have any access to '$PROJECT_ID'?):" >&2
    echo "${RESPONSE:-<empty response>}" >&2
    exit 1
  fi

  MISSING=""
  for perm in "${REQUIRED_PERMS[@]}"; do
    [[ "$RESPONSE" == *"\"$perm\""* ]] || MISSING="${MISSING}  - ${perm}"$'\n'
  done

  if [[ -n "$MISSING" ]]; then
    cat >&2 <<EOF
ERROR: $ACCOUNT is missing required permissions:

$MISSING
This script creates networks, a cluster, service accounts, IAM bindings, Workload Identity
Federation and Certificate Manager resources - roles/owner on this dev project is the simple fix:

  gcloud projects add-iam-policy-binding $PROJECT_ID --member="user:$ACCOUNT" --role=roles/owner

If permissions come from a source this check can't see, skip with IAM_CHECK=0.
EOF
    exit 1
  fi
  echo "    all required permissions present"
fi

log "Enabling APIs"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  secretmanager.googleapis.com \
  certificatemanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com

# ---- 1. Service accounts ----------------------------------------------------
ensure_sa() { # ensure_sa <id> <display name>
  if gcloud iam service-accounts describe "$(sa_email "$1")" &>/dev/null; then
    echo "    $1: exists"
  else
    gcloud iam service-accounts create "$1" --display-name="$2"
  fi
}
project_role() { # project_role <sa id> <role>
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$(sa_email "$1")" --role="$2" --condition=None --quiet >/dev/null
  echo "    $1 -> $2"
}

log "Creating service accounts"
ensure_sa "$NODE_SA"          "GKE dev-cluster nodes"
ensure_sa "$CROSSPLANE_SA"    "Crossplane GCP provider (Cloud SQL)"
ensure_sa "$ESO_SA"           "External Secrets Operator (Secret Manager reader)"
ensure_sa "$IMAGE_UPDATER_SA" "Argo CD Image Updater (Artifact Registry reader)"
ensure_sa "$CI_SA"            "GitHub Actions image push"

log "Granting project roles"
# Node SA: logging/monitoring/metadata only (the predefined role GKE recommends for custom node
# SAs). Image pulls are granted on the repo itself in step 6, not project-wide.
project_role "$NODE_SA" roles/container.defaultNodeServiceAccount
# Crossplane creates/deletes Cloud SQL instances attached to the VPC by private IP.
project_role "$CROSSPLANE_SA" roles/cloudsql.admin
project_role "$CROSSPLANE_SA" roles/compute.networkUser
# ESO gets secretAccessor per secret (gke-secrets-seed.sh), not project-wide.

# ---- 2. Dedicated VPC + subnet --------------------------------------------
log "Creating VPC: $VPC"
if gcloud compute networks describe "$VPC" &>/dev/null; then
  skip
else
  gcloud compute networks create "$VPC" --subnet-mode=custom
fi

log "Creating subnet: $SUBNET ($SUBNET_RANGE, pods=$PODS_RANGE, services=$SERVICES_RANGE)"
if gcloud compute networks subnets describe "$SUBNET" --region="$REGION" &>/dev/null; then
  skip
else
  gcloud compute networks subnets create "$SUBNET" \
    --network="$VPC" \
    --region="$REGION" \
    --range="$SUBNET_RANGE" \
    --secondary-range="pods=$PODS_RANGE,services=$SERVICES_RANGE" \
    --enable-private-ip-google-access
fi

# ---- 3. Cloud Router + NAT (egress for private nodes) ----------------------
log "Creating Cloud Router: $ROUTER"
if gcloud compute routers describe "$ROUTER" --region="$REGION" &>/dev/null; then
  skip
else
  gcloud compute routers create "$ROUTER" --network="$VPC" --region="$REGION"
fi

log "Creating Cloud NAT: $NAT"
if gcloud compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" &>/dev/null; then
  skip
else
  gcloud compute routers nats create "$NAT" \
    --router="$ROUTER" \
    --region="$REGION" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
fi

# ---- 4. Private Service Access (Cloud SQL private IP) ------------------------
log "Reserving Private Service Access range: $PSA_RANGE_NAME ($PSA_RANGE_START/$PSA_RANGE_PREFIX)"
if gcloud compute addresses describe "$PSA_RANGE_NAME" --global &>/dev/null; then
  skip
else
  gcloud compute addresses create "$PSA_RANGE_NAME" \
    --global \
    --purpose=VPC_PEERING \
    --addresses="$PSA_RANGE_START" \
    --prefix-length="$PSA_RANGE_PREFIX" \
    --network="$VPC"
fi

log "Peering $VPC with servicenetworking.googleapis.com"
if gcloud services vpc-peerings list --network="$VPC" --format='value(peering)' 2>/dev/null | grep -q .; then
  skip
else
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="$PSA_RANGE_NAME" \
    --network="$VPC"
fi

# ---- 5. Control-plane access restricted to operator's IP -------------------
log "Detecting operator public IP for master authorized networks"
MY_IP=$(curl -4 -s --max-time 10 ifconfig.me || true)
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: could not detect public IP (got: '${MY_IP:-empty}')" >&2; exit 1;
}
echo "    operator IP: $MY_IP"

# ---- 6. GKE cluster ---------------------------------------------------------
# These flags can only be set at creation time (dataplane v2) or are awkward to change later, so
# an existing cluster created by an older version of this script must be recreated to pick them up.
[[ ",$NODE_ZONES," == *",$ZONE,"* ]] || { echo "ERROR: NODE_ZONES ($NODE_ZONES) must include ZONE ($ZONE)" >&2; exit 1; }
NODE_ZONE_COUNT=$(tr ',' '\n' <<<"$NODE_ZONES" | grep -c .)
log "Creating cluster: $CLUSTER (control plane $ZONE, nodes in $NODE_ZONES, $MACHINE_TYPE, ${NODE_DISK_SIZE_GB}GB pd-balanced, autoscaling $MIN_NODES..$MAX_NODES total, private nodes)"
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" &>/dev/null; then
  skip
  # Existing cluster: node zones and total autoscaling bounds are not reconciled automatically.
  # Adding zones to a live pool creates as many nodes in each new zone as the pool currently
  # has per zone (4 today -> 12 nodes, likely over the regional CPU quota), so it's a guided,
  # ordered change - see GKE-OPS.md "Spreading an existing cluster across zones".
  CURRENT_ZONES=$(gcloud container clusters describe "$CLUSTER" --zone="$ZONE" \
    --format='value(locations.list())' | tr ';' ',')
  if [[ "$(tr ',' '\n' <<<"$CURRENT_ZONES" | sort | paste -sd, -)" != "$(tr ',' '\n' <<<"$NODE_ZONES" | sort | paste -sd, -)" ]]; then
    echo "    WARNING: nodes run in [$CURRENT_ZONES], wanted [$NODE_ZONES]; not changed here (GKE-OPS.md)" >&2
  fi
else
  gcloud container clusters create "$CLUSTER" \
    --zone="$ZONE" \
    --network="$VPC" \
    --subnetwork="$SUBNET" \
    --enable-ip-alias \
    --cluster-secondary-range-name=pods \
    --services-secondary-range-name=services \
    --enable-private-nodes \
    --enable-master-authorized-networks \
    --master-authorized-networks="$MY_IP/32" \
    --service-account="$(sa_email "$NODE_SA")" \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-dataplane-v2 \
    --gateway-api=standard \
    --no-enable-managed-prometheus \
    --enable-shielded-nodes \
    --shielded-secure-boot \
    --shielded-integrity-monitoring \
    --machine-type="$MACHINE_TYPE" \
    --disk-type=pd-balanced \
    --disk-size="$NODE_DISK_SIZE_GB" \
    --node-locations="$NODE_ZONES" \
    --num-nodes="$(( (MIN_NODES + NODE_ZONE_COUNT - 1) / NODE_ZONE_COUNT ))" \
    --enable-autoscaling \
    --location-policy=BALANCED \
    --total-min-nodes="$MIN_NODES" \
    --total-max-nodes="$MAX_NODES" \
    --release-channel=stable
fi

# Admission webhooks served on ports other than 443/10250 (Kyverno and Crossplane: 9443).
# Current GKE private clusters are PSC-based: the control plane reaches webhooks through the
# konnectivity agents running inside the cluster, i.e. over the pod network, which GKE's own
# "-all" firewall rule already allows - nothing to add. Older VPC-peering-based private clusters
# instead connect from a dedicated control-plane range that GKE's "-master" rule only opens for
# 443/10250; there, open the webhook ports too, or every matching create/update times out.
WEBHOOK_FW="${CLUSTER}-allow-webhooks"
log "Control plane -> admission webhooks (tcp:8443,9443)"
MASTER_RANGES=$(gcloud compute firewall-rules list \
  --filter="network~/${VPC}\$ AND name~^gke-${CLUSTER}-.*-master\$" \
  --format='value(sourceRanges.list())' | head -1)
if [[ -z "$MASTER_RANGES" ]]; then
  echo "    PSC-based cluster (webhooks reached via konnectivity) - no extra rule needed"
elif gcloud compute firewall-rules describe "$WEBHOOK_FW" &>/dev/null; then
  skip
else
  NODE_TAG=$(gcloud compute firewall-rules list \
    --filter="network~/${VPC}\$ AND name~^gke-${CLUSTER}-.*-master\$" \
    --format='value(targetTags.list())' | head -1)
  gcloud compute firewall-rules create "$WEBHOOK_FW" \
    --network="$VPC" \
    --direction=INGRESS \
    --source-ranges="$MASTER_RANGES" \
    --target-tags="$NODE_TAG" \
    --allow=tcp:8443,tcp:9443
fi

# ---- 7. Workload Identity bindings for in-cluster controllers ----------------
# The PROJECT.svc.id.goog identity pool exists once the first Workload Identity cluster does.
wi_bind() { # wi_bind <gsa id> <namespace> <ksa>
  gcloud iam service-accounts add-iam-policy-binding "$(sa_email "$1")" \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[$2/$3]" --quiet >/dev/null
  echo "    $2/$3 -> $1"
}
log "Binding Kubernetes ServiceAccounts to GCP service accounts (Workload Identity)"
wi_bind "$CROSSPLANE_SA"    crossplane-system provider-gcp
wi_bind "$ESO_SA"           external-secrets  external-secrets
wi_bind "$IMAGE_UPDATER_SA" argocd            argocd-image-updater

# ---- 8. Artifact Registry ---------------------------------------------------
log "Creating Artifact Registry repo: $REPO ($REGION)"
if gcloud artifacts repositories describe "$REPO" --location="$REGION" &>/dev/null; then
  skip
else
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION"
fi

log "Applying cleanup policy (keep the 20 newest versions, drop untagged after 1 day)"
POLICY_FILE=$(mktemp)
cat > "$POLICY_FILE" <<'EOF'
[
  {"name": "keep-newest-20", "action": {"type": "Keep"}, "mostRecentVersions": {"keepCount": 20}},
  {"name": "delete-untagged", "action": {"type": "Delete"},
   "condition": {"tagState": "UNTAGGED", "olderThan": "1d"}},
  {"name": "delete-old-tagged", "action": {"type": "Delete"},
   "condition": {"tagState": "TAGGED", "olderThan": "14d"}}
]
EOF
gcloud artifacts repositories set-cleanup-policies "$REPO" --location="$REGION" \
  --policy="$POLICY_FILE" --no-dry-run --quiet >/dev/null
rm -f "$POLICY_FILE"

repo_role() { # repo_role <sa id> <role>
  gcloud artifacts repositories add-iam-policy-binding "$REPO" --location="$REGION" \
    --member="serviceAccount:$(sa_email "$1")" --role="$2" --quiet >/dev/null
  echo "    $1 -> $2 on $REPO"
}
log "Granting repository access"
repo_role "$NODE_SA"          roles/artifactregistry.reader  # kubelet image pulls
repo_role "$IMAGE_UPDATER_SA" roles/artifactregistry.reader  # tag listing
repo_role "$CI_SA"            roles/artifactregistry.writer  # CI push
# Trivy Operator's scan jobs (KSA trivy-system/trivy-operator) pull the API image to scan it.
# Granted to the Workload Identity principal directly - no GSA or KSA annotation needed; Trivy
# picks up the pod's federated token from the GKE metadata server (useGCRServiceAccount).
gcloud artifacts repositories add-iam-policy-binding "$REPO" --location="$REGION" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/trivy-system/sa/trivy-operator" \
  --role=roles/artifactregistry.reader --quiet >/dev/null
echo "    trivy-system/trivy-operator -> roles/artifactregistry.reader on $REPO"

log "Configuring local docker for push"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ---- 9. Keyless CI: GitHub OIDC -> Workload Identity Federation -> $CI_SA ----
# The pool and provider are shared by every project in this GCP project (pools are soft-deleted for
# 30 days, so gke-teardown.sh never purges it). The provider condition is only a coarse gate (this
# GitHub owner, main branch); what a repo may actually do is decided by its own binding below, which
# lets that repo - and only that repo - impersonate this project's CI service account.
GITHUB_OWNER="${GITHUB_REPO%%/*}"
WIF_CONDITION="assertion.repository_owner == '${GITHUB_OWNER}' && assertion.ref == 'refs/heads/main'"
log "Workload Identity Federation for GitHub Actions ($GITHUB_REPO)"
if gcloud iam workload-identity-pools describe "$WIF_POOL" --location=global &>/dev/null; then
  echo "    pool $WIF_POOL: exists"
else
  gcloud iam workload-identity-pools create "$WIF_POOL" --location=global \
    --display-name="GitHub Actions"
fi
if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
     --workload-identity-pool="$WIF_POOL" --location=global &>/dev/null; then
  # Converge an older repo-specific condition to the owner-wide one (existing repos' bindings keep
  # working; the condition only widens from one repo to the owner's repos).
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
    --workload-identity-pool="$WIF_POOL" --location=global \
    --attribute-condition="$WIF_CONDITION" --quiet >/dev/null
  echo "    provider $WIF_PROVIDER: exists (condition converged)"
else
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --workload-identity-pool="$WIF_POOL" --location=global \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="$WIF_CONDITION"
fi
gcloud iam service-accounts add-iam-policy-binding "$(sa_email "$CI_SA")" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}" \
  --quiet >/dev/null
WIF_PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"

# ---- 10. Public edge for the API -----------------------------------------------
log "Reserving global static IP: $IP_NAME"
if gcloud compute addresses describe "$IP_NAME" --global &>/dev/null; then
  skip
else
  gcloud compute addresses create "$IP_NAME" --global --ip-version=IPV4
fi
API_IP=$(gcloud compute addresses describe "$IP_NAME" --global --format='value(address)')
echo "    $IP_NAME = $API_IP"

log "Creating SSL policy: $SSL_POLICY (MODERN, TLS >= 1.2)"
if gcloud compute ssl-policies describe "$SSL_POLICY" --global &>/dev/null; then
  skip
else
  gcloud compute ssl-policies create "$SSL_POLICY" --global --profile=MODERN --min-tls-version=1.2
fi

# The API has no authentication, so Cloud Armor (attached by the GCPBackendPolicy in
# k8s/gateway.yaml) only lets these source ranges reach it: comma-separated, at most 10.
# The allow rule is rewritten on every run, so re-running after an IP change re-authorizes it.
API_ALLOWED_CIDRS="${API_ALLOWED_CIDRS:-$MY_IP/32}"
log "Cloud Armor policy: $ARMOR_POLICY (allow $API_ALLOWED_CIDRS, deny the rest)"
if gcloud compute security-policies describe "$ARMOR_POLICY" &>/dev/null; then
  echo "    policy exists"
else
  gcloud compute security-policies create "$ARMOR_POLICY" \
    --description="job-manager-api source allowlist (gke-deploy.sh)"
fi
gcloud compute security-policies rules update 2147483647 --security-policy="$ARMOR_POLICY" \
  --action=deny-403 >/dev/null
if gcloud compute security-policies rules describe 1000 --security-policy="$ARMOR_POLICY" &>/dev/null; then
  gcloud compute security-policies rules update 1000 --security-policy="$ARMOR_POLICY" \
    --src-ip-ranges="$API_ALLOWED_CIDRS" --action=allow >/dev/null
else
  gcloud compute security-policies rules create 1000 --security-policy="$ARMOR_POLICY" \
    --src-ip-ranges="$API_ALLOWED_CIDRS" --action=allow \
    --description="allowed API clients" >/dev/null
fi

# DNS authorization lets Google issue the cert before (and independently of) the load balancer
# existing, so the cert survives cluster rebuilds and is valid the moment a new Gateway comes up.
log "Certificate Manager: DNS authorization, certificate, cert map for $API_HOST"
if gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" &>/dev/null; then
  echo "    dns authorization $DNS_AUTH: exists"
else
  gcloud certificate-manager dns-authorizations create "$DNS_AUTH" --domain="$API_HOST"
fi
if gcloud certificate-manager certificates describe "$CERT" &>/dev/null; then
  echo "    certificate $CERT: exists"
else
  gcloud certificate-manager certificates create "$CERT" \
    --domains="$API_HOST" --dns-authorizations="$DNS_AUTH"
fi
if gcloud certificate-manager maps describe "$CERT_MAP" &>/dev/null; then
  echo "    cert map $CERT_MAP: exists"
else
  gcloud certificate-manager maps create "$CERT_MAP"
fi
if gcloud certificate-manager maps entries describe "$CERT_MAP_ENTRY" --map="$CERT_MAP" &>/dev/null; then
  echo "    cert map entry $CERT_MAP_ENTRY: exists"
else
  gcloud certificate-manager maps entries create "$CERT_MAP_ENTRY" \
    --map="$CERT_MAP" --hostname="$API_HOST" --certificates="$CERT"
fi
ACME_NAME=$(gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" --format='value(dnsResourceRecord.name)')
ACME_DATA=$(gcloud certificate-manager dns-authorizations describe "$DNS_AUTH" --format='value(dnsResourceRecord.data)')

# ---- 11. DNS (Cloudflare) ----------------------------------------------------------
# Both records must be "DNS only" (proxied=false): the A record so clients reach Google's load
# balancer and its Google-managed cert directly, the CNAME because Cloudflare can't proxy it.
DNS_DONE=0
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  log "Updating Cloudflare DNS for $DOMAIN"
  # shellcheck source=scripts/cloudflare-dns.sh
  source scripts/cloudflare-dns.sh
  cf_upsert "$DOMAIN" A     "$API_HOST"       "$API_IP"
  cf_upsert "$DOMAIN" CNAME "${ACME_NAME%.}"  "${ACME_DATA%.}"
  DNS_DONE=1
fi

# ---- 12. Connect + verify -----------------------------------------------------
log "Fetching kubeconfig for $CLUSTER"
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE"

log "Verifying cluster"
kubectl get nodes -o wide
kubectl cluster-info

# ---- Summary -----------------------------------------------------------------
CERT_STATE=$(gcloud certificate-manager certificates describe "$CERT" --format='value(managed.state)')
cat <<EOF

$(printf '\033[1;32mDone.\033[0m') Cluster '$CLUSTER' and its GCP foundation are ready.

  DNS for $DOMAIN (Cloudflare, both "DNS only" / grey cloud):
    A      ${API_HOST}  ->  ${API_IP}
    CNAME  ${ACME_NAME%.}  ->  ${ACME_DATA%.}
  $( [[ $DNS_DONE == 1 ]] && echo "  (upserted via the Cloudflare API)" || echo "  Set CLOUDFLARE_API_TOKEN to automate this, or add both records by hand." )
  Certificate $CERT state: ${CERT_STATE:-unknown} (ACTIVE once the CNAME resolves; first issue ~15-60 min)

  GitHub repo variables for .github/workflows/job-manager-api-ci.yml
  (Settings -> Secrets and variables -> Actions -> Variables):
    GCP_WIF_PROVIDER = ${WIF_PROVIDER_NAME}
    GCP_CI_SA        = $(sa_email "$CI_SA")

  Next:
    1. op run --env-file=.env -- env PROJECT_ID=$PROJECT_ID ./gke-secrets-seed.sh   (first time / rotation)
    2. PROJECT_ID=$PROJECT_ID ./gke-bootstrap.sh
    3. ./gke-port-forward.sh     (Argo CD, Grafana, Prometheus, OpenObserve, Headlamp, Polaris)

  API clients allowed by Cloud Armor ($ARMOR_POLICY): $API_ALLOWED_CIDRS

  If your public IP changes, re-authorize it (control plane, then the API):
    gcloud container clusters update $CLUSTER --zone=$ZONE \\
      --enable-master-authorized-networks \\
      --master-authorized-networks=NEW_IP/32
    gcloud compute security-policies rules update 1000 --security-policy=$ARMOR_POLICY \\
      --src-ip-ranges=NEW_IP/32

  Tear down (keeps registry, cert, secrets, service accounts): PROJECT_ID=$PROJECT_ID ./gke-teardown.sh
EOF
