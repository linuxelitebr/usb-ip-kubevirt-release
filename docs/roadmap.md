# Roadmap

What comes next, roughly in order. None of it works yet: what works is in the
[README](../README.md), and what works with a catch is in
[the limitations](limitations.md).

## CI and releases

The images are built and published from the maintainer's machine, and a tag
publishes the release and mirrors it to the public repo. Next: the tests that
need no cluster (`tests/`) on every change, not only on a tag, and badges at the
top of the README that link to the images on GHCR and on Quay.

## A whole USB controller for the exporter (IOMMU)

Today KubeVirt hands the exporter one device at a time. The other way to
deploy: hand it a whole USB controller, a PCIe card, through IOMMU and VFIO. A
replug then happens inside the VM, where KubeVirt has nothing to forget, which
takes care of [a replugged device needing a person](limitations.md#a-replugged-device-needs-a-person).
Both ways stay, documented apart.

The catch: on RHCOS the xHCI driver is built into the kernel, so the usual
recipe (blocklist the driver, `vfio-pci.ids`) cannot take one controller and
leave the others to the host. And IOMMU has to be on in the node's kernel
arguments, which means a MachineConfig and a reboot. Waiting on the card going
into the lab server.

## An exporter without a VM

A test, not a plan yet. The exporter is a VM because the usbip server side is a
kernel module, `usbip-host`, that RHCOS does not ship, and loading a module onto
the node is not an option: unsupported, and every upgrade can break it.

But KubeVirt's USB passthrough already is a container talking to a USB device.
The exporter's virt-launcher pod gets `/dev/bus/usb/...` from a device plugin,
and QEMU opens it through libusb, from a container that is not privileged. A
user-space USB/IP server can do the same and relay to TCP instead, like the
"host" mode of the Rust [`usbip`](https://github.com/jiegec/usbip) crate. Same
protocol, so the clients would not change.

What to find out, on a lab namespace: whether a plain pod can request the same
`kubevirt.io/usb-dongle` resource and get the device, and whether the server
holds with a license dongle, a WiFi adapter, a replug and a pod restart. If it
holds, it becomes a third way to deploy, next to the VM. If not, this item goes
away.

## More live migrations of a client

One is measured: a Windows client live-migrated to another cluster had its
device back about 26 seconds after the switchover. Still to measure: a Linux
client, a migration between nodes of one cluster, and what a real license
dongle's software makes of that half minute.

## Who can reach port 3240

usbip has no authentication
([details](limitations.md#anyone-who-reaches-port-3240-can-take-a-free-device)).
Under analysis: `loadBalancerSourceRanges` on the LoadBalancer and a
NetworkPolicy on the exporter. Both have to be measured with OVN-Kubernetes,
where a client from another cluster reaches the exporter from the OVN join
address, not its own.

## Packaging

An install friendlier than environment variables on `apply.sh`, such as a Helm
chart.
