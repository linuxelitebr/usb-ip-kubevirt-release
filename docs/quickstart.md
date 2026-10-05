# Quickstart

From an empty OpenShift Virtualization cluster to a USB device in a VM, in two
parts: the exporter on the cluster that has the device, then your first client
VM, Windows or Linux. Each step links to the doc with the why. The outputs are
real, from the lab, with the LoadBalancer IP masked as 192.0.2.50.

## Part 1: the exporter

You need OpenShift Virtualization working on the cluster with the device and on
any cluster with client VMs, `oc`, `virtctl`, `jq` and bash on your machine,
logged in as cluster-admin, and nodes that pull from quay.io or a mirror of it
([requirements](requirements.md)). Measured on OpenShift 4.21.32, OpenShift
Virtualization 4.21.17 and MetalLB 4.21.0.

**1. Get the scripts.** The repo is a single commit, replaced on every release:
to update, clone again.

```bash
git clone https://github.com/linuxelitebr/usb-ip-kubevirt-release.git
cd usb-ip-kubevirt-release
```

**2. Find the device's vendor:product** on the node it is plugged into. RHCOS
has no `lsusb`, so this reads sysfs from a debug pod:

```bash
oc get nodes
oc debug node/<node> -- chroot /host sh -c 'for d in /sys/bus/usb/devices/[0-9]*; do [ -f $d/idVendor ] || continue; echo "$(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done'
```

```text
3-10 05e3:0608 USB2.0 Hub
3-10.2 0cf3:9271 USB2.0 WLAN
3-13 0a12:0001 CSR8510A10
```

You want the second column. Not sure which line is yours? Unplug the device, run
it again, and yours is the line that went away. A hub needs no entry: export the
device behind it. For a first run pick a plain device, a Bluetooth dongle, say;
[some devices do not behave](limitations.md#some-devices-do-not-behave).

**3. Clients on another cluster only: install MetalLB.** Skip this step when
every client VM runs on this cluster. Skip the first block when
`oc get csv -n metallb-system` already shows MetalLB `Succeeded`: a second
install makes OLM fail every operator in that namespace
(`TooManyOperatorGroups`).

```bash
oc apply -f deploy/operators/metallb-operator.yaml
until oc get csv -n metallb-system -l operators.coreos.com/metallb-operator.metallb-system -o name | grep -q .; do sleep 5; done
oc wait csv -n metallb-system -l operators.coreos.com/metallb-operator.metallb-system --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
```

Then the instance, without which the operator runs and announces nothing:

```bash
oc apply -f deploy/operators/metallb.yaml
until oc get deployment/controller -n metallb-system >/dev/null 2>&1; do sleep 5; done
oc wait deployment/controller -n metallb-system --for=condition=Available --timeout=5m
oc rollout status daemonset/speaker -n metallb-system --timeout=5m
```

**4. Deploy the exporter** with your vendor:product and an SSH public key, the
only way into its VM (there is no password):

```bash
DEVICES=0a12:0001 SSH_PUBKEY=~/.ssh/id_ed25519.pub ./scripts/apply.sh
```

For clients on another cluster, add `CROSS_CLUSTER=yes LB_IP=<lan-ip>`, a free
IP on the LAN of the node's `br-ex` (the subnet of its INTERNAL-IP in
`oc get nodes -o wide`), outside any MetalLB pool you already have: `apply.sh`
makes its own. Look for `all advertised` near the top of
the output: `still not advertised` does not stop the script, which ends with
`done` either way. It took 23 to 29 seconds in three lab installs.

- Everything goes into the `default` namespace unless you set `NAMESPACE`; then
  pass it to `status.sh` and `undo.sh` too.
- Pass the same variables on every run. Left out, `DEVICES` falls back to
  `0a12:0001` and `SSH_PUBKEY` to no key.
- Two identical devices (same vendor:product, whatever their names say): list
  the id twice to export both, `DEVICES="0a12:0001 0a12:0001"`. Listed once,
  the exporter gets one of them and the other stays on the node.
