#!/bin/bash
# guest-setup.sh - what building usb-ip-fedora does inside the guest, the same
# for both builds: image/build-disk.sh runs it on a booted VM, and
# image/fedora-usbip.sh through virt-customize. The exporter's files are in the
# directory given as $1, default /tmp/usb-ip-exporter.
#
# It upgrades Fedora, installs usbip, the kernel modules and HAProxy, installs
# the exporter with its service off (the Linux client boots the same disk, and
# the exporter's cloud-init is what turns it on), checks that the modules exist
# for the kernel the disk will boot and that the exporter's bytecode was
# compiled for this disk's python3, and writes /etc/usbip-image.
set -euo pipefail
SRC="${1:-/tmp/usb-ip-exporter}"

dnf -y upgrade --refresh
dnf -y install usbip kernel-modules-extra haproxy

install -m 0644 "$SRC/haproxy.cfg" /etc/haproxy/haproxy.cfg
install -m 0644 "$SRC/usbip-serve.pyc" /usr/local/bin/usbip-serve.pyc
install -m 0755 "$SRC/usbip-export.sh" /usr/local/bin/usbip-export.sh
install -m 0644 "$SRC/usbip-export.service" /etc/systemd/system/usbip-export.service
# a booted build labels them here; virt-customize relabels the whole disk after
restorecon -F /etc/haproxy/haproxy.cfg /usr/local/bin/usbip-serve.pyc /usr/local/bin/usbip-export.sh \
  /etc/systemd/system/usbip-export.service 2>/dev/null || true

k="$(ls /lib/modules | sort -V | tail -1)"
for m in usbip-core usbip-host vhci-hcd; do
  find "/lib/modules/$k" -name "${m//-/[-_]}.ko*" | grep -q . || { echo "no $m for kernel $k" >&2; exit 1; }
done
for b in usbip usbipd haproxy python3; do command -v "$b" >/dev/null || { echo "no $b" >&2; exit 1; }; done
# Bytecode runs only on the Python version that compiled it (the Containerfile's
# Fedora stage). A disk on another Fedora release would start an exporter that
# dies at once, so refuse it here.
python3 -c 'import importlib.util, sys; sys.exit(open(sys.argv[1], "rb").read(4) != importlib.util.MAGIC_NUMBER)' \
  /usr/local/bin/usbip-serve.pyc || { echo "usbip-serve.pyc was compiled for another Python than this disk's $(python3 -V)" >&2; exit 1; }
echo "kernel $k: usbip-core usbip-host vhci-hcd present; $(echo $(rpm -q usbip haproxy))" > /etc/usbip-image
dnf clean all
