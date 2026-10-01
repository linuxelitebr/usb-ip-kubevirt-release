#!/usr/bin/env bash
# fedora-usbip.sh - build the containerDisk the exporter and the Linux client
# boot: Fedora with usbip, its kernel modules, HAProxy and the exporter (its
# service off; the exporter's cloud-init turns it on). It runs image/guest-setup.sh
# inside the disk through virt-customize, for the architecture of the machine it
# runs on. Needs Linux with KVM, skopeo, virt-customize (guestfs-tools), qemu-img,
# tar and gzip. build-in-cluster.sh runs it on a cluster node for you, with the
# exporter's files taken from the usb-ip-kubevirt image.
#
#   FEDORA        Fedora release of the base containerDisk. Default 44.
#   BASE          base containerDisk. Default quay.io/containerdisks/fedora:$FEDORA.
#   EXPORTER_DIR  the exporter's files. Default /exporter.
#   GUEST_SETUP   the script that runs in the guest. Default: guest-setup.sh next to this one.
#   IMAGE    where to push the result. Default: the OpenShift internal registry,
#            image-registry.openshift-image-registry.svc:5000/usb-ip-kubevirt/fedora-usbip:$FEDORA.
#   WORK     scratch directory. Default /var/tmp/fedora-usbip.
#   PUSH     "no" builds without pushing. Default "yes".
set -euo pipefail

FEDORA="${FEDORA:-44}"
BASE="${BASE:-quay.io/containerdisks/fedora:${FEDORA}}"
IMAGE="${IMAGE:-image-registry.openshift-image-registry.svc:5000/usb-ip-kubevirt/fedora-usbip:${FEDORA}}"
WORK="${WORK:-/var/tmp/fedora-usbip}"
PUSH="${PUSH:-yes}"
SA=/var/run/secrets/kubernetes.io/serviceaccount
EXPORTER_DIR="${EXPORTER_DIR:-/exporter}"
GUEST_SETUP="${GUEST_SETUP:-$(dirname "$0")/guest-setup.sh}"
# the disk is built for this machine's architecture, which on a cluster is the node's
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *)       echo "no containerDisk for $(uname -m)" >&2; exit 1 ;;
esac
for f in haproxy.cfg usbip-serve.pyc usbip-export.sh usbip-export.service; do
  [ -f "$EXPORTER_DIR/$f" ] || { echo "no $EXPORTER_DIR/$f" >&2; exit 1; }
done

