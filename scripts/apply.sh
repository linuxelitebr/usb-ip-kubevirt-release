#!/usr/bin/env bash
# apply.sh - stand up the usbip exporter side on OpenShift Virtualization.
# Idempotent: safe to re-run. Reads settings from env vars (see defaults below).
#
#   DEVICES            USB devices to export, as vendor:product in lowercase hex,
#                      space separated. List one twice to pass two identical
#                      devices. Default "$VENDOR:$PRODUCT".
#   VENDOR / PRODUCT   the single-device shorthand. Default 0a12:0001.
#   RESOURCE_NAME      name for a device that is not on the allowlist yet, when
#                      DEVICES holds one kind of device, listed once or more.
#                      Default kubevirt.io/usb-dongle. With several kinds, new
#                      ones get kubevirt.io/usb-<vendor>-<product>.
#                      A device already on the allowlist keeps the name it has.
#   NAMESPACE          Namespace for the VMs/Services. Default "default".
#   CROSS_CLUSTER      "yes" also applies the MetalLB LoadBalancer. Default "no".
#   LB_IP              the LoadBalancer IP, a free IP on your LAN. Required with
#                      CROSS_CLUSTER=yes.
#   LINUX_CLIENT       "yes" also applies the optional Fedora client VM. Default "no".
#   DASHBOARD          "yes" deploys the device map. Default "yes".
#   ROUTE              "yes" gives the dashboard an OpenShift Route, behind the OpenShift
#                      login. "no" leaves it out; oc port-forward reaches it. Default "yes".
#   OAUTH_PROXY_IMAGE  the dashboard's login proxy. Default: the one of the cluster's own
#                      release (ImageStream openshift/oauth-proxy:v4.4), pinned by digest.
#   USB_IP_IMAGE       what the dashboard, discovery and watchdog pods run. Default:
#                      usb-ip-kubevirt 0.2.2, pinned by digest; the same bytes are on
#                      ghcr.io/linuxelitebr/usb-ip-kubevirt.
#   OTHER_VMS          "yes" lets the map name the VM holding a USB device passed through
#                      on the exporter's node, in any namespace. A cluster-wide read of
#                      VMIs: whoever may open the page sees their names. Default "yes".
#   WATCHDOG           "yes" deploys the watchdog: it reports a device that left the node or
#                      that KubeVirt lost, with the command that fixes it. It only reports:
#                      a person runs the fix. Default "yes".
#   ALERTS             "yes" adds alerts on the watchdog's state for the OpenShift console.
#                      They need user workload monitoring (docs/requirements.md). Default "yes".
#   DISK_IMAGE         containerDisk both VMs boot. Default: usb-ip-fedora, Fedora with usbip,
#                      HAProxy and the exporter preinstalled, pinned by digest; the same bytes
#                      are on ghcr.io/linuxelitebr/usb-ip-fedora. A disk without the exporter
#                      boots and exports nothing (docs/server.md).
#   SSH_PUBKEY         an SSH public key file. The VMs have no password, so this key
#                      (user "fedora") is the only way in. Default: none, nobody logs in.
#   OC                 oc/kubectl binary (add --context=... here if you need it). Default "oc".
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="${VENDOR:-0a12}"
PRODUCT="${PRODUCT:-0001}"
DEVICES="${DEVICES:-${VENDOR}:${PRODUCT}}"
RESOURCE_NAME="${RESOURCE_NAME:-kubevirt.io/usb-dongle}"
NAMESPACE="${NAMESPACE:-default}"
CROSS_CLUSTER="${CROSS_CLUSTER:-no}"
LB_IP="${LB_IP:-}"
LINUX_CLIENT="${LINUX_CLIENT:-no}"
DASHBOARD="${DASHBOARD:-yes}"
ROUTE="${ROUTE:-yes}"
OAUTH_PROXY_IMAGE="${OAUTH_PROXY_IMAGE:-}"
USB_IP_IMAGE="${USB_IP_IMAGE:-quay.io/elastocera/usb-ip-kubevirt@sha256:7e616b1183486ae90c2525f5fabe7bfa4507e429c79c2b0772698fb953c18a90}"
OTHER_VMS="${OTHER_VMS:-yes}"
WATCHDOG="${WATCHDOG:-yes}"
ALERTS="${ALERTS:-yes}"
DISK_IMAGE="${DISK_IMAGE:-quay.io/elastocera/usb-ip-fedora@sha256:8b4463e1b670e71b219cabdce022be467fbb77f6201905042c7dde0fcbd17aba}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
OC="${OC:-oc}"
HCO_NS="openshift-cnv"
HCO_NAME="kubevirt-hyperconverged"
CREATED_KEY="usb-ip-kubevirt/created-resource-names"
DEVICES_KEY="usb-ip-kubevirt/devices"

