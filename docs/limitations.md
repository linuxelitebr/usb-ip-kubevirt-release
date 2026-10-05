# Limitations

What does not work yet, or works with a catch. Read it before you trust this
with a license dongle.

## Anyone who reaches port 3240 can take a free device

usbip has no authentication and no encryption. The exporter answers whoever
reaches port 3240: any pod in the cluster through the ClusterIP Service, and,
with `CROSS_CLUSTER=yes`, anything on the LAN through the LoadBalancer IP. The
first one to ask for a free device gets it, and what crosses the wire is
readable, keystrokes from a keyboard receiver included. Measured: a Linux client
listed and attached the test exporter's devices with no credentials at all.

For now, keep the LoadBalancer IP on a network only your clients reach. Under
analysis: letting only known clients in (the Service's source ranges, a
NetworkPolicy), measured before it ships.

## A live migration of the client is not measured yet

It is the whole point, and the lab cannot do it yet: both of its clusters have
a single node, and a live migration needs two. The closest stand-ins, measured:
a client pod killed so it came back with a new IP freed its device in 42
seconds, and the Windows watchdog attached a detached device again within one
15-second check.

## A replugged device needs a person

KubeVirt keeps offering the device it had before the unplug. The watchdog raises
an alert and says to run `scripts/rediscover.sh`; it changes nothing itself
([details](server.md#when-a-device-leaves-the-node-the-watchdog-tells-you)).

The catch is the order. If the exporter restarts before someone runs it, the
exporter does not start (`Allocate failed`), and every device on it stays down
until the device is back and `rediscover.sh` runs, or `apply.sh` drops it. The
alert fires when the device leaves, while the exporter still runs, so there is
time to act before a restart. A watchdog that fixed this by itself had to guess
at KubeVirt's private state, and once took a good identical dongle out of the
exporter, so a person acts instead.

Next to test: passing a whole USB controller to the exporter (IOMMU), so that a
replug happens inside the VM, where KubeVirt has nothing to forget.

## Maintenance on the device's node takes its devices down

The exporter cannot live-migrate: its devices are plugged into that node, and
KubeVirt reports it as `HostDeviceNotLiveMigratable`. So it sets its eviction
strategy to `None` itself, whatever the cluster's default: with `LiveMigrate`,
KubeVirt would refuse to evict it and a drain would wait forever. With `None` a
drain stops it, and every client goes without its device until the node is
back. Measured: those settings. Not measured: a drain, since the lab's clusters
have a single node.

## Some devices do not behave

A device that changes its own id cannot stay passed through: KubeVirt loses it
the moment it switches. The 8BitDo receiver does exactly that when its
controller connects (measured). A composite HID device also tripped a kernel bug
under the Windows client. Both are in
[the known traps](#known-traps-i-fell-into-all-of-them) below.

A device that takes its firmware from the driver does not survive an exporter
restart once a client has used it. Measured once, with an Atheros AR9271 WiFi
adapter: the client's driver loaded the firmware into the adapter over usbip;
when the exporter stopped, QEMU reset the adapter, the node's kernel saw it come
back different (`device firmware changed`) and gave it a new number, and to
KubeVirt that is a replug, which takes `scripts/rediscover.sh`. On RHCOS it got
worse, because the node has a driver for that adapter too (`ath9k_htc`): it
grabbed the adapter, and when the exporter took it back, QEMU sat blocked in the
kernel for eight minutes and the adapter stayed unusable until it was unplugged.
After a replug and `rediscover.sh` it worked again. The Bluetooth adapter,
keyboard receiver and sound card in the lab take no firmware from the host and
came back from every exporter restart.

Audio did not play. A C-Media USB headset attached to a Fedora client on another
cluster: `snd-usb-audio` bound and ALSA listed the card, but `aplay` hit an
underrun on every period, and 4 seconds of playback moved about 200 bytes each
way where the stream needs 192 KB a second (measured once). Sound runs on
isochronous transfers, which this path did not carry. License dongles use
control and interrupt transfers, so this says nothing about them; a webcam or a
headset is not a good fit.

## Known traps (I fell into all of them)

**Port 3240 is a default, not a law.** I believed it was hardcoded for a while,
because `-r` takes a host and no port. The port is a global flag instead:
`usbip --tcp-port 31240 list -r <node-ip>` worked through a NodePort from another
cluster, and so did the Windows scripts with `-Port`, which passes the same flag
to usbip-win2. MetalLB is still the default for cross-cluster clients: it serves
the native 3240 on a stable LAN IP, where a NodePort ties every client to one
node's IP.

**Pick a well-behaved device.** The first device I tried was a game controller,
a composite HID thing that switches its own vendor:product id depending on
whether it is idle or on. Under the Windows client it tripped a use-after-free in
the Linux `usbip_host` kernel module (`KFENCE: use-after-free in stub_rx_loop`)
and the device would drop off the exporter's bus with a `-71` (EPROTO) on the
first real transfer. Passthrough has its own problem with it: its receiver
enumerates as `2dc8:301c` ("IDLE") and, the moment the controller connects,
comes back as `2dc8:310a`, same serial. KubeVirt loses the device it passed
through, and the new id is on nobody's allowlist. A plain single-function device, a CSR8510 Bluetooth dongle,
just worked: clean attach, survives reset and detach, no kernel fireworks. Ask
me how I know. A Linux usbip client never triggered the crash, only the Windows
one did, so if you must use a quirky device, test Linux-to-Linux first to prove
the exporter is fine before you blame the client.

**Multiple selectors under one resourceName mean AND, not OR.** In
`permittedHostDevices.usbHostDevices`, if you list two selectors under a single
`resourceName`, KubeVirt wants BOTH devices present at once. Add a second one
expecting "either" and your resource count silently goes to zero. One device per
resourceName.

**Secure Boot is fine.** The official usbip-win2 driver is Microsoft
attestation-signed, so it loads with Secure Boot on and no test signing. The
test-signing instructions in the upstream README are for people who build the
driver themselves. `install-usbip.ps1` checks this and fails loudly if it ever
gets a test-signed driver.

**Downloading the release inside a locked-down VM.** GitHub release assets
redirect to a separate CDN host. A VM that can reach github.com may still not
reach that host, and the download hangs with no error. Stage the installer
somewhere with real egress and copy it in, then `install-usbip.ps1 -InstallerPath`.

**If the exporter loses the device**, the guest log
(`/var/log/usbip-export.log`) says so. A client-side reset can knock a fragile
device off the passed-through bus; the fix is `virtctl restart usb-ip-exporter`,
which re-grabs it. A well-behaved device does not do this. See the device note above.

**Windows powers idle USB devices down, and usbip cannot wake them.** Seconds
after the last keystroke, a keyboard attached over usbip went to D3 while Device
Manager still said Status OK, and no key ever arrived again: the wakeup signal
has no way back through the usbip protocol. The fix is the per-device "Allow the
computer to turn off this device to save power", not the power plan's USB
selective suspend. The Windows scripts turn it off for the device they manage.
I spent a day calling composite HID devices "flaky" before finding this. Details
in [the Windows client doc](client-windows.md#windows-powers-idle-devices-down-and-usbip-cannot-wake-them).

**A client that dies without detaching leaves the device busy.** usbipd sets no
keepalive, so the exporter kept a dead client's session, and its device, for as
long as I watched, and every new attach got `Device busy (exported)`. The
exporter now puts HAProxy in front of usbipd with TCP keepalive on every client:
a dead session is gone in under a minute (under 30 seconds after a client
reboot, 42 after its pod vanished), and HAProxy must run without client or server timeouts
or it drops idle dongles itself. Details in
[the server doc](server.md#a-client-that-dies-without-detaching-leaves-the-device-busy).

## Migration

A single-node cluster cannot live-migrate, so at home this proves the mechanism
and the decoupling (the client has no host device and reaches the dongle over the
network). The actual live migration belongs on a multi-node cluster. Cross-cluster
live migration (CCLM) is the path for moving the client between clusters while it
keeps the dongle attached over IP.

What I expected to go wrong there: on the pod network (masquerade) the client's
address changes when it migrates, and the exporter would hold the old session.
HAProxy in front of usbipd handles that case: killing a client's pod so it came
back with a new IP freed the device in 42 seconds. A real live migration is still
not measured.