echo "[1/5] fetch ${BASE} (${ARCH})"
rm -rf "$WORK" && mkdir -p "$WORK/layers" "$WORK/root"
skopeo copy --override-arch "$ARCH" --override-os linux "docker://${BASE}" "dir:${WORK}/layers" >/dev/null
# A containerDisk is a single file under /disk/ in one of the layers.
for l in "$WORK"/layers/*; do
  tar -tf "$l" 2>/dev/null | grep -q '^disk/.' && tar -xf "$l" -C "$WORK/root" disk
done
SRC="$(find "$WORK/root/disk" -type f | head -1)"
[ -n "$SRC" ] || { echo "no disk found in ${BASE}" >&2; exit 1; }
qemu-img convert -O qcow2 "$SRC" "$WORK/disk.qcow2"
rm -rf "$WORK/layers" "$WORK/root"

echo "[2/5] image/guest-setup.sh inside the disk, then relabel"
export LIBGUESTFS_BACKEND=direct
UPLOADS=()
for f in haproxy.cfg usbip-serve.pyc usbip-export.sh usbip-export.service; do
  UPLOADS+=(--upload "$EXPORTER_DIR/$f:/tmp/usb-ip-exporter/$f")
done
virt-customize -a "$WORK/disk.qcow2" --memsize 2048 \
  --mkdir /tmp/usb-ip-exporter "${UPLOADS[@]}" \
  --run "$GUEST_SETUP" \
  --run-command 'rm -rf /tmp/usb-ip-exporter' \
  --selinux-relabel

echo "[3/5] check: the modules for the kernel that boots, and the exporter, off"
# virt-customize does not echo a command's output, so guest-setup.sh writes the
# result into the image (/etc/usbip-image, handy on a running VM too).
virt-cat -a "$WORK/disk.qcow2" /etc/usbip-image | tee "$WORK/check.txt"
virt-ls -a "$WORK/disk.qcow2" /usr/local/bin | grep -qx usbip-export.sh || { echo "no exporter in the disk" >&2; exit 1; }
if virt-ls -a "$WORK/disk.qcow2" /etc/systemd/system/multi-user.target.wants 2>/dev/null | grep -qxE '(usbip-export|haproxy)\.service'; then
  echo "the exporter or HAProxy is enabled in the disk; the Linux client would run it too" >&2; exit 1
fi

echo "[4/5] sparsify and package as a containerDisk"
virt-sparsify --in-place "$WORK/disk.qcow2"
# A containerDisk is one layer holding /disk/<image>, owned by qemu (107).
# Assembling the OCI layout by hand needs no container runtime and no
# privileges, so this also runs inside an unprivileged pod.
OCI="$WORK/oci"; B="$OCI/blobs/sha256"
mkdir -p "$B" "$WORK/layer/disk"
mv "$WORK/disk.qcow2" "$WORK/layer/disk/disk.qcow2"
tar --owner=107 --group=107 --numeric-owner -C "$WORK/layer" -cf "$WORK/layer.tar" disk
DIFF_ID="$(sha256sum "$WORK/layer.tar" | cut -d' ' -f1)"
gzip -1 "$WORK/layer.tar"
LAYER="$(sha256sum "$WORK/layer.tar.gz" | cut -d' ' -f1)"; LSIZE="$(stat -c %s "$WORK/layer.tar.gz")"
mv "$WORK/layer.tar.gz" "$B/$LAYER"
DESC="Fedora ${FEDORA} with usbip, HAProxy and the usb-ip exporter preinstalled ($(cat "$WORK/check.txt"))"
printf '{"architecture":"%s","os":"linux","config":{"Labels":{"org.opencontainers.image.source":"https://github.com/linuxelitebr/usb-ip-kubevirt-release","org.opencontainers.image.description":"%s"}},"rootfs":{"type":"layers","diff_ids":["sha256:%s"]}}' \
  "$ARCH" "$DESC" "$DIFF_ID" > "$WORK/config.json"
CFG="$(sha256sum "$WORK/config.json" | cut -d' ' -f1)"; CSIZE="$(stat -c %s "$WORK/config.json")"
mv "$WORK/config.json" "$B/$CFG"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%s},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:%s","size":%s}]}' \
  "$CFG" "$CSIZE" "$LAYER" "$LSIZE" > "$WORK/manifest.json"
MAN="$(sha256sum "$WORK/manifest.json" | cut -d' ' -f1)"; MSIZE="$(stat -c %s "$WORK/manifest.json")"
mv "$WORK/manifest.json" "$B/$MAN"
printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%s,"platform":{"architecture":"%s","os":"linux"}}]}' \
  "$MAN" "$MSIZE" "$ARCH" > "$OCI/index.json"
printf '{"imageLayoutVersion":"1.0.0"}' > "$OCI/oci-layout"
echo "    layer $((LSIZE / 1048576)) MiB, image at oci:${OCI}"

if [ "$PUSH" = "yes" ]; then
  echo "[5/5] push ${IMAGE}"
  ARGS=()
  if [ -f "$SA/token" ]; then
    mkdir -p "$WORK/certs" && cp "$SA/service-ca.crt" "$WORK/certs/ca.crt"
    ARGS=(--dest-cert-dir "$WORK/certs" --dest-creds "builder:$(cat "$SA/token")")
  fi
  skopeo copy --format v2s2 --digestfile "$WORK/digest" "${ARGS[@]}" "oci:${OCI}" "docker://${IMAGE}"
  echo "pushed ${IMAGE}@$(cat "$WORK/digest")"
else
  echo "[5/5] skipping push (PUSH=no); copy it anywhere with: skopeo copy oci:${OCI} docker://<registry>/<image>"
fi
