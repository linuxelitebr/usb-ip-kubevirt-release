# Windows client

This is the real target: the VM that runs your licensed app, attaching the dongle
over TCP with [usbip-win2](https://github.com/vadimgrn/usbip-win2). It has no
host device in its manifest, which is what keeps it migratable.

Before you start:

- The exporter lists the device (see [the server doc](server.md)).
- `<host>` is the exporter endpoint, and which name reaches it depends on where
  the VM sits: the LoadBalancer IP from another cluster (measured on Windows),
  `usb-ip-exporter` from the exporter's own namespace, and
  `usb-ip-exporter.<namespace>.svc.cluster.local` from another namespace of the
  same cluster (the short name measured on Windows too, the full name from Linux
  only). The port is 3240 unless you add `-Port` to the attach or watchdog
  scripts (a NodePort, say).
- The four scripts from `windows/` are in `C:\usbip-lab\`, and you run them in an
  elevated PowerShell. That folder is also where the watchdog task looks for its
  script and writes its log. The scripts are unsigned: copied in over `scp`, they
  ran as they were under Windows Server 2025's default, `RemoteSigned`
  (measured). `RemoteSigned` refuses an unsigned script marked as downloaded
  from the internet, as a browser marks it, with `is not digitally signed`;
  `Get-ChildItem C:\usbip-lab | Unblock-File` takes the mark off (both
  measured).

## 1. Install the driver, once

The GitHub release download redirects to a CDN host that a locked-down VM often
cannot reach, and it hangs with no error. So download `USBip-0.9.8.0-x64.exe`
somewhere with real egress, copy it to `C:\usbip-lab\`, and install that copy:

```powershell
.\install-usbip.ps1 -InstallerPath C:\usbip-lab\USBip-0.9.8.0-x64.exe -Sha256 81f426741f7ee2ed991febe24a22daca8400b6ae2f171054e3fb404897e15d39
```

That hash is the one GitHub publishes for the v0.9.8.0 asset. The script checks
it only when you pass `-Sha256`, then checks the installer's Authenticode
signature, installs silently, and fails loudly if the driver turns out
test-signed. The release driver is Microsoft attestation-signed, so it loads with
**Secure Boot on and no test signing**. On a VM with no internet the signature
check can report `UnknownError`: that is the offline revocation lookup, not
tampering, and the script accepts it when the chain builds and the publisher
matches.

## 2. Attach the device

**See what the exporter offers.** The last lines of `./scripts/status.sh` print
the right `<host>` for where this VM runs. Only what is plugged into the
exporter's own node shows up: the node with the dongle, or with the USB hub the
dongle hangs from, and only the devices `apply.sh` got in `DEVICES`. The
vendor:product for `-VidPid` comes from that node's USB tree
([server side](server.md#deploy-it), step 1), never from this VM's. A device
another client holds is not listed.

```powershell
& "C:\Program Files\USBip\usbip.exe" list -r <host>
```

```text
Exportable USB devices
======================
    1-3    : C-Media Electronics, Inc. : Audio Adapter (0d8c:000c)
           : /sys/devices/pci0000:00/0000:00:02.4/0000:05:00.0/usb1/1-3
           : (Defined at Interface level) (00/00/00)

    1-2    : Microsoft Corp. : Wireless keyboard (All-in-One-Media) (045e:0800)
           : /sys/devices/pci0000:00/0000:00:02.4/0000:05:00.0/usb1/1-2
           : (Defined at Interface level) (00/00/00)
```

Yours is the line that ends in your vendor:product. The name comes from usbip's
own id list and can differ from the node's: `045e:0800` here is the receiver the
node calls `Microsoft Nano Transceiver v2.0`.

**Then attach it:**

```powershell
.\usbip-attach.ps1 -Server <host> -VidPid 0a12:0001
```

Pick the device with one of these:

| Flag | Use it when |
| --- | --- |
| `-VidPid 0a12:0001` | it is the only device of its kind on the exporter; the script finds the busid |
| `-BusId 1-2` | two identical devices that are not interchangeable; this is the exporter's slot, not a physical port, and it moves when `DEVICES` changes |

`-Serial` does not pick a device. usbip-win2 reports that string to Windows as
the device's serial number.

usbip is exclusive: one client holds a device at a time, so assigning devices is
pointing each client at its own and never two at the same one. To see what the
exporter has and how it names it (busid, vendor:product, serial, name, and
whether a client holds it), read its status endpoint, from your machine logged in
to the exporter's cluster:

```bash
oc port-forward -n default svc/usb-ip-exporter-status 3241:3241 &
sleep 3
curl -sS localhost:3241/state.json
kill $!
```

Check it:

```powershell
& "C:\Program Files\USBip\usbip.exe" port
```

```text
Imported USB devices
====================
Port 01: device in use at Full Speed(12Mbps)
         Cambridge Silicon Radio, Ltd : Bluetooth Dongle (HCI mode) (0a12:0001)
           -> usbip://usb-ip-exporter:3240/1-1
           -> remote bus/dev: 001/002
           -> serial:
           -> mode: zero-copy
```

Device Manager shows it like any local device (this dongle: "Generic Bluetooth
Radio", Status OK). Over SSH, with no Device Manager, every row should read OK:

```powershell
Get-PnpDevice -PresentOnly | ? InstanceId -match 'VID_0A12&PID_0001' | Select-Object Status,FriendlyName
```

## 3. Keep it attached and awake (watchdog)

`usbip attach` is one-shot. The watchdog runs as a SYSTEM Scheduled Task from
startup and checks every 15 seconds. It re-attaches the device when it is gone,
and keeps Windows from powering it down (next section). Give it the server and
the device you attached; here `-Server` and `-VidPid` are both required, and
`-BusId` only picks between identical devices. Leave it out when they are
interchangeable: slots move when `DEVICES` changes (measured: a fifth device
moved every one), and a pinned slot then names another device:

```powershell
.\register-watchdog.ps1 -Server <host> -VidPid 0a12:0001
```

Run it again to change the server or the device: it stops the running watchdog
first, since the task ignores a second start (measured: a new process, a new
`watchdog start` line, the device still attached).

It logs to `C:\usbip-lab\watchdog.log` (this run went through a NodePort, with
`-Port 31732`):

```text
2026-09-25T13:37:45.7546674Z watchdog start server=<host> port=31732 vidpid=0a12:0001 busid= serial= pnp=VID_0A12&PID_0001
2026-09-25T13:37:48.4413604Z device absent -> attach busid=1-1
2026-09-25T13:37:48.4970424Z   succesfully attached to port 1
```

Measured: back within one 15-second check after a detach, 30 seconds after a
reboot of this VM, within 10 seconds of a freshly installed exporter exporting,
on two clients on another cluster, and 11 to 16 seconds after a restarted
exporter was exporting again, after a `DEVICES` change that moved every slot,
each client with its own device. Windows closes the session on the way down,
so the exporter frees the device right away. Live-migrated to another cluster,
the VM kept running and the watchdog attached the device again about 26 seconds
after the switchover (measured once).

**It also cancels usbip-win2's own retries.** After a dropped connection,
usbip-win2 attaches the same busid again by itself, 30 seconds later, whatever
sits there now, and `--once` does not stop that. After a `DEVICES` change that
is another device (measured: one client took a second Bluetooth dongle, another
the headset a Linux VM was using). So the watchdog runs
`usbip.exe attach --stop-all` as soon as it finds its device gone, and attaches
by vendor:product. A client attached by hand, with no watchdog, keeps that
exposure.

### Give it back

Remove the watchdog first, or it takes the device again within one check. Then
detach with the port number `usbip.exe port` shows, which starts at 1 here:

```powershell
Stop-ScheduledTask -TaskName usbip-watchdog
Unregister-ScheduledTask -TaskName usbip-watchdog -Confirm:$false
& "C:\Program Files\USBip\usbip.exe" detach -p 1
```

Measured: the exporter showed the device free 3 to 5 seconds later, and it
stayed free.

## Windows powers idle devices down, and usbip cannot wake them

This is the "attached, Status OK, does nothing" failure. Measured on a keyboard
receiver with Windows defaults: within seconds of the last keystroke (6 and 13
in two runs), every part of the device went to D3 (off) while Device Manager
still said Status OK. A suspended device wakes the host with a remote wakeup, and
the usbip protocol has no message for that (it only carries submits and
unlinks), so the next key never arrived. A "Scan for hardware changes" brought it
back until the next idle.

The switch that matters is per device: "Allow the computer to turn off this
device to save power". `usbip-attach.ps1` and the watchdog turn it off for the
device they manage, and the watchdog restarts the device if it finds it
suspended anyway. By hand, with your vendor and product:

```powershell
Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable | ? InstanceName -match 'VID_045E&PID_0800' | Set-CimInstance -Property @{ Enable = $false }
```

With it off, the keyboard stayed awake through idle and typed after the pause,
touchpad included. The power plan's USB selective suspend stayed on during that
test, so that is not the setting that matters. Not measured yet with a real
license dongle; the scripts turn the switch off for whatever device they manage
anyway.

## When it misbehaves

- **Attached, Status OK, does nothing.** Windows powered it down, see the
  section above. The watchdog logs `power-off allowed ... disabled` or
  `device suspended -> restart` when it steps in.
- **`Device busy (exported)` on attach, or `no <vid:pid> exported by <host>`
  with `-VidPid`.** The exporter does not list a device someone holds, so the
  `-VidPid` lookup comes back empty. Either another client holds it, and only
  that client lets it go ([how](#give-it-back)), or a previous session of this
  VM died without detaching, which the exporter clears by itself in under a
  minute. See
  [the server doc](server.md#a-client-that-dies-without-detaching-leaves-the-device-busy).
- **`no <vid:pid> exported by <host>` from the attach, or
  `device absent and <vid:pid> not exported by <host>` in the watchdog's log,
  and nobody holds the device.** Both scripts keep usbip's own error to
  themselves, so a name that does not resolve and a port that does not answer
  end the same way. The lookup they run shows usbip's answer:
  `& "C:\Program Files\USBip\usbip.exe" list -r <host>`.
- **Nothing after a reboot.** Check that the `usbip-watchdog` Scheduled Task
  exists and is running, then read the log. The installer adds a task of its
  own, `USBip Detach All On Reboot Or Shutdown`, which runs
  `usbip.exe detach --all=closeonly`: leave it alone.
