# Dashboard

A small map of what is plugged in and who has it. The exporter publishes a live
`state.json` on port 3241 (one entry per bound device, each marked connected or
free from the kernel's `usbip_status`). The page draws it as a topology:
exporter on top, devices under it, client VMs under those, green when
attached, gray when free, red when a person has to act, and black for what
another VM holds by passthrough.

![The dashboard: the exporter, the three devices on its node, and the Windows VMs holding two of them](dashboard.avif)

## Who holds what

`apply.sh` deploys it as a small collector pod that serves the page and an
enriched `state.json`: it adds the exporter's node, and the client VM you
declared for each device in the `usb-ip-assignments` ConfigMap (key `0a12_0001`
or a busid, value `vm@cluster`). Declared, not discovered: a cross-cluster client
reaches the exporter masqueraded, so its address does not say which VM it is. A
device you declared that the exporter does not have shows up red. If the
exporter stops answering, the map keeps its last device list, grays it out and
says since when, instead of passing its last "connected" off as live.

## Hubs, and what else is plugged in

**Hubs come back from the node's side.** Passthrough flattens the tree: inside
the exporter every device sits on a root port. So `apply.sh` also runs one small
pod per node (`deploy/65-usb-discovery.yaml`) that reads the node's
`/sys/bus/usb` and serves it on 3242. The collector puts each exported device
back on its node port, the map draws the hubs between the exporter and the
device, and the device panel shows the port and the USB controller. No
privileges and no hostPath: sysfs is not namespaced, so a plain pod already sees
the node's USB tree (measured under OpenShift's `restricted-v2`, 11 MiB per pod).
A passed-through device is the one bound to `usbfs`, because QEMU holds it. The
exporter's panel lists what else is plugged into its node, which is where the
next device for `DEVICES` shows up. Two identical devices (same ids, serial and
name) cannot be told apart, and the panel says the port is a guess.

## Devices held by other VMs

**A device passed through to another VM shows that VM.** On the node, QEMU holds
a passed-through device through `usbfs`, which says some VM has it, not which
one. The collector works it out: every running VMI on the node asks for host
devices by name, and KubeVirt's allowlist says which vendor:product each name
selects. That VM goes on the exporter's row with its devices under it, in the
neutral color, because usbip has no say over them. When two VMs ask for the same
vendor:product, which got which is a guess, and the panel says so. A VM in
another namespace takes a cluster-wide read of VMIs
(`deploy/62-dashboard-other-vms.yaml`), and whoever may open the page sees
those names, namespaces they cannot read included. `OTHER_VMS=no` leaves that
read out; the map then names only the VMs in its own namespace.

## Sessions, from HAProxy

**HAProxy knows how long each client has been attached.** The exporter serves
what HAProxy's admin socket says on `/haproxy.json`, and the map puts it where it
fits: on the exporter, HAProxy's uptime and its sessions (now, peak, since
start); on an attached device, how long the client has held it, when data last
moved, and the bytes each way, which match usbipd's own socket counters to the
byte (measured). HAProxy's frontend byte counters are left out on purpose: they
stand still while a session is open, and a usbip session stays open for days.
"Seen from" is the address after NAT. A same-cluster client shows its pod IP;
every client through the LoadBalancer shows the node's own OVN address
(`externalTrafficPolicy: Cluster`). That is why the client VM on the map still
comes from `usb-ip-assignments`.

## Reaching it

The page loads nothing from the internet: Cytoscape and the fonts ship with it in
the `usb-ip-kubevirt` image, so it works from a browser with no outside access.

On OpenShift `apply.sh` also creates a Route and prints its URL, behind
OpenShift's own login. An oauth-proxy next to the collector lets in whoever may
read the dashboard's Service in that namespace, and the collector itself listens
on 127.0.0.1 only. Measured: without a login the page, `state.json` and the
activity monitor's switch all answer 403 with OpenShift's sign-in page, and
another pod gets its connection refused. The proxy is the cluster's own, from the
`openshift/oauth-proxy` ImageStream, so a mirrored release carries it along.

With `ROUTE=no` there is no Route; port-forward straight to the collector, which
your cluster login already guards, and open `http://localhost:8080`:

```bash
oc port-forward deploy/usb-ip-dashboard 8080
```

## Without a cluster

The page also runs straight from the image, with made-up data and no cluster
at all:

```bash
podman run --rm -p 8080:8080 quay.io/elastocera/usb-ip-kubevirt:latest python -m http.server 8080 -d /www
```

Then `http://localhost:8080/?state=state.sample.json` shows a small map with
nested hubs, and `?state=state.stress.json` shows 24 dongles behind four
daisy-chained hubs. `?state=http://<exporter-status>:3241/state.json` points it
at a real exporter instead.

![The stress sample: 24 dongles and six client VMs, synthetic data](multiple-usb-connected.avif)

That is `state.stress.json`, not a lab: made-up dongles and VMs, there to show
how the map copes with a crowded exporter.
