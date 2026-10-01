#!/usr/bin/env bash
# build-in-cluster.sh - run fedora-usbip.sh as a Job on a cluster node with KVM
# and push the disk to the OpenShift internal registry, built for that node's
# architecture: the way to get a disk for an arm64 cluster, or for one that
# cannot pull the published image. The internal registry must be enabled.
# Idempotent: re-running rebuilds and re-pushes the tag.
#
#   FEDORA        Fedora release. Default 44.
#   NAMESPACE     where the build runs and the image lives. Default usb-ip-kubevirt.
#   USB_IP_IMAGE  where the exporter's files come from: the usb-ip-kubevirt image.
#                 Default: the one apply.sh deploys.
#   OC            oc binary (add --context=... here). Default "oc".
set -euo pipefail
cd "$(dirname "$0")"
FEDORA="${FEDORA:-44}"
NAMESPACE="${NAMESPACE:-usb-ip-kubevirt}"
OC="${OC:-oc}"
USB_IP_IMAGE="${USB_IP_IMAGE:-$(sed -n 's/^USB_IP_IMAGE="\${USB_IP_IMAGE:-\(.*\)}"$/\1/p' ../scripts/apply.sh)}"
[ -n "$USB_IP_IMAGE" ] || { echo "no USB_IP_IMAGE (and none found in scripts/apply.sh)" >&2; exit 1; }
IMAGE="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/fedora-usbip:${FEDORA}"

echo "[1/4] namespace ${NAMESPACE}, build permissions, pull permission for every service account"
$OC get namespace "$NAMESPACE" >/dev/null 2>&1 || $OC create namespace "$NAMESPACE" >/dev/null
$OC create serviceaccount fedora-usbip-builder -n "$NAMESPACE" --dry-run=client -o yaml | $OC apply -f - >/dev/null
$OC adm policy add-scc-to-user anyuid -z fedora-usbip-builder -n "$NAMESPACE" >/dev/null
$OC policy add-role-to-user system:image-builder -z fedora-usbip-builder -n "$NAMESPACE" >/dev/null
$OC policy add-role-to-group system:image-puller system:serviceaccounts -n "$NAMESPACE" >/dev/null

echo "[2/4] start the build job"
$OC create configmap fedora-usbip-build -n "$NAMESPACE" --from-file=fedora-usbip.sh --from-file=guest-setup.sh \
  --dry-run=client -o yaml | $OC apply -f - >/dev/null
$OC delete job fedora-usbip-build -n "$NAMESPACE" --ignore-not-found >/dev/null
sed "s/namespace: usb-ip-kubevirt/namespace: ${NAMESPACE}/; s/value: \"44\"/value: \"${FEDORA}\"/; s#svc:5000/usb-ip-kubevirt/fedora-usbip:44#svc:5000/${NAMESPACE}/fedora-usbip:${FEDORA}#; s#USB_IP_IMAGE#${USB_IP_IMAGE}#" job.yaml | $OC apply -f - >/dev/null

echo "[3/4] following the log (10 to 20 minutes)"
$OC wait --for=condition=Ready pod -l job-name=fedora-usbip-build -n "$NAMESPACE" --timeout=300s >/dev/null
$OC logs -f job/fedora-usbip-build -n "$NAMESPACE"

echo "[4/4] result"
# the log ends when the container exits; the Job status lands a moment later
R=""
for _ in $(seq 1 30); do
  R="$($OC get job fedora-usbip-build -n "$NAMESPACE" -o jsonpath='{.status.succeeded}/{.status.failed}')"
  case "$R" in 1/*|*/1) break ;; esac
  sleep 2
done
[ "${R%%/*}" = "1" ] || { echo "build FAILED, see the log above" >&2; exit 1; }
# Pin the digest: nodes cache a tag they already pulled (containerDisks pull
# IfNotPresent), so a rebuilt :44 would not reach a node that has the old one.
DIGEST="$($OC get istag "fedora-usbip:${FEDORA}" -n "$NAMESPACE" -o jsonpath='{.image.metadata.name}')"
echo "image: ${IMAGE} (${DIGEST})"
echo "use it: DISK_IMAGE=${IMAGE%:*}@${DIGEST} ./scripts/apply.sh"