DEVS_JSON="$(printf '%s\n' $DEVICES | jq -R . | jq -sc .)"
if ! printf '%s' "$DEVS_JSON" | jq -e 'length > 0 and all(.[]; test("^[0-9a-f]{4}:[0-9a-f]{4}$"))' >/dev/null; then
  echo "ERROR: DEVICES must be vendor:product pairs in lowercase hex, got: ${DEVICES}" >&2
  exit 1
fi
if [ "$CROSS_CLUSTER" = "yes" ] && [ -z "$LB_IP" ]; then
  echo "ERROR: CROSS_CLUSTER=yes needs LB_IP, a free IP on your LAN for the LoadBalancer." >&2
  exit 1
fi
if { [ "$DASHBOARD" = "yes" ] || [ "$WATCHDOG" = "yes" ]; } && [ -z "$USB_IP_IMAGE" ]; then
  echo "ERROR: USB_IP_IMAGE is not set: the dashboard, discovery and watchdog pods run it" >&2
  exit 1
fi
# The key lands in a Secret. Make sure it is the public half.
if [ -n "$SSH_PUBKEY" ] && ! grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)' "$SSH_PUBKEY" 2>/dev/null; then
  echo "ERROR: SSH_PUBKEY=${SSH_PUBKEY} is not a readable SSH public key (the .pub file, not the private one)." >&2
  exit 1
fi

echo "[1/6] permittedHostDevices: ${DEVICES}"
# The patch below replaces the whole list, so a read that failed must stop here:
# taken for an empty list, it would drop every entry already there.
CUR="$($OC get hyperconverged $HCO_NAME -n $HCO_NS -o jsonpath='{.spec.permittedHostDevices.usbHostDevices}')" || {
  echo "ERROR: cannot read the HyperConverged ${HCO_NAME} in ${HCO_NS}; its allowlist is left alone" >&2; exit 1; }
[ -z "$CUR" ] && CUR='[]'
# One resourceName per vendor:product. Two names selecting the same device fight
# over it and the node advertises 0 for both, so a device already on the
# allowlist keeps its name instead of getting a second one.
if ! PLAN="$(jq -cn --argjson cur "$CUR" --argjson devs "$DEVS_JSON" --arg rn "$RESOURCE_NAME" '
  ($devs | unique) as $u
  | reduce $u[] as $d ({hco: $cur, names: {}, created: []};
      ($d | split(":")) as [$v, $p]
      | ([.hco[] | select(any(.selectors[]?; .vendor == $v and .product == $p)) | .resourceName] | first) as $have
      | if $have != null then .names[$d] = $have
        else (if ($u | length) == 1 then $rn else "kubevirt.io/usb-\($v)-\($p)" end) as $n
          | if any(.hco[]; .resourceName == $n)
            then error("\($n) already selects another device; set RESOURCE_NAME to a free name")
            else .hco += [{resourceName: $n, selectors: [{vendor: $v, product: $p}]}]
                 | .names[$d] = $n | .created += [$n]
            end
        end)' 2>&1)"; then
  echo "ERROR: ${PLAN#jq: error (at <unknown>): }" >&2
  exit 1
