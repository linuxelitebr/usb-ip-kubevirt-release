#!/usr/bin/env bash
# status.sh - show the state of the usbip exporter side.
set -euo pipefail
NAMESPACE="${NAMESPACE:-default}"
OC="${OC:-oc}"

echo "== devices the exporter claims, as the node advertises them =="
NAMES="$($OC get vm usb-ip-exporter -n "$NAMESPACE" -o json 2>/dev/null \
  | jq -r '[.spec.template.spec.domain.devices.hostDevices[]?.deviceName] | unique | .[]' || true)"
[ -z "$NAMES" ] && echo "(no exporter VM in ${NAMESPACE})"
for n in $NAMES; do
  $OC get nodes -o json | jq -r --arg n "$n" '.items[] | "\(.metadata.name)  \($n)=\(.status.allocatable[$n] // "0")"'
done
echo
echo "== exporter VMI =="
$OC get vmi usb-ip-exporter -n "$NAMESPACE" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeName' 2>/dev/null || echo "(none)"
echo
echo "== watchdog: each device against the node's real USB tree =="
WD="$($OC get configmap usb-ip-watchdog-status -n "$NAMESPACE" -o jsonpath='{.data.status\.json}' 2>/dev/null || true)"
if [ -z "$WD" ]; then
  echo "(no status: WATCHDOG=no, or it has not finished its first check)"
else
  printf '%s' "$WD" | jq -r '.devices[] | "\(.name)  \(.vidpid)  \(.state)\(if (.fix // "") != "" then "  fix: " + .fix else "" end)"'
  printf '%s' "$WD" | jq -r '.note // "" | select(. != "") | "note: " + .'
fi
echo
echo "== services =="
$OC get svc -n "$NAMESPACE" -l app.kubernetes.io/part-of=usb-ip-kubevirt 2>/dev/null || true
echo
echo "== hint: what a client attaches to =="
# The short name resolves only inside this namespace, and Fedora resolves the
# .svc form only spelled out in full.
LB="$($OC get svc usb-ip-exporter-lb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
# the Service exists but MetalLB gave it no IP: running apply.sh again will not help
[ -z "$LB" ] && $OC get svc usb-ip-exporter-lb -n "$NAMESPACE" >/dev/null 2>&1 \
  && LB="<pending: MetalLB assigned no IP, see docs/quickstart.md, When it does not work>"
echo "same namespace:     usbip list -r usb-ip-exporter"
echo "another namespace:  usbip list -r usb-ip-exporter.${NAMESPACE}.svc.cluster.local"
echo "another cluster:    usbip list -r ${LB:-<LoadBalancer IP: apply.sh with CROSS_CLUSTER=yes>}"
