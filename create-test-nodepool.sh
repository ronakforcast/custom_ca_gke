#!/bin/bash

# ==============================================================================
# Add Existing Node Pool to Custom Cluster Autoscaler
# OR Create New Pool if it doesn't exist
# ==============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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
# Configuration
# ==============================================================================
log_step "Configure Node Pool for Custom Autoscaler"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    error_exit "No GCP project set"
fi

CLUSTER_NAME="gke-rp-030326"
REGION="us-central1-c"
POOL_NAME="test-pool"

log_info "Configuration:"
echo "  Project:  $PROJECT_ID"
echo "  Cluster:  $CLUSTER_NAME"
echo "  Region:   $REGION"
echo "  Pool:     $POOL_NAME"

# ==============================================================================
# STEP 1: Check if Node Pool Exists
# ==============================================================================
log_step "STEP 1: Checking Node Pool Status"

if gcloud container node-pools describe $POOL_NAME --cluster=$CLUSTER_NAME --region=$REGION &>/dev/null; then
    log_success "✓ Node pool '$POOL_NAME' already exists"
    
    # Show current configuration
    log_info "Current pool configuration:"
    gcloud container node-pools describe $POOL_NAME \
        --cluster=$CLUSTER_NAME \
        --region=$REGION \
        --format="table(name,config.machineType,initialNodeCount,config.labels,config.taints)"
    
    echo ""
    read -p "Do you want to (u)se existing pool, (d)elete and recreate, or (c)ancel? [u/d/c]: " ACTION
    
    case $ACTION in
        d|D)
            log_warning "Deleting existing node pool..."
            gcloud container node-pools delete $POOL_NAME \
                --cluster=$CLUSTER_NAME \
                --region=$REGION \
                --quiet
            log_success "✓ Pool deleted"
            CREATE_POOL=true
            ;;
        u|U)
            log_info "Using existing pool"
            CREATE_POOL=false
            ;;
        *)
            log_warning "Cancelled"
            exit 0
            ;;
    esac
else
    log_info "Node pool does not exist, will create it"
    CREATE_POOL=true
fi

# ==============================================================================
# STEP 2: Create Node Pool (if needed)
# ==============================================================================
if [ "$CREATE_POOL" = true ]; then
    log_step "STEP 2: Creating Node Pool"
    
    read -p "Enter machine type [e2-medium]: " MACHINE_TYPE
    MACHINE_TYPE=${MACHINE_TYPE:-e2-medium}
    
    read -p "Enter number of initial nodes [0]: " NUM_NODES
    NUM_NODES=${NUM_NODES:-0}
    
    log_info "Creating node pool with:"
    echo "  Machine Type:   $MACHINE_TYPE"
    echo "  Initial Nodes:  $NUM_NODES"
    echo "  Label:          usecase=test"
    echo "  Taint:          usecase=test:NoSchedule"
    
    gcloud container node-pools create $POOL_NAME \
        --cluster=$CLUSTER_NAME \
        --region=$REGION \
        --machine-type=$MACHINE_TYPE \
        --num-nodes=$NUM_NODES \
        --node-labels=usecase=test \
        --node-taints=usecase=test:NoSchedule \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --workload-metadata=GKE_METADATA \
        --enable-autorepair \
        --enable-autoupgrade
    
    log_success "✓ Node pool created"
fi

# ==============================================================================
# STEP 3: Get Instance Group Name
# ==============================================================================
log_step "STEP 3: Finding Instance Group"

log_info "Waiting for instance group..."
sleep 5

IG_PREFIX_NEW="gke-${CLUSTER_NAME}-${POOL_NAME}"
log_info "Instance Group Prefix: $IG_PREFIX_NEW"

# List matching instance groups
log_info "Available instance groups:"
gcloud compute instance-groups list --filter="name~${IG_PREFIX_NEW}" --format="table(name,zone,size)"

IG_FULL=$(gcloud compute instance-groups list --filter="name~${IG_PREFIX_NEW}" --format="value(name)" | head -n 1)

if [ -n "$IG_FULL" ]; then
    log_success "✓ Found instance group: $IG_FULL"
else
    log_warning "Instance group not found, waiting 10 more seconds..."
    sleep 10
    IG_FULL=$(gcloud compute instance-groups list --filter="name~${IG_PREFIX_NEW}" --format="value(name)" | head -n 1)
    
    if [ -n "$IG_FULL" ]; then
        log_success "✓ Found instance group: $IG_FULL"
    else
        error_exit "Could not find instance group. Check: gcloud compute instance-groups list"
    fi
fi

# ==============================================================================
# STEP 4: Get Autoscaler Min/Max Configuration
# ==============================================================================
log_step "STEP 4: Autoscaler Configuration"

read -p "Enter min nodes for autoscaler [0]: " MIN_NODES
MIN_NODES=${MIN_NODES:-0}

read -p "Enter max nodes for autoscaler [10]: " MAX_NODES
MAX_NODES=${MAX_NODES:-10}

log_info "Autoscaler will manage this pool with:"
echo "  Min Nodes: $MIN_NODES"
echo "  Max Nodes: $MAX_NODES"

# ==============================================================================
# STEP 5: Get Existing Autoscaler Configuration
# ==============================================================================
log_step "STEP 5: Getting Existing Autoscaler Configuration"

if ! helm list -n default | grep -q "custom-ca"; then
    error_exit "custom-ca Helm release not found. Deploy the autoscaler first."