fi
printf '%s' "$PLAN" | jq -r '.names | to_entries[] | "     \(.key) -> \(.value)"'
$OC patch hyperconverged $HCO_NAME -n $HCO_NS --type=merge \
  -p "{\"spec\":{\"permittedHostDevices\":{\"usbHostDevices\":$(printf '%s' "$PLAN" | jq -c .hco)}}}" >/dev/null
echo "     waiting for the node to advertise them ..."
NEED="$(jq -cn --argjson devs "$DEVS_JSON" --argjson plan "$PLAN" '[$devs[] | $plan.names[.]] | group_by(.) | map({name: .[0], n: length})')"
for i in $(seq 1 30); do
  ALLOC="$($OC get nodes -o json | jq -c '[.items[].status.allocatable]')"
  SHORT="$(jq -rn --argjson need "$NEED" --argjson alloc "$ALLOC" \
    '[$need[] as $x | select(([$alloc[] | (.[$x.name] // "0" | tonumber)] | max) < $x.n) | $x.name] | join(" ")')"
  [ -z "$SHORT" ] && { echo "     all advertised"; break; }
  [ "$i" = 30 ] && echo "     still not advertised: ${SHORT} (is the device plugged into a node?)"
  sleep 4
done

echo "[2/6] namespace ${NAMESPACE} + cloud-init Secret (exporter)"
$OC get namespace "$NAMESPACE" >/dev/null 2>&1 || $OC create namespace "$NAMESPACE" >/dev/null
$OC create secret generic usb-ip-exporter-cloudinit -n "$NAMESPACE" \
  --from-file=userdata=deploy/10-exporter-cloudinit.yaml --dry-run=client -o yaml | $OC apply -f -
# No password on the VMs. With a key, KubeVirt puts it into cloud-init for the
# default user (accessCredentials, noCloud); without one, nobody logs in.
if [ -n "$SSH_PUBKEY" ]; then
  $OC create secret generic usb-ip-ssh-key -n "$NAMESPACE" --from-file=key="$SSH_PUBKEY" \
    --dry-run=client -o yaml | $OC apply -f -
  ACCESS='[{"sshPublicKey":{"source":{"secret":{"secretName":"usb-ip-ssh-key"}},"propagationMethod":{"noCloud":{}}}}]'
else
  $OC delete secret usb-ip-ssh-key -n "$NAMESPACE" --ignore-not-found >/dev/null
  ACCESS='null'
  echo "     no SSH_PUBKEY: the VMs will have no way to log in"
fi

echo "[3/6] exporter VM"
# Remember which allowlist entries this script created, across runs, so
# undo.sh removes those and never one that was there before.
WAS="$($OC get vm usb-ip-exporter -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg k "$CREATED_KEY" '.metadata.annotations[$k] // ""' || true)"
CREATED="$(jq -rn --arg was "$WAS" --argjson plan "$PLAN" '(($was | split(" ")) + $plan.created) | map(select(. != "")) | unique | join(" ")')"
HOSTDEVS="$(jq -cn --argjson devs "$DEVS_JSON" --argjson plan "$PLAN" '[$devs | to_entries[] | {deviceName: $plan.names[.value], name: "usb\(.key)"}]')"
# The full list goes into an annotation too: the watchdog checks the node against
# it, and rediscover.sh puts a device back into hostDevices from here.
WANTED="$(jq -cn --argjson devs "$DEVS_JSON" --argjson plan "$PLAN" '[$devs | to_entries[] | {name: "usb\(.key)", deviceName: $plan.names[.value], vidpid: .value}]')"
sed "s/namespace: default/namespace: ${NAMESPACE}/" deploy/20-exporter-vm.yaml \
  | $OC create --dry-run=client -o json -f - \
  | jq --argjson hd "$HOSTDEVS" --arg img "$DISK_IMAGE" --arg k "$CREATED_KEY" --arg c "$CREATED" --argjson ac "$ACCESS" \
       --arg dk "$DEVICES_KEY" --arg want "$WANTED" '
      .spec.template.spec.domain.devices.hostDevices = $hd
      | (.spec.template.spec.volumes[] | select(.name == "containerdisk") | .containerDisk.image) = $img
      | .metadata.annotations[$k] = $c
      | .metadata.annotations[$dk] = $want
      | if $ac == null then . else .spec.template.spec.accessCredentials = $ac end' \
  | $OC apply -f -
