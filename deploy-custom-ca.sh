#!/bin/bash

# ==============================================================================
# Deploy Custom Cluster Autoscaler on GKE
# Based on: https://vadasambar.com/post/kubernetes/how-to-deploy-custom-ca-on-gcp/
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo ""; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; }

error_exit() {
    log_error "$1"
    exit 1
}

# ==============================================================================
# STEP 0: Prerequisites
# ==============================================================================
log_step "STEP 0: Checking Prerequisites"

if ! command -v gcloud &> /dev/null; then
    error_exit "gcloud is not installed"
fi
log_success "✓ gcloud installed"

if ! command -v kubectl &> /dev/null; then
    error_exit "kubectl is not installed"
fi
log_success "✓ kubectl installed"

if ! command -v helm &> /dev/null; then
    error_exit "helm is not installed"
fi
log_success "✓ helm installed"

# ==============================================================================
# STEP 1: Configuration
# ==============================================================================
log_step "STEP 1: Gathering Configuration"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    error_exit "No GCP project set. Run: gcloud config set project PROJECT_ID"
fi
log_info "Project ID: $PROJECT_ID"

read -p "Enter cluster name: " CLUSTER_NAME
read -p "Enter cluster region/zone: " REGION

# Configuration
GCP_SA_NAME="cluster-autoscaler"
GCP_SA_EMAIL="${GCP_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
K8S_NAMESPACE="default"
HELM_RELEASE_NAME="custom-ca"
IG_PREFIX="gke-${CLUSTER_NAME}"

# Get user inputs
read -p "Enter new-pod-scale-up-delay in seconds [600]: " SCALE_UP_DELAY
SCALE_UP_DELAY=${SCALE_UP_DELAY:-600}

read -p "Enter min nodes [1]: " MIN_NODES
MIN_NODES=${MIN_NODES:-1}

read -p "Enter max nodes [10]: " MAX_NODES
MAX_NODES=${MAX_NODES:-10}

# For K8s 1.33, use appropriate Helm chart version
CHART_VERSION="9.43.2"  # Supports K8s 1.33

# ==============================================================================
# NODE POOL SELECTION
# ==============================================================================
log_info "Fetching available node pools..."
ALL_POOLS=$(gcloud container node-pools list --cluster=$CLUSTER_NAME --region=$REGION --format="value(name)" 2>/dev/null)

if [ -z "$ALL_POOLS" ]; then
    error_exit "Cannot fetch node pools. Check cluster name and region."
fi

echo ""
log_info "Available node pools:"
echo "$ALL_POOLS" | nl -w2 -s'. '
echo ""

read -p "Apply changes to specific node pools only? (yes/no) [no]: " TARGET_SPECIFIC
TARGET_SPECIFIC=${TARGET_SPECIFIC:-no}

if [ "$TARGET_SPECIFIC" = "yes" ]; then
    read -p "Enter node pool names (comma-separated): " POOL_INPUT
    
    # Parse comma-separated input into array
    IFS=',' read -ra TARGET_POOLS <<< "$POOL_INPUT"
    
    # Trim whitespace from each element
    for i in "${!TARGET_POOLS[@]}"; do
        TARGET_POOLS[$i]=$(echo "${TARGET_POOLS[$i]}" | xargs)
    done
    
    # Validate pools exist
    for POOL in "${TARGET_POOLS[@]}"; do
        if ! echo "$ALL_POOLS" | grep -q "^${POOL}$"; then
            error_exit "Node pool '${POOL}' not found in cluster"
        fi
    done
    
    log_success "✓ Selected pools: ${TARGET_POOLS[@]}"
else
    # Use all pools
    readarray -t TARGET_POOLS <<< "$ALL_POOLS"
    log_success "✓ Will apply to all pools: ${TARGET_POOLS[@]}"
fi