- Anyone who reaches port 3240 can take a free device: keep `LB_IP` on a network
  only your clients reach
  ([details](limitations.md#anyone-who-reaches-port-3240-can-take-a-free-device)).
- `user workload monitoring is off` only means nobody reads the console alerts
  yet ([details](requirements.md#user-workload-monitoring-the-watchdogs-alerts)).

**5. Check it.** The first start on a node pulls the disk, about 1 GiB: in the
lab, a fresh install on such a node had the VM running 2 minutes 45 seconds
after `apply.sh` started and exporting 25 seconds later. With the disk already
on the node, all four devices were exported 47 and 63 seconds after `apply.sh`
started, in two installs.

```bash
./scripts/status.sh
```

The end of the lab's output:

```text
== watchdog: each device against the node's real USB tree ==
usb0  0a12:0001  ok
usb1  045e:0800  ok
usb2  0d8c:000c  ok
usb3  0cf3:9271  ok

== hint: what a client attaches to ==
same namespace:     usbip list -r usb-ip-exporter
another namespace:  usbip list -r usb-ip-exporter.default.svc.cluster.local
another cluster:    usbip list -r 192.0.2.50
```

Each device should read `ok`, and the hint is the address a client uses. The
exporter is ready when its status endpoint lists the device, `free` until a
client holds it and `connected` while one does:

```bash
oc port-forward -n default svc/usb-ip-exporter-status 3241:3241 &
sleep 3
curl -sS localhost:3241/state.json
kill $!
```

## Part 2: the first client VM

### Which address does the client use?

The one for where the VM runs; the end of `status.sh` prints all three:

| The client VM runs | `<host>` |
| --- | --- |
| in the exporter's namespace | `usb-ip-exporter` |
| in another namespace of the same cluster | `usb-ip-exporter.<namespace>.svc.cluster.local` |
| on another cluster | the LoadBalancer IP, your `LB_IP` |

Spell the middle one out: from a Fedora VM in another namespace, neither the
short name nor `usb-ip-exporter.default.svc` resolves (measured). Both same
cluster rows need the VM on the pod network, the default; a VM only on a bridge
or localnet network needs the LoadBalancer IP even on the same cluster (not
measured). A device serves one client at a time, and a held one is missing from
every other client's list.

### Windows

The usual case: the VM that runs the licensed app, with no host device in its
spec. Secure Boot stays on, since the usbip-win2 driver is attestation-signed.
The four scripts are unsigned. On Windows Server 2025, whose default is
`RemoteSigned`, they ran as they were after coming in over `scp` (measured).
`RemoteSigned` refuses an unsigned script marked as downloaded from the internet
with `is not digitally signed`, and `Unblock-File` takes the mark off (both
measured). Windows 10 and 11 refuse scripts by default (not measured here).

**1. Download usbip-win2 0.9.8.0 on your machine, not in the VM.** GitHub hands
the download to a CDN host that a locked-down VM often cannot reach, and it
hangs with no error.

```bash
curl -fLO https://github.com/vadimgrn/usbip-win2/releases/download/v.0.9.8.0/USBip-0.9.8.0-x64.exe
```

Copy it and the four scripts from the clone's `windows/` folder into
`C:\usbip-lab\` on the VM, however you move files there. With an SSH server in
the VM, make the folder and `scp` through `virtctl port-forward`, from the
clone (measured):

```bash
ssh -o "ProxyCommand=virtctl port-forward --stdio=true vm/<vm>/<namespace> 22" Administrator@vm.<vm>.<namespace> "mkdir C:\usbip-lab"
scp -o "ProxyCommand=virtctl port-forward --stdio=true vm/<vm>/<namespace> 22" USBip-0.9.8.0-x64.exe windows/*.ps1 Administrator@vm.<vm>.<namespace>:C:/usbip-lab/
```

The watchdog runs its script from that folder and logs there. Each release also
carries the scripts as `usb-ip-kubevirt-windows-v<version>.zip` on
[the releases page](https://github.com/linuxelitebr/usb-ip-kubevirt-release/releases),
with no folder inside, to unzip straight into it. Saved by a browser, they carry
the downloaded mark: run `Get-ChildItem C:\usbip-lab | Unblock-File` once.

**2. Install the driver once**, from an elevated PowerShell in that folder:

```powershell
cd C:\usbip-lab
.\install-usbip.ps1 -InstallerPath C:\usbip-lab\USBip-0.9.8.0-x64.exe -Sha256 81f426741f7ee2ed991febe24a22daca8400b6ae2f171054e3fb404897e15d39
```

It checks the hash and the signature, then installs silently. On a VM with no
internet, the warning `signature valid offline` is expected.

**3. List, then attach once by hand**, so a wrong address fails here and not
quietly in a log:

```powershell
& "C:\Program Files\USBip\usbip.exe" list -r <host>
.\usbip-attach.ps1 -Server <host> -VidPid 0a12:0001
& "C:\Program Files\USBip\usbip.exe" port
```

The list shows usbip's own error. The attach script turns every failure into
`no 0a12:0001 exported by <host>` after 60 seconds. With two identical devices,
each client takes whichever one is free; `-BusId` pins the exporter's slot, and
slots move when `DEVICES` changes (measured). Device Manager then shows the device like
a local one; over SSH,
`Get-PnpDevice -PresentOnly | ? InstanceId -match 'VID_0A12&PID_0001'` lists
it, every row Status OK.

**4. Register the watchdog** with the same `-Server` and `-VidPid`:

```powershell
.\register-watchdog.ps1 -Server <host> -VidPid 0a12:0001
```

A SYSTEM task, from startup, checks every 15 seconds, attaches the device again
when it is gone, and keeps Windows from powering it down. Its log,
`C:\usbip-lab\watchdog.log`, starts with a `watchdog start` line naming the
server and ids; no log means the task cannot find its script. Measured in the
lab: back within one check after a detach, 30 seconds after a reboot, and within
10 seconds of a freshly installed exporter exporting. Only on the VM meant to
keep the device: it takes the device again whenever it comes free, so
[remove it first](client-windows.md#give-it-back) to give the device back.

### Linux (Fedora)

Also the client to reach for when Windows misbehaves: a device that works here
means the device and the exporter are fine. No Fedora VM at hand? `apply.sh`
with `LINUX_CLIENT=yes` adds one in the exporter's namespace, usbip included, so
skip step 1 there ([how to log in](client-linux.md#attach-a-device)).

**1. Install usbip, and the module for the kernel the VM runs:**

```bash
sudo dnf install -y usbip kernel-modules-extra-$(uname -r)
sudo modprobe vhci-hcd
```

The Fedora 44 cloud image has no `vhci-hcd`. `usbip` alone pulls a newer kernel
and its modules instead, and `modprobe` fails until a reboot (measured).
`kernel-modules-extra` also brings `kernel-modules`, with class drivers the
cloud image leaves out, `snd-usb-audio` for one (measured).

**2. See what the exporter offers:**

```bash
usbip list -r <host>
```

```text
Exportable USB devices
======================
 - 192.0.2.50
        1-4: Qualcomm Atheros Communications : AR9271 802.11n (0cf3:9271)
           : /sys/devices/pci0000:00/0000:00:02.4/0000:05:00.0/usb1/1-4
           : Vendor Specific Class / Vendor Specific Subclass / Vendor Specific Protocol (ff/ff/ff)
```

Yours is the line that ends in your vendor:product, `(0cf3:9271)` here. The
name comes from usbip's own id list and can differ from what the node printed
in step 1 of Part 1. The busid before the colon, `1-4`, is the exporter's
numbering, not the node's.

**3. Attach it by busid**, and check:

```bash
sudo usbip attach -r <host> -b <busid>
sudo usbip port
```

```text
Imported USB devices
====================
Port 00: <Port in Use> at High Speed(480Mbps)
       Qualcomm Atheros Communications : AR9271 802.11n (0cf3:9271)
       1-1 -> usbip://usb-ip-exporter.default.svc.cluster.local:3240/1-4
           -> remote bus/dev 001/005
```

As far as the kernel cares, the device is local now. A driver that needs
firmware needs it in the guest, and the cloud image has none.
`sudo usbip detach -p 00` gives the device back.

**4. Keep it attached.** `usbip attach` is one-shot: after an exporter restart,
nothing brings the device back. Save the script, the service and the timer from
[the Linux client doc](client-linux.md#keep-it-attached) with your host, then
turn the timer on for your device's vendor:product. It finds the device by that
id, since a busid moves when `DEVICES` changes (measured):

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now usbip-attach@0cf3:9271.timer
```

Measured: back 18 to 36 seconds after a manual detach in three runs, a minute at
most, since the timer checks every 60. Only on the VM meant to keep the device:
the timer grabs it again within a minute whenever it comes free, so
[stop it first](client-linux.md#keep-it-attached) to give the device back.

## When it does not work

- **`still not advertised`, or no node lists the device in `status.sh`.** The
  device is on no node, the ids are wrong, or two allowlist names fight over it.
  Nodes without the device always print `=0`
  ([how a device reaches a VM](server.md#how-a-usb-device-reaches-a-vm-at-all-and-what-applysh-sets-up),
  [the rules](server.md#rules-that-cost-me-hours)).
- **A device reads `missing`, `lost` or `back`.** On a first run, `missing`
  means the id in `DEVICES` is not on the node: check it against step 2. Later,
  run the command on its line, before the exporter restarts: the watchdog only
  reports
  ([the watchdog](server.md#when-a-device-leaves-the-node-the-watchdog-tells-you)).
- **The exporter VMI never gets to `Running`.**
  `oc get vm usb-ip-exporter -n default` shows where it is stuck, and
  `oc get events -n default --sort-by=.lastTimestamp` why. On a first run it is
  usually the pull from quay.io, or ids that are not on the node.
- **Nothing answers on the LoadBalancer IP.** `<pending>` under EXTERNAL-IP in
  `oc get svc usb-ip-exporter-lb -n default` means MetalLB assigned nothing:
  check its instance (step 3). An assigned IP that nobody reaches is not on the
  LAN of the node's `br-ex`.
- **The device is not in the list, or `Device busy (exported)`.** Another
  client holds it, or one died without detaching, which the exporter clears in
  under a minute
  ([details](server.md#a-client-that-dies-without-detaching-leaves-the-device-busy)).
- **Windows: `no 0a12:0001 exported by <host>` from the attach, or
  `not exported by <host>` in the watchdog's log.** A name that does not
  resolve, the exporter down, a wrong `-VidPid` or a held device:
  `usbip.exe list -r <host>` says which
  ([details](client-windows.md#when-it-misbehaves)).
- **Windows: attached, Status OK, does nothing.** Windows powered the device
  down, and usbip cannot wake it
  ([details](client-windows.md#windows-powers-idle-devices-down-and-usbip-cannot-wake-them)).
- **Linux: `Module vhci-hcd not found`.** `usbip` brought a newer kernel's
  modules: reboot into it (measured), or use step 1's line on a fresh VM. If dnf
  finds no `kernel-modules-extra` for your kernel, install `usbip` alone and
  reboot (not measured).
