# Changelog

What changed, release by release, newest on top. Each section is also the
release notes.

## [0.2.2] - 2026-10-05

The device map tells the truth about who holds what. A dongle in use by a client
on another cluster read as "not attached", with no client drawn, and the map
gave no reason; on the lab that looked like a dashboard that had stopped
updating. Only the pods image changes, `usb-ip-kubevirt` 0.2.2; the disk is
still `usb-ip-fedora` 0.2.0.

- The device map shows a device in use as in use even when nobody named its
  client. A client on another cluster reaches the exporter masqueraded, so its
  address names no VM: the map now draws an unnamed client under the device,
  and the panel says "a client it cannot name, seen as <address>" where it used
  to say "not attached" under a green "connected". A free device reads
  "nobody".
- `docs/limitations.md`: USB audio did not play over this path (measured).
- When devices are in use and nobody named their clients, the map says why at
  the bottom (the `usb-ip-assignments` ConfigMap is missing, empty, or names
  none of them) and gives the command that names one, with a real id.
- `undo.sh` keeps `usb-ip-assignments`, the client names you declared;
  `PURGE=yes` removes it too. It used to delete it, which is how the lab's map
  lost every name after a reinstall.

## [0.2.1] - 2026-10-01

The first public release. A USB device stays plugged into one node of an
OpenShift Virtualization cluster, and the VM that uses it runs, and moves,
anywhere, another cluster included. The VM still sees a local USB device; it
gets it over TCP.

- The exporter: a Fedora VM on the device's node gets the devices by
  passthrough and serves them with usbipd behind HAProxy on TCP 3240, to the
  same cluster through a Service and to other clusters through a MetalLB
  LoadBalancer.
- The disk it boots, `usb-ip-fedora` 0.2.0, unchanged in this release: Fedora
  with usbip, HAProxy and the exporter inside, from
  `ghcr.io/linuxelitebr/usb-ip-fedora` or `quay.io/elastocera/usb-ip-fedora`,
  pinned by digest. Nothing to install at boot. The exporter's service ships
  off, since the Linux client boots the same disk, and the exporter's
  cloud-init turns it on. A disk without the exporter, such as the stock Fedora
  one, boots and exports nothing, and says so in its kernel log.
- The clients: Windows, with usbip-win2 and a watchdog task that attaches the
  device and keeps it attached, and Linux, with usbip and an optional systemd
  timer per device that does the same. Both find the device by vendor:product,
  never by the exporter's slot, since a `DEVICES` change moves every slot. The
  Windows watchdog also cancels usbip-win2's own retries of an old slot.
- The node-side watchdog reports and a person acts. A device that leaves the
  node, comes back, or looks replugged shows up in `status.sh`, on the
  dashboard and as an alert in the OpenShift console, with the command that
  fixes it, `scripts/rediscover.sh`. It never edits or restarts the exporter
  VM: acting by itself meant guessing which device paths KubeVirt had
  captured, and the guess took a perfectly good second identical dongle out of
  the exporter. The cost: a device leaves the node, the exporter restarts
  before anyone runs the fix, and the exporter does not start until the device
  is back and `rediscover.sh` runs, or `apply.sh` drops it. The alert fires
  when the device leaves, while the exporter still runs.
- The dashboard: devices, hubs and the VMs that hold them, with the node that
  holds the dongles in bold, behind the OpenShift login.
- A quickstart, `docs/quickstart.md`: the exporter up, then the first client VM,
  Windows or Linux, step by step, with real output from the lab. The README's
  quick start has one block per role: the server, a Linux client, a Windows
  client.
- The pods run their own image, `usb-ip-kubevirt` 0.2.1, for amd64 and arm64:
  the dashboard's collector, the USB discovery, the watchdog and the dashboard
  page. Their code no longer ships inside the manifests.
- Both images carry our Python as minified bytecode, not source. The minified
  code passes the offline tests before it is compiled.
- `image/build-in-cluster.sh` builds the disk for the architecture of the node it
  runs on, taking the exporter from the `usb-ip-kubevirt` image. Tested on
  x86_64 only.

Measured: five dongles, two of them identical, on four client VMs on another
cluster, two Windows and two Linux, each set up from the docs on a fresh VM;
after a `DEVICES` change that moved every slot, each client back on its own
devices 11 to 31 seconds after the exporter was exporting; a Windows client's
device back within one 15-second check; a Linux client's back 18 to 36 seconds
after a detach; both clusters powered off and on, and the Windows clients
attached their devices by themselves; the exporter exporting 21 to 27 seconds
after its VM is running, with or without internet.
Not measured yet: a live migration of a client, and the watchdog's `missing`
and `lost` reports on a cluster. Read [the limitations](docs/limitations.md)
before you trust it with a license dongle.

## [0.2.0] - 2026-09-28

Images only, `usb-ip-fedora` 0.2.0 and `usb-ip-kubevirt` 0.2.0, never a release
of this repo. 0.2.1 is the first; its disk is still the 0.2.0 one.