log_info "Configuration:"
cat <<EOF
  Project:        $PROJECT_ID
  Cluster:        $CLUSTER_NAME
  Region:         $REGION
  GCP SA:         $GCP_SA_EMAIL
  K8s Namespace:  $K8S_NAMESPACE
  IG Prefix:      $IG_PREFIX
  Scale-up Delay: ${SCALE_UP_DELAY}s
  Min Nodes:      $MIN_NODES
  Max Nodes:      $MAX_NODES
  Chart Version:  $CHART_VERSION
  Target Pools:   ${TARGET_POOLS[@]}
EOF

read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    exit 0
fi

# ==============================================================================
# STEP 2: Connect to Cluster
# ==============================================================================
log_step "STEP 2: Connecting to Cluster"

log_info "Getting credentials for cluster..."
gcloud container clusters get-credentials $CLUSTER_NAME --region=$REGION

if kubectl cluster-info &> /dev/null; then
    log_success "✓ Connected to cluster"
else
    error_exit "Cannot connect to cluster"
fi

# ==============================================================================
# STEP 3: Verify GKE Autoscaling is Disabled
# ==============================================================================
log_step "STEP 3: Verifying GKE Autoscaling is Disabled"

log_info "Checking cluster autoscaling status..."
AUTOSCALING_CHECK=$(gcloud container clusters describe $CLUSTER_NAME --region=$REGION | grep "autoscaling:" -A 5)
echo "$AUTOSCALING_CHECK"

if echo "$AUTOSCALING_CHECK" | grep -q "enabled: true"; then
    log_error "GKE autoscaling is ENABLED!"
    log_warning "Disabling on selected pools only..."
    
    for POOL in "${TARGET_POOLS[@]}"; do
        log_info "Disabling autoscaling on pool: $POOL"
        gcloud container clusters update $CLUSTER_NAME \
            --no-enable-autoscaling \
            --node-pool=$POOL \
            --region=$REGION
    done
    log_success "✓ GKE autoscaling disabled on selected pools"
else
    log_success "✓ GKE autoscaling is disabled"
fi

# ==============================================================================
# STEP 4: Verify Workload Identity is Enabled
# ==============================================================================
log_step "STEP 4: Verifying Workload Identity"

WI_POOL=$(gcloud container clusters describe $CLUSTER_NAME --region=$REGION \
    --format="value(workloadIdentityConfig.workloadPool)" 2>/dev/null || echo "")

if [ -z "$WI_POOL" ]; then
    log_error "❌ Workload Identity is NOT enabled!"
    log_warning "Enable it with:"
    echo ""
    echo "gcloud container clusters update $CLUSTER_NAME \\"
    echo "  --region=$REGION \\"
    echo "  --workload-pool=${PROJECT_ID}.svc.id.goog"
    echo ""
    error_exit "Workload Identity must be enabled"
else
    log_success "✓ Workload Identity enabled: $WI_POOL"
fi

# Verify node pools have correct workload metadata (only selected pools)
for POOL in "${TARGET_POOLS[@]}"; do
    WL_METADATA=$(gcloud container node-pools describe $POOL \
        --cluster=$CLUSTER_NAME \
        --region=$REGION \
        --format="value(config.workloadMetadataConfig.mode)" 2>/dev/null || echo "")
    
    if [ "$WL_METADATA" != "GKE_METADATA" ]; then
        log_warning "Node pool '$POOL' needs GKE_METADATA workload metadata"
        log_info "Updating node pool (this will recreate nodes)..."
        gcloud container node-pools update $POOL \
            --cluster=$CLUSTER_NAME \
            --region=$REGION \
            --workload-metadata=GKE_METADATA
        log_success "✓ Node pool updated"
    else
        log_success "✓ Node pool '$POOL' already has GKE_METADATA"
    fi
done

# ==============================================================================
# STEP 5: Create GCP Service Account
# ==============================================================================
log_step "STEP 5: Creating GCP Service Account"

if gcloud iam service-accounts describe $GCP_SA_EMAIL &> /dev/null; then
    log_success "✓ Service account already exists: $GCP_SA_EMAIL"