fi

log_info "Retrieving current autoscaler settings..."

# Try to get existing config
if command -v jq &> /dev/null; then
    EXISTING_PREFIX=$(helm get values custom-ca -n default -o json | jq -r '.autoscalingGroupsnamePrefix[0].name' 2>/dev/null || echo "")
    EXISTING_MIN=$(helm get values custom-ca -n default -o json | jq -r '.autoscalingGroupsnamePrefix[0].minSize' 2>/dev/null || echo "")
    EXISTING_MAX=$(helm get values custom-ca -n default -o json | jq -r '.autoscalingGroupsnamePrefix[0].maxSize' 2>/dev/null || echo "")
else
    log_warning "jq not installed, need manual input"
    EXISTING_PREFIX=""
fi

if [ -z "$EXISTING_PREFIX" ] || [ "$EXISTING_PREFIX" == "null" ]; then
    log_warning "Could not auto-detect existing pool configuration"
    read -p "Enter EXISTING pool prefix (e.g., gke-${CLUSTER_NAME}): " EXISTING_PREFIX
    read -p "Enter EXISTING pool min nodes [1]: " EXISTING_MIN
    EXISTING_MIN=${EXISTING_MIN:-1}
    read -p "Enter EXISTING pool max nodes [10]: " EXISTING_MAX
    EXISTING_MAX=${EXISTING_MAX:-10}
fi

log_info "Current autoscaler configuration:"
echo "  [0] Prefix: $EXISTING_PREFIX"
echo "  [0] Min:    $EXISTING_MIN"
echo "  [0] Max:    $EXISTING_MAX"

log_info "Will add new pool:"
echo "  [1] Prefix: $IG_PREFIX_NEW"
echo "  [1] Min:    $MIN_NODES"
echo "  [1] Max:    $MAX_NODES"

read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    exit 0
fi

# ==============================================================================
# STEP 6: Update Custom Cluster Autoscaler
# ==============================================================================
log_step "STEP 6: Updating Custom Cluster Autoscaler"

log_info "Updating autoscaler to manage BOTH node pools..."

helm upgrade custom-ca autoscaler/cluster-autoscaler \
    --namespace=default \
    --reuse-values \
    --set "autoscalingGroupsnamePrefix[0].name=${EXISTING_PREFIX}" \
    --set "autoscalingGroupsnamePrefix[0].minSize=${EXISTING_MIN}" \
    --set "autoscalingGroupsnamePrefix[0].maxSize=${EXISTING_MAX}" \
    --set "autoscalingGroupsnamePrefix[1].name=${IG_PREFIX_NEW}" \
    --set "autoscalingGroupsnamePrefix[1].minSize=${MIN_NODES}" \
    --set "autoscalingGroupsnamePrefix[1].maxSize=${MAX_NODES}"

log_success "✓ Autoscaler configuration updated"

# ==============================================================================
# STEP 7: Restart Autoscaler Pod
# ==============================================================================
log_step "STEP 7: Restarting Autoscaler Pod"

POD_NAME=$(kubectl get pods -n default -l "app.kubernetes.io/name=gce-cluster-autoscaler" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_NAME" ]; then
    error_exit "Cannot find cluster autoscaler pod"
fi

log_info "Deleting pod: $POD_NAME"
kubectl delete pod $POD_NAME -n default

log_info "Waiting for new pod..."
sleep 15

kubectl wait --for=condition=ready pod \
    -l "app.kubernetes.io/name=gce-cluster-autoscaler" \
    -n default \
    --timeout=120s || log_warning "Pod not ready yet"

NEW_POD=$(kubectl get pods -n default -l "app.kubernetes.io/name=gce-cluster-autoscaler" -o jsonpath='{.items[0].metadata.name}')
log_success "✓ Pod restarted: $NEW_POD"

# ==============================================================================
# STEP 8: Verify Configuration
# ==============================================================================
log_step "STEP 8: Verifying Configuration"

log_info "Waiting for initialization..."
sleep 10

log_info "Checking autoscaler logs..."
echo ""
echo "========== AUTOSCALER LOGS =========="
kubectl logs $NEW_POD -n default --tail=50 | grep -v "reflector.go"
echo "====================================="
echo ""

# ==============================================================================
# STEP 9: Create Test Deployment
# ==============================================================================
log_step "STEP 9: Creating Test Deployment"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-workload
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-workload
  template:
    metadata:
      labels:
        app: test-workload
    spec:
      nodeSelector:
        usecase: test
      tolerations:
      - key: "usecase"
        operator: "Equal"
        value: "test"
        effect: "NoSchedule"
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF

log_success "✓ Test deployment created"

# ==============================================================================
# SUCCESS
# ==============================================================================
log_step "✅ Configuration Complete!"

cat <<EOF

${GREEN}Autoscaler Now Managing:${NC}
  [0] ${EXISTING_PREFIX}* (min: ${EXISTING_MIN}, max: ${EXISTING_MAX})
  [1] ${IG_PREFIX_NEW}* (min: ${MIN_NODES}, max: ${MAX_NODES})

${BLUE}Monitor:${NC}
  # Watch pods (will wait 600s before scaling):
  kubectl get pods -o wide -w

  # Watch nodes:
  watch kubectl get nodes -l usecase=test

  # Check autoscaler:
  kubectl logs -f $NEW_POD -n default

${YELLOW}Cleanup:${NC}
  kubectl delete deployment test-workload

EOF