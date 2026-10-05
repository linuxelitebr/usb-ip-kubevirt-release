# Linux client

The client side is a kernel module, `vhci_hcd`, and the stock Fedora 44 cloud
image does not carry it: it ships in `kernel-modules-extra`, which step 1
installs. This is also the client to reach for when something misbehaves on
Windows: if a device works here, the device and the exporter are fine.

`<host>` below is the exporter endpoint: `usb-ip-exporter` from the same
namespace, `usb-ip-exporter.<namespace>.svc.cluster.local` from another one in the
same cluster, the LoadBalancer IP from anywhere else. Spell that second name out
in full: Fedora's systemd-resolved applies the search domains to single-label
names only, so `usb-ip-exporter.<namespace>.svc` does not resolve (measured on
Fedora 44). The port defaults to 3240; for anything else (a NodePort, say) add
the global flag: `usbip --tcp-port 31240 list -r <host>`.

## Attach a device

**1. Install the tools.** On Fedora (the `LINUX_CLIENT=yes` VM already has
both; get in with `virtctl ssh -i <key> fedora@vm/usb-ip-linux-client`, the key
you gave `apply.sh` as `SSH_PUBKEY`):

```bash
sudo dnf install -y usbip kernel-modules-extra-$(uname -r)
sudo modprobe vhci-hcd
```

`$(uname -r)` pins the modules to the running kernel. On the stock Fedora 44
cloud image, whose kernel is older than the newest, `usbip` alone pulls in the
newest kernel and its modules, and `modprobe` then fails with
`Module vhci-hcd not found` until you reboot into that kernel (measured). If dnf
has no `kernel-modules-extra` for your kernel, because the mirrors dropped that
update (not measured), install `usbip` alone, reboot into the kernel it brings,
and load the module. `kernel-modules-extra` brings `kernel-modules` along, with
the class drivers the cloud image leaves out: a C-Media headset got
`snd-usb-audio` from it with nothing else installed (measured).

**2. See what the exporter offers.** The last lines of `./scripts/status.sh`
print this command with the right `<host>` for where this VM runs. Only what is
plugged into the exporter's own node shows up: the node with the dongle, or with
the USB hub the dongle hangs from, and only the devices `apply.sh` got in
`DEVICES`. The vendor:product comes from that node's USB tree
([server side](server.md#deploy-it), step 1), never from this VM's. And only
free devices show up: one that another client holds is not listed at all, so an
empty list can just mean "taken".

```bash
usbip list -r <host>
```

```text
Exportable USB devices
======================
 - usb-ip-exporter
        1-1: Cambridge Silicon Radio, Ltd : Bluetooth Dongle (HCI mode) (0a12:0001)
           : /sys/devices/pci0000:00/0000:00:02.4/0000:05:00.0/usb1/1-1
           : Wireless / Radio Frequency / Bluetooth (e0/01/01)
```

**3. Attach it by busid** and check the port:

```bash
sudo usbip attach -r <host> -b 1-1
sudo usbip port
```

```text
Imported USB devices
====================
Port 00: <Port in Use> at Full Speed(12Mbps)
       Cambridge Silicon Radio, Ltd : Bluetooth Dongle (HCI mode) (0a12:0001)
       1-1 -> usbip://usb-ip-exporter:3240/1-1
           -> remote bus/dev 001/002
```

The device is now local as far as the kernel cares: `dmesg` shows its driver
binding (for this dongle, `Bluetooth: hci0: CSR: Setting up dongle`). If `lsusb`
is missing, it comes with `usbutils`.

A driver that needs firmware needs it in the guest, as it would on any machine,
and the Fedora cloud image carries none. For an Atheros AR9271 WiFi adapter that
is `atheros-firmware`; NetworkManager also wants `NetworkManager-wifi`, or it
shows the adapter as unavailable, while `iw dev <interface> scan` works without
it. Mind the catch in [the limitations](limitations.md#some-devices-do-not-behave):
once the guest loaded that firmware into the adapter, the next exporter restart
loses it.

**4. Detach** with the port number from `usbip port`:

```bash
sudo usbip detach -p 00
```

## Keep it attached

`usbip attach` is one-shot. If the connection drops (exporter restart, network
blip), nothing brings it back. A systemd timer does, one per device, and it
finds the device by vendor:product, not by busid. The busid is the exporter's
slot, and slots move: a fifth device in `DEVICES` moved every one of them, and
two clients whose timers held a busid each came back with the other one's
dongle (measured).

**1. Save the attach script** as `/usr/local/bin/usbip-attach-id`. It does
nothing when this VM already has a device with that id, and otherwise looks the
busid up in the exporter's list. It attaches one device at a time: two
`usbip attach` at once can pick the same port, and the loser spins on
`port 0 already used` while it holds the device on the exporter (measured, with
two timers firing in the same second). The `timeout` frees a stuck one for the
next run:

```sh
#!/bin/sh
exec 9>/run/usbip-attach-id.lock
flock 9
usbip port | grep -qF "($2)" && exit 0
busid=$(usbip list -r "$1" | awk -v id="($2)" 'index($0, id) {print $1; exit}' | tr -d :)
[ -n "$busid" ] || { echo "no $2 exported by $1" >&2; exit 1; }
exec timeout 60 usbip attach -r "$1" -b "$busid"
```

```bash
sudo chmod 755 /usr/local/bin/usbip-attach-id
```

**2. Save the service** as `/etc/systemd/system/usbip-attach@.service`, with
your host in place of `usb-ip-exporter`:

```ini
[Unit]
Description=Attach the usbip device %i
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/modprobe vhci-hcd
ExecStart=/usr/local/bin/usbip-attach-id usb-ip-exporter %i
```

**3. Save the timer** as `/etc/systemd/system/usbip-attach@.timer`:

```ini
[Unit]
Description=Re-attach the usbip device %i if it dropped

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s

[Install]
WantedBy=timers.target
```

**4. Turn it on for each device**, by its vendor:product:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now usbip-attach@0a12:0001.timer
```

A second device on the same VM is one more `enable --now` with its id
(measured: a C-Media headset and a CSR Bluetooth dongle on one Fedora VM). Two
clients that want identical dongles each take whichever one is free.

`AccuracySec=1s` is not decoration: by default systemd may fire a timer up to a
minute late, and without it a manual detach came back in 95 seconds. Measured
with it: attached within a second of enabling, back 18 to 36 seconds after a
manual detach in three runs (the timer checks every 60, so a minute at most),
and back 22 to 31 seconds after a restarted exporter was exporting again, after
a `DEVICES` change that moved every slot, each VM with its own devices.

**To give the device back for good**, stop its timer first, or it takes the
device again within a minute:

```bash
sudo systemctl disable --now usbip-attach@0a12:0001.timer
sudo usbip detach -p 00
```

**Close the session on the way down.** A reboot kills the TCP session without
closing it, and the exporter needs up to 30 seconds to notice (see
[the server doc](server.md#a-client-that-dies-without-detaching-leaves-the-device-busy)).
This unit closes the session while the network is still up, so the device is
free at once. Save as
`/etc/systemd/system/usbip-detach.service`:

```ini
[Unit]
Description=Detach usbip devices before the network goes down
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/modprobe vhci-hcd
ExecStop=/usr/sbin/modprobe -r vhci-hcd

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now usbip-detach.service
```

Unloading `vhci_hcd` detaches every port and closes its connection. Measured:
the exporter freed the device within 2 seconds of the reboot, and the client was
attached again 44 seconds after boot (30 of them are the timer's `OnBootSec`).