else
    log_info "Creating service account..."
    gcloud iam service-accounts create $GCP_SA_NAME \
        --display-name="Cluster Autoscaler"
    log_success "✓ Service account created"
fi

# ==============================================================================
# STEP 6: Grant IAM Role
# ==============================================================================
log_step "STEP 6: Granting IAM Permissions"

log_info "Granting Compute Instance Admin (v1) role..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${GCP_SA_EMAIL}" \
    --role="roles/compute.instanceAdmin.v1" \
    --condition=None > /dev/null 2>&1 || log_warning "Role may already exist"

log_success "✓ IAM permissions granted"

# ==============================================================================
# STEP 7: Deploy ResourceQuota
# ==============================================================================
log_step "STEP 7: Deploying ResourceQuota"

log_info "Creating ResourceQuota for system-cluster-critical pods..."

if kubectl get resourcequota gcp-critical-pods -n $K8S_NAMESPACE &> /dev/null; then
    log_warning "ResourceQuota exists, recreating..."
    kubectl delete resourcequota gcp-critical-pods -n $K8S_NAMESPACE
fi

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
  name: gcp-critical-pods
  namespace: $K8S_NAMESPACE
spec:
  hard:
    pods: "10"
  scopeSelector:
    matchExpressions:
    - operator: In
      scopeName: PriorityClass
      values:
      - system-cluster-critical
EOF

log_success "✓ ResourceQuota created"
kubectl get resourcequota gcp-critical-pods -n $K8S_NAMESPACE

# ==============================================================================
# STEP 8: Install Helm Chart
# ==============================================================================
log_step "STEP 8: Installing Cluster Autoscaler Helm Chart"

log_info "Adding Helm repository..."
helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
helm repo update
log_success "✓ Helm repo added"

log_info "Available chart versions:"
helm search repo autoscaler/cluster-autoscaler --versions | head -5

# Check if already installed
if helm list -n $K8S_NAMESPACE | grep -q $HELM_RELEASE_NAME; then
    log_warning "Release exists, upgrading..."
    HELM_CMD="upgrade"
else
    HELM_CMD="install"
fi

log_info "Deploying cluster-autoscaler..."
log_info "Configuration:"
echo "  - Instance Group Prefix: $IG_PREFIX"
echo "  - Min Nodes: $MIN_NODES"
echo "  - Max Nodes: $MAX_NODES"
echo "  - Scale-up Delay: ${SCALE_UP_DELAY}s"
echo "  - Chart Version: $CHART_VERSION"

helm $HELM_CMD $HELM_RELEASE_NAME autoscaler/cluster-autoscaler \
    --set "autoscalingGroupsnamePrefix[0].name=${IG_PREFIX}" \
    --set "autoscalingGroupsnamePrefix[0].maxSize=${MAX_NODES}" \
    --set "autoscalingGroupsnamePrefix[0].minSize=${MIN_NODES}" \
    --set autoDiscovery.clusterName=${CLUSTER_NAME} \
    --set "rbac.serviceAccount.annotations.iam\.gke\.io\/gcp-service-account=${GCP_SA_EMAIL}" \
    --set cloudProvider=gce \
    --set "extraArgs.new-pod-scale-up-delay=${SCALE_UP_DELAY}s" \
    --set "extraArgs.v=4" \
    --set "extraArgs.logtostderr=true" \
    --set "extraArgs.stderrthreshold=info" \
    --namespace=$K8S_NAMESPACE \
    --version=$CHART_VERSION

log_success "✓ Cluster autoscaler deployed"

# ==============================================================================
# STEP 9: Create Workload Identity Binding
# ==============================================================================
log_step "STEP 9: Configuring Workload Identity Binding"

log_info "Waiting for pod to be created..."
sleep 15

# Get Kubernetes Service Account
K8S_SA=$(kubectl get sa -n $K8S_NAMESPACE -o name | grep cluster-autoscaler | head -n 1 | cut -d'/' -f2)

