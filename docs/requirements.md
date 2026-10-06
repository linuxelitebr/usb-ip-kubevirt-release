# Requirements

OpenShift Virtualization already running on every cluster involved, MetalLB on
the exporter's cluster if clients live elsewhere, and four tools on your
machine. This page installs MetalLB, user workload monitoring and, only to
build the disk image on the cluster, the internal registry; setting up OpenShift
Virtualization itself is not what this project is about.

| Where | What it needs |
| --- | --- |
| The cluster with the USB device | OpenShift Virtualization installed and working, with persistent storage, and the device plugged into one of its nodes |
| The same cluster, if clients live on another one | MetalLB, and a free IP on that node's LAN (`LB_IP`) |
| Every cluster with client VMs | OpenShift Virtualization installed and working, with persistent storage |
| The cluster with the USB device, for the watchdog's alerts | user workload monitoring switched on (optional) |
| Your machine | `oc`, `virtctl`, `jq` and bash, logged in as cluster-admin |

The nodes pull two images, both pinned by digest: the VMs' disk,
`quay.io/elastocera/usb-ip-fedora`, and what the pods run,
`quay.io/elastocera/usb-ip-kubevirt`. The same bytes are on ghcr.io, under
`ghcr.io/linuxelitebr`. Nothing needs the internet after that: the disk has
usbip, HAProxy and the exporter inside, and the pods install nothing when they
start. A cluster that reaches neither registry can mirror the two images, or
build its own disk
([server side](server.md#boot-without-internet-the-prebuilt-image)).

Measured on two single-node clusters, the exporter's on bare metal: OpenShift
4.21.32, OpenShift Virtualization 4.21.17, MetalLB 4.21.0.

## MetalLB (clients on another cluster)

Already installed? Check first:

```bash
oc get csv -n metallb-system
```

If it lists MetalLB as `Succeeded`, skip step 1 and go straight to the
instance. Applying the operator file on top of an existing install adds a second
OperatorGroup to the namespace, and OLM fails every operator in a namespace with
two of them (`TooManyOperatorGroups`).

**1. Install the operator** and wait for its CSV:

```bash
oc apply -f deploy/operators/metallb-operator.yaml
until oc get csv -n metallb-system -l operators.coreos.com/metallb-operator.metallb-system -o name | grep -q .; do sleep 5; done
oc wait csv -n metallb-system -l operators.coreos.com/metallb-operator.metallb-system --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
```

**2. Create the instance**, without which the operator runs and announces
nothing:

```bash
oc apply -f deploy/operators/metallb.yaml
until oc get deployment/controller -n metallb-system >/dev/null 2>&1; do sleep 5; done
oc wait deployment/controller -n metallb-system --for=condition=Available --timeout=5m
oc rollout status daemonset/speaker -n metallb-system --timeout=5m
```

That is all MetalLB needs from you. The address pool and the L2 advertisement
come from `apply.sh` with `CROSS_CLUSTER=yes` and `LB_IP`
(`deploy/40-exporter-metallb.yaml`), announced on `br-ex`; change that there if
your node's LAN interface is another one.

The operator file labels the namespace `openshift.io/cluster-monitoring=true`,
so OpenShift's own Prometheus collects MetalLB's metrics, which is what its
ServiceMonitors are written for. Without the label, user workload monitoring
rejects them (last section, step 3).

Measured: exactly these commands, on a cluster with no MetalLB. The operator was
`Succeeded` after 71 seconds, and the controller and speaker were ready at 84.

## The internal registry (building the disk on the cluster only)

`image/build-in-cluster.sh` pushes to the OpenShift internal registry, which on
bare metal starts `Removed`. It needs a volume and to be switched on.

**1. Create the volume**, a ReadWriteOnce claim on your default StorageClass:

```bash
oc apply -f deploy/operators/image-registry-pvc.yaml
```

**2. Switch the registry on** with that claim:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"managementState":"Managed","storage":{"pvc":{"claim":"image-registry-storage"}}}}'
```

**3. One replica, Recreate rollout**, which is what OpenShift asks of a
registry on a ReadWriteOnce volume. Then bounce the replicas so the registry
comes back up under it:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"rolloutStrategy":"Recreate"}}'
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"replicas":0}}'
sleep 30
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"replicas":1}}'
```

The lab's registry runs like that: `Managed`, one replica, `Recreate`, on a
100 GiB claim.

## User workload monitoring (the watchdog's alerts)

The watchdog's alerts are a ServiceMonitor and a PrometheusRule in the
exporter's namespace (`deploy/85-watchdog-alerts.yaml`). OpenShift's own
Prometheus does not read those in a workload's namespace; user workload
monitoring does. Without it the two objects just sit there, and `apply.sh` says
so.

Already on? Check first:

```bash
oc get pods -n openshift-user-workload-monitoring
```

**1. Switch it on.** When `oc get configmap cluster-monitoring-config -n
openshift-monitoring` says NotFound, create it:

```bash
oc create configmap cluster-monitoring-config -n openshift-monitoring --from-literal=config.yaml='enableUserWorkload: true'
```

If that ConfigMap exists, it holds your monitoring settings: add
`enableUserWorkload: true` to its `config.yaml` with `oc edit` instead of
replacing it.

**2. Wait for its three pods**, an operator, a Prometheus and a Thanos Ruler,
with the same command as the check above.

On the lab's single node they were running 18 seconds after the ConfigMap, and
8 minutes later the three used 19 millicores and 289 MiB between them. The
watchdog shows up as a target about 80 seconds after `apply.sh` creates the
ServiceMonitor.

**3. Got `PrometheusOperatorRejectedResources` right after?** Another operator's
namespace lacks `openshift.io/cluster-monitoring=true`. User workload monitoring
reads every namespace without that label, and refuses the ServiceMonitors
written for OpenShift's own Prometheus. Measured with MetalLB installed without
the label: its two ServiceMonitors were rejected, because they read a token from
a file. The label hands them back to OpenShift's Prometheus, which had both
targets up about 100 seconds later, and the alert cleared:

```bash
oc label namespace metallb-system openshift.io/cluster-monitoring=true
```

Why not an alert on the logs? The watchdog logs a change once, so an alert on
its log lines fires for the length of its window and then clears while the
device is still gone. The metric holds the state until the device is back. And
a log store costs far more for this job: LokiStack's smallest production size
asks for 8 vCPUs and 18 GiB with its ruler.
