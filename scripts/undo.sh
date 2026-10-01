#!/usr/bin/env bash
# undo.sh - tear down what apply.sh created. Run it with the same env vars you
# gave apply.sh. Leaves MetalLB itself alone; with CROSS_CLUSTER=yes it also
# removes the pool/advertisement this project added (they are cluster-wide, so
# they are not touched otherwise). From the HyperConverged allowlist it removes
# only the entries apply.sh created (recorded on the exporter VM), never one
# that was there before.
set -euo pipefail
cd "$(dirname "$0")/.."
NAMESPACE="${NAMESPACE:-default}"
CROSS_CLUSTER="${CROSS_CLUSTER:-no}"
OC="${OC:-oc}"
HCO_NS="openshift-cnv"
HCO_NAME="kubevirt-hyperconverged"
CREATED_KEY="usb-ip-kubevirt/created-resource-names"

# read it before the VM goes away
CREATED="$($OC get vm usb-ip-exporter -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg k "$CREATED_KEY" '.metadata.annotations[$k] // ""' || true)"

echo "== deleting VMs / Services / Secret in ${NAMESPACE} =="
# the watchdog goes first, so it does not react to the exporter going away
$OC delete servicemonitor,prometheusrule usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
$OC delete deploy usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found
$OC delete svc usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found
$OC delete configmap usb-ip-watchdog-py usb-ip-watchdog-status -n "$NAMESPACE" --ignore-not-found
$OC delete sa usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found
$OC delete role usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found
$OC delete rolebinding usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found
$OC delete vm usb-ip-exporter usb-ip-linux-client -n "$NAMESPACE" --ignore-not-found
$OC delete svc usb-ip-exporter usb-ip-exporter-lb usb-ip-exporter-status -n "$NAMESPACE" --ignore-not-found
$OC delete secret usb-ip-exporter-cloudinit usb-ip-ssh-key -n "$NAMESPACE" --ignore-not-found
$OC delete deploy usb-ip-dashboard -n "$NAMESPACE" --ignore-not-found
$OC delete daemonset usb-ip-discovery -n "$NAMESPACE" --ignore-not-found
$OC delete svc usb-ip-dashboard usb-ip-discovery -n "$NAMESPACE" --ignore-not-found
$OC delete route usb-ip-dashboard -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
$OC delete configmap usb-ip-dashboard-html usb-ip-dashboard-vendor usb-ip-dashboard-fonts \
  usb-ip-collector-py usb-ip-discovery-py usb-ip-assignments -n "$NAMESPACE" --ignore-not-found
$OC delete sa usb-ip-dashboard -n "$NAMESPACE" --ignore-not-found
$OC delete role usb-ip-dashboard -n "$NAMESPACE" --ignore-not-found
$OC delete rolebinding usb-ip-dashboard -n "$NAMESPACE" --ignore-not-found
$OC delete clusterrolebinding "usb-ip-dashboard-other-vms-${NAMESPACE}" --ignore-not-found
$OC delete clusterrolebinding "usb-ip-dashboard-login-${NAMESPACE}" --ignore-not-found
$OC delete secret usb-ip-dashboard-cookie usb-ip-dashboard-tls -n "$NAMESPACE" --ignore-not-found
# every install shares the ClusterRole: the last one out takes it along
if LEFT="$($OC get clusterrolebinding -o jsonpath='{range .items[?(@.roleRef.name=="usb-ip-dashboard-other-vms")]}{.metadata.name}{"\n"}{end}')" \
    && [ -z "$LEFT" ]; then
  $OC delete clusterrole usb-ip-dashboard-other-vms --ignore-not-found
fi
if [ "$CROSS_CLUSTER" = "yes" ]; then
  $OC delete ipaddresspool.metallb.io usb-ip-exporter-ip -n metallb-system --ignore-not-found 2>/dev/null || true
  $OC delete l2advertisement.metallb.io usb-ip-exporter-l2 -n metallb-system --ignore-not-found 2>/dev/null || true
fi

if [ -n "$CREATED" ]; then
  echo "== removing ${CREATED} from HyperConverged =="
  # The patch replaces the whole list: a failed read taken for an empty one
  # would drop every entry, not only these.
  CUR="$($OC get hyperconverged $HCO_NAME -n $HCO_NS -o jsonpath='{.spec.permittedHostDevices.usbHostDevices}')" || {
    echo "ERROR: cannot read the HyperConverged ${HCO_NAME} in ${HCO_NS}; its allowlist is left alone. Remove ${CREATED} from it by hand." >&2
    exit 1; }
  [ -z "$CUR" ] && CUR='[]'
  NEW="$(printf '%s' "$CUR" | jq -c --arg c "$CREATED" '($c | split(" ")) as $rm | [.[] | select(.resourceName as $n | $rm | any(. == $n) | not)]')"
  $OC patch hyperconverged $HCO_NAME -n $HCO_NS --type=merge \
    -p "{\"spec\":{\"permittedHostDevices\":{\"usbHostDevices\":$NEW}}}" >/dev/null
else
  echo "== HyperConverged left alone: apply.sh created no allowlist entry for this exporter =="
fi
echo "done."