if [ -z "$K8S_SA" ]; then
    log_error "Cannot find Kubernetes Service Account"
    kubectl get sa -n $K8S_NAMESPACE
    error_exit "Service account not found"
fi

log_success "✓ Found K8s Service Account: $K8S_SA"

# Create IAM policy binding
log_info "Creating IAM policy binding..."
gcloud iam service-accounts add-iam-policy-binding $GCP_SA_EMAIL \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]" \
    > /dev/null 2>&1

log_success "✓ IAM binding created"

# Annotate Kubernetes Service Account
log_info "Annotating Kubernetes Service Account..."
kubectl annotate serviceaccount $K8S_SA \
    -n $K8S_NAMESPACE \
    iam.gke.io/gcp-service-account=$GCP_SA_EMAIL \
    --overwrite

log_success "✓ Service Account annotated"

# ==============================================================================
# STEP 10: Restart Pod
# ==============================================================================
log_step "STEP 10: Restarting Pod to Apply Workload Identity"

sleep 10

POD_NAME=$(kubectl get pods -n $K8S_NAMESPACE -l "app.kubernetes.io/name=gce-cluster-autoscaler" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$POD_NAME" ]; then
    log_info "Deleting pod: $POD_NAME"
    kubectl delete pod $POD_NAME -n $K8S_NAMESPACE
    
    log_info "Waiting for new pod..."
    sleep 20
    
    kubectl wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=gce-cluster-autoscaler" \
        -n $K8S_NAMESPACE \
        --timeout=120s || log_warning "Pod not ready yet"
    
    log_success "✓ Pod restarted"
fi

# ==============================================================================
# STEP 11: Verify Deployment
# ==============================================================================
log_step "STEP 11: Verifying Deployment"

NEW_POD=$(kubectl get pods -n $K8S_NAMESPACE -l "app.kubernetes.io/name=gce-cluster-autoscaler" -o jsonpath='{.items[0].metadata.name}')

log_info "Pod: $NEW_POD"
kubectl get pod $NEW_POD -n $K8S_NAMESPACE

log_info "Waiting for initialization..."
sleep 15

log_info "Checking logs..."
echo ""
echo "========== LOGS =========="
kubectl logs $NEW_POD -n $K8S_NAMESPACE --tail=50
echo "=========================="
echo ""

if kubectl logs $NEW_POD -n $K8S_NAMESPACE 2>/dev/null | grep -qi "error 403\|insufficientpermissions"; then
    log_error "❌ Authentication errors detected"
    log_warning "Wait 5 minutes for Workload Identity to propagate, then:"
    log_warning "kubectl delete pod $NEW_POD -n $K8S_NAMESPACE"
elif kubectl logs $NEW_POD -n $K8S_NAMESPACE 2>/dev/null | grep -qi "successfully"; then
    log_success "✅ Cluster Autoscaler is working!"
fi

# ==============================================================================
# SUCCESS
# ==============================================================================
log_step "🎉 Deployment Complete!"

cat <<EOF

${GREEN}Custom Cluster Autoscaler Deployed:${NC}
  ✓ GCP Service Account:   $GCP_SA_EMAIL
  ✓ K8s Service Account:   $K8S_SA
  ✓ Namespace:             $K8S_NAMESPACE
  ✓ Scale-up Delay:        ${SCALE_UP_DELAY}s
  ✓ Min Nodes:             $MIN_NODES
  ✓ Max Nodes:             $MAX_NODES
  ✓ Instance Group:        $IG_PREFIX*
  ✓ Target Pools:          ${TARGET_POOLS[@]}

${BLUE}Useful Commands:${NC}
  # Watch logs:
  kubectl logs -f $NEW_POD -n $K8S_NAMESPACE

  # Test (pods will wait ${SCALE_UP_DELAY}s before scaling):
  kubectl run test --image=nginx --requests='cpu=10000m'
  kubectl get pods -w

${YELLOW}Note:${NC} This autoscaler is NOT in kube-system to avoid conflicts with GKE.

EOF
