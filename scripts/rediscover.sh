#!/usr/bin/env bash
# rediscover.sh - get a USB device back into the exporter after KubeVirt lost it.
#
# Unplug and replug a passed-through device and KubeVirt keeps offering the dead
# one (docs/server.md). This is the fix the watchdog names when it reports a
# device missing, lost or back; a person runs it, since it edits the cluster's
# KubeVirt configuration. It takes the device's entry off the HyperConverged
# allowlist and puts it back, which makes KubeVirt discover it anew, puts that
# device back in the exporter's hostDevices if it is not there, and restarts the
# exporter.
#
#   VIDPID     the device, vendor:product in lowercase hex. Required.
#   NAMESPACE  the exporter's namespace. Default "default".
#   FORCE      "yes" goes ahead even if another VM uses the same allowlist entry:
#              while the entry is off, KubeVirt hands that device to nobody.
#   OC         oc/kubectl binary (add --context=... here if you need it). Default "oc".
set -euo pipefail
cd "$(dirname "$0")/.."

VIDPID="${VIDPID:?set VIDPID to the vendor:product of the device, e.g. VIDPID=0a12:0001}"
NAMESPACE="${NAMESPACE:-default}"
FORCE="${FORCE:-no}"
OC="${OC:-oc}"
HCO_NS="openshift-cnv"
HCO_NAME="kubevirt-hyperconverged"
DEVICES_KEY="usb-ip-kubevirt/devices"

WANTED="$($OC get vm usb-ip-exporter -n "$NAMESPACE" -o json | jq -c --arg k "$DEVICES_KEY" '.metadata.annotations[$k] // "[]" | fromjson')"
RN="$(printf '%s' "$WANTED" | jq -r --arg v "$VIDPID" '[.[] | select(.vidpid == $v) | .deviceName] | unique | join(" ")')"
if [ -z "$RN" ] || [ "${RN#* }" != "$RN" ]; then
  echo "ERROR: ${VIDPID} is not exactly one of the exporter's devices (annotation ${DEVICES_KEY}); run apply.sh first" >&2
  exit 1
fi
NEED="$(printf '%s' "$WANTED" | jq --arg v "$VIDPID" '[.[] | select(.vidpid == $v)] | length')"

OTHERS="$($OC get vmi -A -o json | jq -r --arg rn "$RN" --arg me "${NAMESPACE}/usb-ip-exporter" '
  .items[] | select(any(.spec.domain.devices.hostDevices[]?; .deviceName == $rn))
  | "\(.metadata.namespace)/\(.metadata.name)" | select(. != $me)')"
if [ -n "$OTHERS" ] && [ "$FORCE" != "yes" ]; then
  echo "ERROR: other VMs use ${RN}: ${OTHERS}. While the entry is off they lose it too; FORCE=yes to go ahead." >&2
  exit 1
fi

CUR="$($OC get hyperconverged $HCO_NAME -n $HCO_NS -o jsonpath='{.spec.permittedHostDevices.usbHostDevices}')"
if ! printf '%s' "$CUR" | jq -e --arg rn "$RN" 'any(.[]; .resourceName == $rn)' >/dev/null; then
  echo "ERROR: ${RN} is not on the HyperConverged allowlist" >&2
  exit 1
fi
patch_hco() {
  $OC patch hyperconverged $HCO_NAME -n $HCO_NS --type=merge \
    -p "{\"spec\":{\"permittedHostDevices\":{\"usbHostDevices\":$1}}}" >/dev/null
}

echo "[1/4] taking ${RN} off the allowlist"
patch_hco "$(printf '%s' "$CUR" | jq -c --arg rn "$RN" '[.[] | select(.resourceName != $rn)]')"
sleep 10
echo "[2/4] putting it back, so KubeVirt discovers ${VIDPID} anew"
patch_hco "$(printf '%s' "$CUR" | jq -c .)"
sleep 5
for _ in $(seq 1 30); do
  N="$($OC get nodes -o json | jq -r --arg rn "$RN" '[.items[].status.allocatable[$rn] // "0" | tonumber] | max')"
  [ "$N" -ge "$NEED" ] && break
  sleep 2
done
echo "     the node advertises ${N} (the exporter wants ${NEED})"

echo "[3/4] giving ${VIDPID} back to the exporter"
# only this device comes back: another one taken out by hand may still be
# missing, and putting it back would leave the exporter waiting for it
HAVE="$($OC get vm usb-ip-exporter -n "$NAMESPACE" -o json | jq -c '[.spec.template.spec.domain.devices.hostDevices[]?.name]')"
HOSTDEVS="$(printf '%s' "$WANTED" | jq -c --arg v "$VIDPID" --argjson have "$HAVE" '
  [.[] | select(.vidpid == $v or (.name as $n | $have | index($n) != null)) | {name, deviceName}]')"
$OC patch vm usb-ip-exporter -n "$NAMESPACE" --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"domain\":{\"devices\":{\"hostDevices\":${HOSTDEVS}}}}}}}" >/dev/null

echo "[4/4] restarting the exporter"
if ! echo '{}' | $OC replace --raw "/apis/subresources.kubevirt.io/v1/namespaces/${NAMESPACE}/virtualmachines/usb-ip-exporter/restart" -f - >/dev/null 2>&1; then
  echo "     no running exporter to restart; KubeVirt starts it with the new device list on its next try"
fi
echo "done. check with scripts/status.sh"