# A re-run can say "configured" with nothing changed: on OpenShift
# Virtualization kubemacpool writes a MAC into the interface, and apply sends
# the list back without it. The server keeps the MAC. RestartRequired is the
# real signal that the running exporter is behind its spec.
for i in 1 2 3 4 5; do
  if [ "$($OC get vm usb-ip-exporter -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="RestartRequired")].status}' 2>/dev/null)" = "True" ]; then
    echo "     the running exporter still has the old spec; restart it to apply: virtctl restart usb-ip-exporter -n ${NAMESPACE}"
    break
  fi
  sleep 2
done

echo "[4/6] ClusterIP Service (same-cluster clients) + status endpoint"
sed "s/namespace: default/namespace: ${NAMESPACE}/" deploy/30-exporter-service-clusterip.yaml | $OC apply -f -
sed "s/namespace: default/namespace: ${NAMESPACE}/" deploy/35-exporter-status-service.yaml | $OC apply -f -

if [ "$CROSS_CLUSTER" = "yes" ]; then
  echo "[5/6] MetalLB LoadBalancer on ${LB_IP} (cross-cluster clients)"
  sed "s/namespace: default/namespace: ${NAMESPACE}/; s#192.0.2.50/32#${LB_IP}/32#" deploy/40-exporter-metallb.yaml | $OC apply -f -
else
  echo "[5/6] skipping MetalLB (CROSS_CLUSTER=no)"
fi

if [ "$LINUX_CLIENT" = "yes" ]; then
  echo "[6/6] optional Fedora client VM"
  sed "s/namespace: default/namespace: ${NAMESPACE}/" deploy/50-linux-client-vm.yaml \
    | $OC create --dry-run=client -o json -f - \
    | jq --arg img "$DISK_IMAGE" --argjson ac "$ACCESS" '
        (.spec.template.spec.volumes[] | select(.name == "containerdisk") | .containerDisk.image) = $img
        | if $ac == null then . else .spec.template.spec.accessCredentials = $ac end' \
    | $OC apply -f -
else
  echo "[6/6] skipping Fedora client (LINUX_CLIENT=no)"
fi

# Stamping the manifest's checksum on the pod template makes apply roll the pods
# when the manifest changes, and only then; a new USB_IP_IMAGE rolls them anyway,
# since it changes the template itself.
with_hash() {
  sed "s/namespace: default/namespace: ${NAMESPACE}/; s#OAUTH_PROXY_IMAGE#${OAUTH_PROXY_IMAGE}#; s#USB_IP_IMAGE#${USB_IP_IMAGE}#" "$1" \
    | $OC create --dry-run=client -o json -f - \
    | jq --arg h "$(cksum < "$1" | cut -d' ' -f1)" '
        def stamp: if .kind == "Deployment" or .kind == "DaemonSet"
          then .spec.template.metadata.annotations["usb-ip-kubevirt/manifest-cksum"] = $h else . end;
        if .kind == "List" then .items |= map(stamp) else stamp end' \
    | $OC apply -f -
}

if [ "$DASHBOARD" = "yes" ] || [ "$WATCHDOG" = "yes" ]; then
  echo "[+] USB discovery (one unprivileged pod per node reading its USB tree)"
  with_hash deploy/65-usb-discovery.yaml
  # the code used to ship in a ConfigMap; the image carries it now
  $OC delete configmap usb-ip-discovery-py -n "$NAMESPACE" --ignore-not-found >/dev/null
