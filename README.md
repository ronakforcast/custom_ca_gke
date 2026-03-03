# Custom Cluster Autoscaler for GKE

A simple way to deploy and manage a custom cluster autoscaler on Google Kubernetes Engine (GKE) with full control over autoscaling behavior.

## Why This Exists

GKE's built-in autoscaler works great, but it's **managed by Google** and you **cannot change its behavior**. You can't:

- ❌ Set a delay before scaling up (e.g., wait 10 minutes to see if pods schedule)
- ❌ Change scan intervals or thresholds
- ❌ Customize scale-down behavior
- ❌ Use advanced autoscaler features

**This solution lets you:**

- ✅ Deploy your own cluster autoscaler with full control
- ✅ Set custom flags like `--new-pod-scale-up-delay=600s` (wait 10 minutes before adding nodes)
- ✅ Manage multiple node pools with different configurations
- ✅ Use taints and labels for workload isolation
- ✅ Scale node pools to 0 when not in use (save money!)

## What You Get

Two bash scripts that handle everything:

1. **`deploy-custom-ca.sh`** - Deploys the custom cluster autoscaler (Please Read It befoer using)
2. **`add-nodepool.sh`** - Adds new node pools to the autoscaler

## Prerequisites

- A GKE cluster (Standard, not Autopilot)
- `gcloud` CLI installed and authenticated
- `kubectl` configured to access your cluster
- `helm` 3.x installed
- Basic knowledge of Kubernetes concepts

## Quick Start

### Step 1: Deploy Custom Cluster Autoscaler

```bash
chmod +x deploy-custom-ca.sh
./deploy-custom-ca.sh
```

**You'll be asked for:**
- Cluster name
- Region/zone
- Scale-up delay (default: 600 seconds = 10 minutes)
- Min/max nodes

**The script will:**
1. ✅ Verify Workload Identity is enabled
2. ✅ Disable GKE's managed autoscaler
3. ✅ Create GCP service account with permissions
4. ✅ Deploy custom cluster autoscaler via Helm
5. ✅ Configure Workload Identity bindings
6. ✅ Verify everything works

**Expected time:** 5-10 minutes

### Step 2: Add Custom Node Pools (Optional)

Want a separate node pool for specific workloads? (e.g., batch jobs, test environments)

```bash
chmod +x add-nodepool.sh
./add-nodepool.sh
```

**This creates:**
- A node pool with custom labels and taints
- Can scale to 0 nodes (no cost when idle!)
- Managed by your custom autoscaler

## How It Works

### Architecture

```
┌─────────────────────────────────────────────┐
│  Custom Cluster Autoscaler (in default ns) │
│  - Watches for pending pods                 │
│  - Waits 600s (configurable)                │
│  - Scales GCE Instance Groups directly      │
└─────────────────────────────────────────────┘
                    │
                    │ Manages
                    ▼
┌─────────────────────────────────────────────┐
│  GCE Managed Instance Groups (MIGs)         │
│  - Default pool: min 1, max 10              │
│  - Test pool: min 0, max 10                 │
└─────────────────────────────────────────────┘
```

### Key Differences from GKE Autoscaler

| Feature | GKE Managed | Custom (This Solution) |
|---------|-------------|------------------------|
| Scale-up delay | ~10 seconds (fixed) | Configurable (e.g., 600s) |
| Customization | Limited flags only | All autoscaler flags |
| Namespace | Hidden (kube-system) | `default` (visible) |
| Control | Google manages | You manage |
| Updates | Automatic | Manual (via Helm) |

## Configuration

### Scale-Up Delay

The most important flag: `--new-pod-scale-up-delay=600s`

**What it does:**
- Pod becomes pending at time 0
- Autoscaler sees it but **ignores it** for 600 seconds
- After 600 seconds, if still pending → scales up

**Why use it?**
- Give the scheduler time to rearrange existing pods
- Avoid scaling for temporary spikes
- Wait for spot instances to become available
- Batch multiple pending pods before scaling

### Other Useful Flags

You can add any flag in `deploy-custom-ca.sh`:

```bash
--set "extraArgs.scale-down-delay-after-add=10m"
--set "extraArgs.scale-down-unneeded-time=5m"
--set "extraArgs.skip-nodes-with-local-storage=false"
```

