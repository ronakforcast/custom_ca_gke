# Custom Cluster Autoscaler for GKE

Deploy a custom cluster autoscaler on GKE with full control over scaling behavior.

## Why

GKE's managed autoscaler is locked down by Google. You can't change scale-up delays, scan intervals, or use advanced flags. This gives you full control.

**Key benefit:** Set `--new-pod-scale-up-delay=600s` to wait 10 minutes before scaling up (impossible with GKE's autoscaler).

## Prerequisites

- GKE cluster (Standard, not Autopilot)
- `gcloud`, `kubectl`, `helm` installed
- Workload Identity enabled on cluster

## Quick Start

```bash
chmod +x deploy-custom-ca.sh
./deploy-custom-ca.sh
```

**Prompts:**
- Cluster name, region
- Scale-up delay (default: 600s)
- Min/max nodes
- Target specific node pools or all pools

**What it does:**
1. Disables GKE's managed autoscaler (selected pools only)
2. Creates GCP service account with compute.instanceAdmin.v1
3. Deploys custom autoscaler via Helm (default namespace)
4. Configures Workload Identity bindings
5. Verifies deployment

**Time:** 5-10 minutes

## Example Run

```bash
$ ./deploy-custom-ca.sh

========================================
STEP 0: Checking Prerequisites
========================================
[SUCCESS] ✓ gcloud installed
[SUCCESS] ✓ kubectl installed
[SUCCESS] ✓ helm installed

========================================
STEP 1: Gathering Configuration
========================================
[INFO] Project ID: my-project-123
Enter cluster name: prod-cluster
Enter cluster region/zone: us-central1-c
Enter new-pod-scale-up-delay in seconds [600]: 600
Enter min nodes [1]: 1
Enter max nodes [10]: 10

[INFO] Fetching available node pools...

[INFO] Available node pools:
 1. default-pool
 2. gpu-pool
 3. batch-pool

Apply changes to specific node pools only? (yes/no) [no]: yes
Enter node pool names (comma-separated): batch-pool,gpu-pool
[SUCCESS] ✓ Selected pools: batch-pool gpu-pool

[INFO] Configuration:
  Project:        my-project-123
  Cluster:        prod-cluster
  Region:         us-central1-c
  GCP SA:         cluster-autoscaler@my-project-123.iam.gserviceaccount.com
  K8s Namespace:  default
  IG Prefix:      gke-prod-cluster
  Scale-up Delay: 600s
  Min Nodes:      1
  Max Nodes:      10
  Chart Version:  9.43.2
  Target Pools:   batch-pool gpu-pool

Continue? (yes/no): yes

========================================
STEP 2: Connecting to Cluster
========================================
[SUCCESS] ✓ Connected to cluster

========================================
STEP 3: Verifying GKE Autoscaling is Disabled
========================================
[INFO] Disabling autoscaling on pool: batch-pool
[INFO] Disabling autoscaling on pool: gpu-pool
[SUCCESS] ✓ GKE autoscaling disabled on selected pools

========================================
STEP 4: Verifying Workload Identity
========================================
[SUCCESS] ✓ Workload Identity enabled: my-project-123.svc.id.goog
[SUCCESS] ✓ Node pool 'batch-pool' already has GKE_METADATA
[SUCCESS] ✓ Node pool 'gpu-pool' already has GKE_METADATA

========================================
STEP 8: Installing Cluster Autoscaler Helm Chart
========================================
[INFO] Deploying cluster-autoscaler...
[SUCCESS] ✓ Cluster autoscaler deployed

========================================
STEP 11: Verifying Deployment
========================================
[INFO] Pod: custom-ca-gce-cluster-autoscaler-7d9f8b5c4-xk2m9

========== LOGS ==========
I0305 10:23:45.123456       1 main.go:515] Cluster autoscaler 1.30.0
I0305 10:23:45.234567       1 cloud_provider_builder.go:89] GCE resource limits: ...
I0305 10:23:46.345678       1 gce_manager.go:412] Discovered MIG: gke-prod-cluster-batch-pool-a1b2c3d4
I0305 10:23:46.456789       1 gce_manager.go:412] Discovered MIG: gke-prod-cluster-gpu-pool-e5f6g7h8
I0305 10:23:46.567890       1 static_autoscaler.go:230] Starting main loop
==========================

[SUCCESS] ✅ Cluster Autoscaler is working!

========================================
🎉 Deployment Complete!
========================================

Custom Cluster Autoscaler Deployed:
  ✓ GCP Service Account:   cluster-autoscaler@my-project-123.iam.gserviceaccount.com
  ✓ K8s Service Account:   custom-ca-gce-cluster-autoscaler
  ✓ Namespace:             default
  ✓ Scale-up Delay:        600s
  ✓ Min Nodes:             1
  ✓ Max Nodes:             10
  ✓ Instance Group:        gke-prod-cluster*
  ✓ Target Pools:          batch-pool gpu-pool

Useful Commands:
  # Watch logs:
  kubectl logs -f custom-ca-gce-cluster-autoscaler-7d9f8b5c4-xk2m9 -n default

  # Test (pods will wait 600s before scaling):
  kubectl run test --image=nginx --requests='cpu=10000m'
  kubectl get pods -w
```

## How It Works

```
Custom Autoscaler Pod (default namespace)
    ↓ watches pending pods
    ↓ waits 600s (configurable)
    ↓ scales GCE Instance Groups
GCE Managed Instance Groups (node pools)
```

**vs GKE Autoscaler:**
- GKE: ~10s delay, limited flags, hidden in kube-system
- Custom: Configurable delay, all flags available, visible in default namespace

## Configuration

### Critical Flag: Scale-Up Delay

```bash
--new-pod-scale-up-delay=600s
```

Pod pending → autoscaler waits 600s → still pending? → scale up

**Use cases:**
- Batch jobs: Wait to batch scale decisions
- Spot instances: Wait for cheaper nodes
- Cost optimization: Avoid rapid scaling

### Add More Flags

Edit `deploy-custom-ca.sh` helm command:

```bash
--set "extraArgs.scale-down-delay-after-add=10m"
--set "extraArgs.scale-down-unneeded-time=5m"
--set "extraArgs.skip-nodes-with-local-storage=false"
```

[All flags](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md#what-are-the-parameters-to-ca)

## Node Pool Selection

The script now supports targeting specific node pools:

```bash
Apply changes to specific node pools only? (yes/no) [no]: yes
Enter node pool names (comma-separated): gpu-pool,batch-pool
```

Only selected pools get:
- GKE autoscaling disabled
- Workload metadata set to GKE_METADATA

Other pools remain untouched.

## Selective Node Pools Example

Deploy to test workload with labels/taints:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  nodeSelector:
    usecase: test
  tolerations:
  - key: usecase
    value: test
    effect: NoSchedule
  containers:
  - name: app
    image: nginx
```

Result: Pod pending 600s → node scales up → pod schedules → idle 10m → node scales down

## Monitoring

```bash
# Watch logs
POD=$(kubectl get pods -n default -l app.kubernetes.io/name=gce-cluster-autoscaler -o jsonpath='{.items[0].metadata.name}')
kubectl logs -f $POD -n default

# Test scaling
kubectl run test --image=nginx --requests='cpu=10000m'
kubectl get pods -w
```

## Troubleshooting

**"Error 403" in logs:**
Wait 5 minutes for Workload Identity propagation, then restart pod:
```bash
kubectl delete pod $POD -n default
```

**Nodes not scaling down:**
Check for:
- Pods with `safe-to-evict: "false"` annotation
- Local storage
- PodDisruptionBudgets
- System pods

**Wrong instance group:**
Verify IG prefix matches: `gke-{CLUSTER_NAME}-*`

## Cleanup

```bash
# Remove autoscaler
helm uninstall custom-ca -n default

# Re-enable GKE autoscaling
gcloud container clusters update CLUSTER_NAME \
  --enable-autoscaling \
  --node-pool=POOL_NAME \
  --min-nodes=1 --max-nodes=10 \
  --region=REGION
```

## Important

- **You manage updates** - No automatic upgrades like GKE
- **Manual Helm upgrades** - Check for autoscaler breaking changes
- **Test first** - Don't experiment in production
- **Monitor logs** - Catch issues early

## Architecture

See the Mermaid diagram in the repository for component relationships.

## References

- [Original guide](https://vadasambar.com/post/kubernetes/how-to-deploy-custom-ca-on-gcp/)
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
- [Helm chart](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)