fi

if [ "$WATCHDOG" = "yes" ]; then
  echo "[+] watchdog"
  with_hash deploy/80-watchdog.yaml
  $OC delete configmap usb-ip-watchdog-py -n "$NAMESPACE" --ignore-not-found >/dev/null
  if [ "$ALERTS" != "yes" ]; then
    $OC delete servicemonitor,prometheusrule usb-ip-watchdog -n "$NAMESPACE" --ignore-not-found
  elif ! $OC get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
    echo "    no Prometheus Operator on this cluster: no alerts"
  else
    sed "s/namespace: default/namespace: ${NAMESPACE}/" deploy/85-watchdog-alerts.yaml | $OC apply -f -
    UWM="$($OC get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
    [[ "$UWM" =~ enableUserWorkload:\ *true ]] \
      || echo "    user workload monitoring is off: nothing reads these alerts until it is on (docs/requirements.md)"
  fi
fi

if [ "$DASHBOARD" = "yes" ]; then
  echo "[+] dashboard (device map)"
  # The login proxy ships with the cluster's own release, pinned by digest, so an
  # air-gapped mirror carries it along.
  if [ -z "$OAUTH_PROXY_IMAGE" ]; then
    OAUTH_PROXY_IMAGE="$($OC get istag oauth-proxy:v4.4 -n openshift -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
  fi
  if [ -z "$OAUTH_PROXY_IMAGE" ]; then
    echo "ERROR: no oauth-proxy image (ImageStream openshift/oauth-proxy:v4.4 not found); set OAUTH_PROXY_IMAGE" >&2
    exit 1
  fi
  # The session cookie's key, made once: a new one would log everybody out.
  if ! $OC get secret usb-ip-dashboard-cookie -n "$NAMESPACE" >/dev/null 2>&1; then
    $OC create secret generic usb-ip-dashboard-cookie -n "$NAMESPACE" \
      --from-literal=cookie-secret="$(head -c 24 /dev/urandom | base64)" >/dev/null
    $OC label secret usb-ip-dashboard-cookie -n "$NAMESPACE" app.kubernetes.io/part-of=usb-ip-kubevirt >/dev/null
  fi
  with_hash deploy/60-dashboard.yaml
  # the page and the collector used to ship in ConfigMaps; the image carries them now
  $OC delete configmap usb-ip-collector-py usb-ip-dashboard-html usb-ip-dashboard-vendor usb-ip-dashboard-fonts \
    -n "$NAMESPACE" --ignore-not-found >/dev/null
  sed "s/namespace: default/namespace: ${NAMESPACE}/; s/usb-ip-dashboard-login-default/usb-ip-dashboard-login-${NAMESPACE}/" \
    deploy/64-dashboard-login.yaml | $OC apply -f -
  if [ "$OTHER_VMS" = "yes" ]; then
    sed "s/namespace: default/namespace: ${NAMESPACE}/; s/usb-ip-dashboard-other-vms-default/usb-ip-dashboard-other-vms-${NAMESPACE}/" \
      deploy/62-dashboard-other-vms.yaml | $OC apply -f -
  else
    $OC delete clusterrolebinding "usb-ip-dashboard-other-vms-${NAMESPACE}" --ignore-not-found
  fi
  if [ "$ROUTE" = "yes" ]; then
    sed "s/namespace: default/namespace: ${NAMESPACE}/" deploy/70-dashboard-route.yaml | $OC apply -f - 2>/dev/null \
      && echo "    dashboard URL: https://$($OC get route usb-ip-dashboard -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null), behind the OpenShift login" \
      || echo "    no Route support; use: oc port-forward deploy/usb-ip-dashboard 8080"
  else
    $OC delete route usb-ip-dashboard -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    echo "    reach it: oc port-forward deploy/usb-ip-dashboard 8080  (then open http://localhost:8080)"
  fi
fi

echo "done. check with scripts/status.sh"