See [all flags here](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md#what-are-the-parameters-to-ca)

## Using Custom Node Pools

### Example: Test Workload Pool

The `add-nodepool.sh` creates a pool with:
- Label: `usecase=test`
- Taint: `usecase=test:NoSchedule`
- Min nodes: 0 (saves money!)
- Max nodes: 10

**Deploy a pod to this pool:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-test-pod
spec:
  nodeSelector:
    usecase: test          # Must match label
  tolerations:
  - key: "usecase"
    operator: "Equal"
    value: "test"
    effect: "NoSchedule"   # Must tolerate taint
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
```

**What happens:**
1. Pod created → stays pending for 600 seconds
2. After 600s → autoscaler adds a node to test-pool
3. Pod schedules on new node
4. When pod deleted → node scales down to 0 after ~10 minutes

## Extending to More Node Pools

### Option 1: Run the Script Again

```bash
./add-nodepool.sh
# Enter different pool name when prompted
```

### Option 2: Manual Helm Upgrade

```bash
# Add pool [2]
helm upgrade custom-ca autoscaler/cluster-autoscaler \
  --namespace=default \
  --reuse-values \
  --set "autoscalingGroupsnamePrefix[2].name=gke-CLUSTER-new-pool" \
  --set "autoscalingGroupsnamePrefix[2].minSize=0" \
  --set "autoscalingGroupsnamePrefix[2].maxSize=20"

# Restart autoscaler pod
kubectl delete pod -n default -l app.kubernetes.io/name=gce-cluster-autoscaler
```

### Option 3: Create Node Pool First

```bash
# Create the GKE node pool
gcloud container node-pools create gpu-pool \
  --cluster=my-cluster \
  --region=us-central1-c \
  --machine-type=n1-standard-4 \
  --accelerator=type=nvidia-tesla-t4,count=1 \
  --num-nodes=0 \
  --node-labels=workload=gpu \
  --node-taints=workload=gpu:NoSchedule \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --workload-metadata=GKE_METADATA

# Then run add-nodepool.sh to add it to autoscaler
```

## Common Use Cases

### 1. Batch Jobs

**Problem:** Batch jobs create 100 pods at once, scale-up is too aggressive

**Solution:**
```bash
# Set 10-minute delay
--new-pod-scale-up-delay=600s
```
Autoscaler waits to batch the scale-up decision

### 2. Spot/Preemptible Workloads

**Problem:** Want to wait for cheap spot instances instead of scaling immediately

**Solution:**
```bash
# Set 5-minute delay + use spot node pool
--new-pod-scale-up-delay=300s
```

### 3. Dev/Test Environments

**Problem:** Need isolated node pool that scales to 0 when not used

**Solution:**
```bash
# Create pool with min=0
./add-nodepool.sh
# Enter min nodes: 0
```

### 4. Cost Optimization

**Problem:** Too many rapid scale-ups/downs waste money

**Solution:**
```bash
--new-pod-scale-up-delay=600s
--scale-down-unneeded-time=10m
```

## Monitoring

### Check Autoscaler Status

```bash
# Get pod name
POD=$(kubectl get pods -n default -l app.kubernetes.io/name=gce-cluster-autoscaler -o jsonpath='{.items[0].metadata.name}')

# Watch logs
kubectl logs -f $POD -n default

# Check for errors
kubectl logs $POD -n default | grep -i error
```

### Verify Node Pools

```bash
# List all node pools
gcloud container node-pools list --cluster=CLUSTER_NAME --region=REGION

# Check instance groups
gcloud compute instance-groups list | grep gke-
```

### Test Scaling

```bash
# Create pending pod
kubectl run test --image=nginx --requests='cpu=10000m'

# Watch (should be pending for 600s)
kubectl get pods -w

# Watch nodes being created
watch kubectl get nodes
```

## Troubleshooting

### Autoscaler Not Scaling

**Check logs:**
```bash
kubectl logs -n default -l app.kubernetes.io/name=gce-cluster-autoscaler --tail=100
```

**Common issues:**
- ❌ **"Error 403"** → Workload Identity not configured correctly
- ❌ **"Cannot find instance group"** → Wrong instance group prefix
- ❌ **Pod pending forever** → Check node selector/tolerations

### Authentication Errors

```bash
# Verify Workload Identity binding
gcloud iam service-accounts get-iam-policy \
  cluster-autoscaler@PROJECT_ID.iam.gserviceaccount.com

# Should show: serviceAccount:PROJECT_ID.svc.id.goog[default/SERVICE_ACCOUNT]
```

### Nodes Not Scaling Down

**Common reasons:**
- Pod has `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` annotation
- Pod has local storage
- PodDisruptionBudget prevents eviction
- Node has system pods

**Check:**
```bash
kubectl describe node NODE_NAME
```

## Cleanup

### Remove Test Deployment
```bash
kubectl delete deployment test-workload
```

### Remove Node Pool
```bash
gcloud container node-pools delete test-pool \
  --cluster=CLUSTER_NAME \
  --region=REGION
```

### Remove Autoscaler (back to GKE managed)
```bash
# Delete custom autoscaler
helm uninstall custom-ca -n default

# Re-enable GKE autoscaling
gcloud container clusters update CLUSTER_NAME \
  --enable-autoscaling \
  --node-pool=POOL_NAME \
  --min-nodes=1 \
  --max-nodes=10 \
  --region=REGION
```

## Important Notes

### Security
- ✅ Uses Workload Identity (no service account keys!)
- ✅ Follows principle of least privilege
- ✅ All resources visible via `kubectl`

### Limitations
- ⚠️ **You manage updates** - Not automatic like GKE
- ⚠️ **Manual Helm upgrades** needed for new versions
- ⚠️ **Breaking changes** possible with autoscaler updates

### Best Practices
- 📝 **Document your configuration** - Save Helm values
- 🔄 **Test in dev first** - Don't experiment in production
- 📊 **Monitor logs** - Watch for errors after deployment
- 💰 **Use min=0 for test pools** - Save costs

## Reference

- [Original guide](https://vadasambar.com/post/kubernetes/how-to-deploy-custom-ca-on-gcp/)
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
- [All available flags](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md#what-are-the-parameters-to-ca)
- [Helm chart docs](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)

## Support

**Found a bug?** Check the logs first, then review the troubleshooting section.

**Need help?** The scripts have extensive logging - read the output carefully.

**Want to contribute?** Improve the scripts and share them!

---

**Made with ❤️ for engineers who need more control over GKE autoscaling**
