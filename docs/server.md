# Server side: the exporter

The exporter is a small Fedora VM that gets the USB device by passthrough and
shares it over TCP with `usbipd`. Passthrough pins it to the node that has the
device, which is fine: sharing the device is its only job. The node cannot do
this itself, because RHCOS ships no usbip kernel modules.

Before you start: OpenShift Virtualization installed and working, with
persistent storage, and MetalLB for clients on other clusters.
[The requirements](requirements.md) install MetalLB if it is missing.

## Deploy it

**1. Find the device's vendor:product on the node.** RHCOS has no `lsusb`, so
read sysfs from a debug pod:

```bash
oc debug node/<node> -- chroot /host sh -c 'for d in /sys/bus/usb/devices/[0-9]*; do [ -f $d/idVendor ] || continue; echo "$(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done'
```

```text
3-10 05e3:0608 USB2.0 Hub
3-10.2 0cf3:9271 USB2.0 WLAN
3-13 0a12:0001 CSR8510A10
```

The first column is the node's busid. A dotted one (`3-10.2`) sits behind a hub.

**2. Run `apply.sh`.** It is idempotent and takes everything from env vars:

```bash
DEVICES=0a12:0001 ./scripts/apply.sh
```

| Variable | Default | What it does |
| --- | --- | --- |
| `DEVICES` | `0a12:0001` | what to export: `vendor:product` in lowercase hex, space separated (`VENDOR` and `PRODUCT` still work for one) |
| `RESOURCE_NAME` | `kubevirt.io/usb-dongle` | the allowlist name for a device that has none yet, when you export one kind of device ([several](#several-devices-one-exporter)) |
| `NAMESPACE` | `default` | where the VMs and Services go, created if missing |
| `CROSS_CLUSTER` | `no` | `yes` adds the MetalLB LoadBalancer |
| `LB_IP` | none | the LoadBalancer's address, a free IP on your LAN; required with `CROSS_CLUSTER=yes` |
| `LINUX_CLIENT` | `no` | `yes` adds a Fedora client VM to test with |
| `DASHBOARD` | `yes` | the device map pod, plus a Route on OpenShift |
| `ROUTE` | `yes` | the dashboard's Route, behind the OpenShift login; `no` leaves it out, and `oc port-forward deploy/usb-ip-dashboard 8080` reaches the page ([details](dashboard.md)) |
| `OTHER_VMS` | `yes` | lets the map name the VM holding a device passed through on the exporter's node, in any namespace: a cluster-wide read of VMIs ([why](dashboard.md)) |
| `WATCHDOG` | `yes` | reports a device that left the node or that KubeVirt lost, with the command that fixes it; it changes nothing itself ([below](#when-a-device-leaves-the-node-the-watchdog-tells-you)) |
| `ALERTS` | `yes` | alerts on the watchdog's state in the OpenShift console; they need user workload monitoring ([requirements](requirements.md#user-workload-monitoring-the-watchdogs-alerts)) |
| `USB_IP_IMAGE` | `usb-ip-kubevirt`, by digest | what the dashboard, discovery and watchdog pods run; the same bytes are on ghcr.io |
| `OAUTH_PROXY_IMAGE` | the cluster's own | the dashboard's login proxy, from the ImageStream `openshift/oauth-proxy:v4.4`, pinned by digest; set it when that ImageStream is missing |
| `DISK_IMAGE` | `usb-ip-fedora`, by digest | the containerDisk both VMs boot, with usbip, HAProxy and the exporter inside ([below](#boot-without-internet-the-prebuilt-image)) |
| `SSH_PUBKEY` | none | an SSH public key file, your only way into the VMs (see below) |
| `OC` | `oc` | put `--context=...` here if you juggle clusters |

The VMs have no password. Port 22 answers on the pod network, and a known
password on the VM that holds your license dongle is a gift to anyone who can
reach it. Pass `SSH_PUBKEY=~/.ssh/id_ed25519.pub` and log in with the matching
private key. Without it there is no way in over SSH, and `fedora` has no
password for the console either:

```bash
virtctl ssh -i ~/.ssh/id_ed25519 fedora@vm/usb-ip-exporter
```

**Pro tip: `virtctl ssh` needs no Service.** It runs your own `ssh` with a
proxy command that tunnels through the Kubernetes API into the VM's pod, so it
gets through masquerade with no NodePort or LoadBalancer, and RBAC decides who
gets in. The port still has to be open on the VM's interface, which is why the
exporter lists 22. `virtctl scp` rides the same tunnel, and so does
`virtctl port-forward vm/usb-ip-exporter 3241:3241` for any other open port.

The catch: the containerDisk starts fresh on every boot, so the VM comes up
with new SSH host keys (measured: written 15 seconds after boot), and after any
restart `ssh` refuses with `REMOTE HOST IDENTIFICATION HAS CHANGED`. The old
keys sit in your `~/.ssh/known_hosts` under `vm.<vm>.<namespace>`; virtctl's
`--known-hosts` flag changed nothing here (virtctl 1.9.0). Drop the stale entry
after a restart:

```bash
ssh-keygen -R vm.usb-ip-exporter.default
```

Or skip the check for these VMs. The tunnel itself runs inside the API's TLS,
but you do give up what the host key check protects:

```bash
virtctl ssh -i ~/.ssh/id_ed25519 -t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null" fedora@vm/usb-ip-exporter
```

One more catch if you juggle clusters: `virtctl --context=<ctx> ssh` does not
hand the context to the proxy command it starts, so the tunnel goes to your
current context (virtctl 1.9.0), and mine answered `not found`. Switch the
current context first, or run `ssh` with the proxy command spelled out:

```bash
ssh -i ~/.ssh/id_ed25519 -o "ProxyCommand=virtctl --context=<ctx> port-forward --stdio=true vm/usb-ip-exporter/default 22" fedora@vm.usb-ip-exporter.default
```

On OpenShift a re-run says `configured` for the exporter VM even when nothing
changed: kubemacpool writes a MAC into the VM, and `oc apply` sends the
interface back without it. When the running exporter really is behind its spec
(a new image, a new device), `apply.sh` says so and prints the `virtctl restart`
to run.

**3. Wait for the boot.** With the default image the exporter exported 21 to 27
seconds after its VM was running. The first start on a node pulls that image
first, about 1 GiB, which took 3 minutes in the lab. It is ready when its status
endpoint lists the device:

```bash
./scripts/status.sh
oc port-forward -n default svc/usb-ip-exporter-status 3241:3241 &
sleep 3
curl -sS localhost:3241/state.json
kill $!
```

```json
{"generated":"2026-09-24T19:22:12Z","exporter":{"name":"usb-ip-exporter","node":"usb-ip-exporter"},"devices":[{"busid":"1-1","vidpid":"0a12:0001","serial":"","name":"CSR8510 A10","status":"free"}]}
```

That `busid` is the exporter's own numbering (`1-1`, `1-2`, ...), not the
node's, and it is what clients attach to. `status` turns `connected` while a
client holds the device.

**4. Tear it down** with the same env vars: `./scripts/undo.sh`. From the
HyperConverged allowlist it removes only the entries `apply.sh` created, never
one that was there before, and it leaves the namespace alone. The MetalLB pool
only goes away with `CROSS_CLUSTER=yes`, because it is cluster-wide.

## Several devices, one exporter

List them all in `DEVICES`:

```bash
DEVICES="0a12:0001 045e:0800 0d8c:000c" ./scripts/apply.sh
```

Each one becomes a hostDevice on the exporter (`usb0`, `usb1`, ...). A device
already on the allowlist keeps the name it has there, because a second name on
the same vendor:product breaks both (see the rules below). A new one gets
`RESOURCE_NAME` when `DEVICES` holds one kind of device, and
`kubevirt.io/usb-<vendor>-<product>` otherwise. `apply.sh` records the names it
created on the exporter VM, which is how `undo.sh` knows what to remove.

Measured: a dongle the allowlist already had plus a USB WiFi it did not. The
WiFi entry was created, the exporter listed both, an identical second run left
the allowlist as it was, and `undo.sh` removed the WiFi entry and nothing else.
A fresh install of four devices on an empty allowlist created all four entries,
and `undo.sh` later removed exactly those four.

Two identical devices: list the vendor:product twice, and `apply.sh` waits
until the node advertises that many. Measured with two of these dongles: the
exporter got both (`1-1` and `1-2`), and a Linux client attached both by busid
and came up with two Bluetooth adapters. Clients tell them apart by busid, see
[the Windows client](client-windows.md#2-attach-the-device).

## Boot without internet: the prebuilt image

It is the default, and since 0.2.0 the only kind of disk that works. Both VMs
boot `usb-ip-fedora`: Fedora 44 with usbip, its kernel modules, HAProxy and the
exporter already inside, so nothing in them needs a package mirror at boot. The
exporter's service ships off, since the Linux client boots the same disk; the
exporter's cloud-init is what turns it on. `apply.sh` pins the disk by digest,
and the same bytes are in two registries:

| Registry | Image |
| --- | --- |
| Quay | `quay.io/elastocera/usb-ip-fedora`, the default: the registry client networks let through most often |
| GitHub | `ghcr.io/linuxelitebr/usb-ip-fedora`, the same bytes |

On a running VM, `cat /etc/usbip-image` says what it carries:

```text
kernel 7.2.7-200.fc44.x86_64: usbip-core usbip-host vhci-hcd present; usbip-5.7.9-14.fc44.x86_64 haproxy-3.0.27-1.fc44.x86_64
```

Measured with the 0.2.0 disk. A fresh install on a node that had never pulled
it had the VM running 2 minutes 45 seconds after `apply.sh` started, the pull
from Quay included, and exporting four devices 25 seconds later. A restart with
every outbound connection to the internet blocked by a NetworkPolicy exported 21
seconds after the VM was running: cluster DNS answered, quay.io and the Fedora
mirrors did not. The clients on the other cluster came back by themselves, the
Windows one 17 seconds and the Linux one 76 seconds after the exporter was back.
The same disk built on the cluster (below) started the exporter the same way,
`usbip-serve.pyc` under Fedora's python3, and `state.json` answered.

### Build it yourself

For an arm64 cluster, one that pulls from neither registry, or one that wants
its own build: on the cluster, with the OpenShift internal registry, a node with
KVM (KubeVirt hands `/dev/kvm` to the build pod) and internet for the build
itself. The disk comes out for that node's architecture, and the exporter's
files come from the `usb-ip-kubevirt` image, the one the pods run. It took 9 and
a half and 11 minutes in two runs on x86_64; arm64 is not tested:

```bash
./image/build-in-cluster.sh
```

It prints the line to deploy with, pinned by digest. A rebuilt image keeps its
tag, and a node that already has the old one will not pull it again, so the tag
alone can boot a stale image:

```bash
DISK_IMAGE=image-registry.openshift-image-registry.svc:5000/usb-ip-kubevirt/fedora-usbip@sha256:<digest> DEVICES=0a12:0001 ./scripts/apply.sh
```

`image/fedora-usbip.sh`, which that Job runs, needs Linux with KVM and
libguestfs (`PUSH=no` keeps the result as an OCI layout). It runs
`image/guest-setup.sh` inside the disk, the same steps the published image was
built with.

## How a USB device reaches a VM at all, and what apply.sh sets up

Most people never plug a USB device into a Kubernetes node and hand it to a VM,
so here is the whole path, in two steps. If you run GitOps instead of
`apply.sh`, these are also the pieces.

First, the cluster has to allow that specific device. OpenShift Virtualization
keeps an allowlist on the HyperConverged CR, keyed by vendor:product, and each
entry gets a name:

```yaml
spec:
  permittedHostDevices:
    usbHostDevices:
      - resourceName: kubevirt.io/usb-dongle
        selectors:
          - vendor: "0a12"
            product: "0001"
```

Once that lands, the node with the device advertises it like any other
schedulable resource, `kubevirt.io/usb-dongle: 1`. If it says 0, the device is
not plugged into that node, the ids are wrong, or two entries fight over it
(the rules below).

Second, a VM claims it, and QEMU hands the physical device to that guest:

```yaml
hostDevices:
  - deviceName: kubevirt.io/usb-dongle
    name: usb0
```

That is real passthrough, and it is exactly what pins a VM to the node. So it
happens once, on the exporter, whose only job is to share the device, and never
on the VM that runs your workload.

The exporter VM claims it (`deploy/20-exporter-vm.yaml`, one `hostDevices`
entry per device), gets its cloud-init
from a Secret because inline user-data is capped at 2048 bytes
(`deploy/10-exporter-cloudinit.yaml`), runs usbipd behind HAProxy (see the last
section), and sits behind two Services: `usb-ip-exporter` on 3240 for clients and
`usb-ip-exporter-status` on 3241 for the dashboard.

## Rules that cost me hours

- **One resourceName per device.** Two resourceNames on the same vendor:product
  fight over it and the node advertises 0. `apply.sh` reuses the name a device
  already has instead of adding a second. And several selectors under one
  resourceName mean AND (all devices present at once), not OR. My first "hubs
  do not work" result was exactly this mistake, not a hub problem. Ask me how I
  know.
- **A hostDevice is mandatory.** If the device is missing when the exporter
  starts, the exporter does not start (`Allocate failed ... no such file`, then
  CrashLoopBackOff), and every other device on it goes down too. The watchdog
  (below) tells you which device and what to run. Pass through devices that
  stay plugged in; anything you plug and unplug is a one-off test.
- **Unplug and replug a passed-through device, and KubeVirt keeps the dead
  one.** It comes back with a new device number, and can come back on another
  port path too (same physical port, `3-10.2` became `3-10.3`). KubeVirt's
  device plugin never notices: the node still advertises the device, the running
  exporter keeps a ghost of it (still listed, still offered to clients), and a
  restart of the exporter fails with `Allocate failed ... error opening the
  socket /dev/bus/usb/003/025 ... no such file`, which takes every other device
  on it down too. The fix is to make KubeVirt discover the device again: take
  its entry off the HyperConverged allowlist, put it back, give the exporter the
  device back and restart it. `scripts/rediscover.sh` does all of that (next
  section). A device plugged in after its entry already exists is different:
  KubeVirt picked it up on its own, 5 seconds after it appeared.
- **Port 3240 unless you pass one.** Clients default to 3240, and another port
  is a global flag (`usbip --tcp-port N`), never host:port. Same cluster: the
  `usb-ip-exporter` Service, by that short name from the exporter's namespace
  and as `usb-ip-exporter.<namespace>.svc.cluster.local` from any other.
  Anything else: `CROSS_CLUSTER=yes` with `LB_IP`,
  which serves the native 3240 on a stable LAN IP. A NodePort also works, with
  `--tcp-port` on Linux and `-Port` on the Windows scripts (both tested from
  another cluster); the catch is that clients then point at one node's IP.
- **A disk without the exporter exports nothing.** The stock Fedora image boots
  fine and exports nothing; the exporter's kernel log says
  `this disk has no exporter`. Use `usb-ip-fedora` 0.2.0 or newer, or build one
  (above).

## When a device leaves the node, the watchdog tells you

`apply.sh` deploys a watchdog with the exporter (`WATCHDOG=no` leaves it out).
Every 10 seconds it compares the devices you asked for with the node's real USB
tree, from the discovery pods. It trusts nothing else: after an unplug the node
still advertises the device and the exporter still lists it.

**It only reports.** It never edits the exporter VM and never restarts it; a
person runs the fix. An earlier version took a device that left out of the
exporter and restarted it. To do that it had to guess which device paths
KubeVirt's USB plugin captured at start, which nothing outside KubeVirt can
read, and the guess kept breaking in new layouts. The last time, it took a
perfectly good second identical dongle out of the exporter. Ask me how I know.

Each device gets a state, and a state changes only when two checks in a row
agree:

| State | What it means | The fix |
| --- | --- | --- |
| `ok` | on the node and in the exporter VM's `hostDevices`. That is its spec: a running exporter has only what was there when it started | none |
| `missing` | the node has fewer devices of that vendor:product than you asked for, whatever driver holds them | plug it back in, then `rediscover.sh` |
| `lost` | a device the exporter held left, and one of its kind sits on a new number, off the exporter: a replug, suspected. Also when the exporter cannot start because KubeVirt hands out the path that device last had | `rediscover.sh` |
| `back` | on the node, but someone took it out of the exporter VM's `hostDevices` | `rediscover.sh` |

The fix is one command with the device's id, and the watchdog prints it with
the id filled in:

```bash
VIDPID=0cf3:9271 ./scripts/rediscover.sh
```

That takes the device's allowlist entry off and puts it back, gives that device
back to the exporter if it is not there, and restarts the exporter. It runs in
18 to 20 seconds. It refuses if another VM uses the same entry, since that VM
loses it too while the entry is off (`FORCE=yes` overrides).

**The catch: run it before the exporter restarts.** While the exporter runs, a
device that left costs only its own client. Restart the exporter first, and it
does not start (`Allocate failed`, or `Pending` for a device the node lacks):
every device on it stays down until the device is back and `rediscover.sh`
runs, or `apply.sh` drops it. The alert fires when the device leaves, while the
exporter still runs, so there is time. If the exporter is already down on
`Allocate failed`, the watchdog reads the path in KubeVirt's event for the
latest start attempt and names the device last seen there. When it never saw a
device there, it says so once, in a `USBExporterCannotStart` event and on a
`note:` line in `status.sh`, with the command to run.

**`rediscover.sh` needs the device back on the node first.** It restarts the
exporter, so every other device in the exporter VM's `hostDevices` has to be
there too, or that restart is what takes them all down. For a device that is
not coming back, run `apply.sh` again with the same settings and `DEVICES`
minus its id, then `virtctl restart usb-ip-exporter -n <namespace>`. Not
measured yet.

It tells you in five places: a Warning event on the exporter VM
(`USBDeviceMissing`, `USBDeviceLost`, `USBDeviceBack`), the dashboard (the
device in red, the command in its panel), `status.sh`, metrics on port 9420
(`usb_ip_device_state`), and alerts in the OpenShift console (below).

What it reports in the cases measured with the earlier watchdog, replayed
offline in `tests/watchdog_test.py`. On a cluster with this one, only the twin
row is measured so far:

| What happened | What it reports |
| --- | --- |
| WiFi unplugged, exporter running | `missing`; the exporter keeps running with the rest |
| WiFi plugged back in, under a new number, on the node's `ath9k_htc` | `lost` |
| exporter restarted into `Allocate failed` on the WiFi's old path | `lost`, from the path in KubeVirt's event |
| joystick missing at start, VM stuck `Pending` | `missing` |
| two identical dongles asked for, the second still on the node's `btusb` until the exporter restarts | both `ok`, before and after the restart (measured: the second stayed in `hostDevices` 80 seconds before the restart and through four more). The earlier watchdog took it out 17 seconds after `apply.sh` |
| `rediscover.sh` run | `ok` once the exporter holds the device again |

**The alerts follow a state, not an event.** `apply.sh` also adds a
ServiceMonitor and a PrometheusRule on those metrics
(`deploy/85-watchdog-alerts.yaml`; `ALERTS=no` leaves them out), which need
user workload monitoring ([requirements](requirements.md#user-workload-monitoring-the-watchdogs-alerts)).
Each alert fires for as long as the thing is wrong and clears by itself once it
is fixed, and its description carries the command that fixes it.

| Alert | Fires when | Severity |
| --- | --- | --- |
| `USBDeviceMissing` | a device is not on the node, for 1 minute | warning |
| `USBDeviceLost` | a replugged device KubeVirt did not follow, for 1 minute | warning |
| `USBDeviceBack` | a device is on the node but out of the exporter VM's `hostDevices`, for 1 minute | warning |
| `USBExporterDown` | the exporter is not running, for 5 minutes | critical |
| `USBWatchdogBlind` | the watchdog runs but cannot see the exporter or the node's USB tree, for 5 minutes | warning |
| `USBWatchdogDown` | no metrics from the watchdog, for 5 minutes | warning |

Measured on the test exporter with the earlier watchdog, with the joystick's
receiver gone. The metrics and the rules are the same in this one; the full
round, unplug to `rediscover.sh`, is not measured yet with it:

| What happened | What the alerts did |
| --- | --- |
| receiver not on the node | `USBDeviceMissing` fired one minute after its first evaluation, in the platform's Alertmanager with the device's vendor:product, allowlist name and namespace |
| `rediscover.sh` (18 s) | the device was in the exporter 40 s later; `USBExporterDown` went pending during the restart and cleared without firing, which is what its 5 minutes are for |

## USB hubs

They work, per device, with no extra config. Tested behind a USB 2.0 hub
(`05e3:0608`): every device on it was advertised, and a USB WiFi the host had
already claimed went all the way through to a VM on another cluster.

Two things to know. The exporter sees flat busids (`1-1`, `1-2`), so the hub is
invisible inside it; the dashboard draws it again from the node's side (see
[the dashboard](dashboard.md#hubs-and-what-else-is-plugged-in)). And a bus-powered hub once dropped that WiFi off the
exporter during a USB reset; power is the suspect, not proven. A dongle draws
next to nothing, but use a powered hub for anything hungrier.

## A client that dies without detaching leaves the device busy

Not anymore: HAProxy in front of usbipd drops the dead session in under a
minute, on either image.

usbipd sets no TCP keepalive on client sessions, and an idle dongle sends
nothing, so a client that vanished (reboot, crash, a new pod IP after a
migration) used to leave its session open and its device marked in use. Every
new attach got this, for the 9 minutes I watched:

```text
usbip: error: Attach Request for 1-1 failed - Device busy (exported)
```

So clients reach HAProxy on 3240, and HAProxy relays to usbipd on
127.0.0.1:3239. HAProxy turns TCP keepalive on for every client (`clitcpka`: 30
seconds idle, a probe every 10, 3 probes). When a client stops answering,
HAProxy closes its side, and the kernel frees the device the same way it does on
a normal detach. Measured through it:

| The client | Device free again | Client attached again |
| --- | --- | --- |
| rebooted without detaching | 23 to 29 seconds (two runs) | 53 seconds, by its own timer |
| pod killed, back with a new IP | 42 seconds | on its first try |

A live client that just sits idle keeps its session: it answers the probes, and
6.5 minutes without a single byte of USB traffic changed nothing. A Windows
client attached through HAProxy too, from another cluster.

Three settings make it work, all in `deploy/10-exporter-cloudinit.yaml` and
`deploy/20-exporter-vm.yaml`:

- **No `timeout client` or `timeout server`.** HAProxy caps any timeout at about
  24.8 days, and keepalive does not count as activity, so a timeout would
  eventually drop an idle dongle. HAProxy warns about the missing timeouts at
  start; that is expected.
- **The SELinux boolean `haproxy_connect_any`.** Without it HAProxy cannot bind
  3240 or reach usbipd on 3239.
- **Only 3240, 3241 and 22 reach the VM.** usbipd has no bind-address option, so
  it listens on 3239 everywhere; the VM's interface lists its ports so nobody
  skips HAProxy.

HAProxy's stats socket (`/var/lib/haproxy/stats`) lists every session with the
real client address, which usbipd no longer sees. If a session ever sticks
anyway, free the device from the exporter (`virtctl ssh`, with the key you gave
as `SSH_PUBKEY`; without one, `virtctl restart usb-ip-exporter` frees them all):

```bash
sudo usbip unbind -b 1-1
```

The exporter binds it again within 5 seconds. A real live migration is still not
measured; the killed pod above is the closest stand-in.
