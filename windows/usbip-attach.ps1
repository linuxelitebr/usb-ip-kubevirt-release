#Requires -RunAsAdministrator
<#
  usbip-attach.ps1 - attach ONE remote device, chosen deliberately.

  How you pick which device (assignment):
    -BusId   the exporter's busid, e.g. 1-2 (see its state.json on :3241).
             Passthrough renumbers devices, so this is a slot on the exporter,
             not a physical hub port. Use it for two identical devices.
    -VidPid  vendor:product, e.g. 0a12:0001. Use when that device type is the
             only one of its kind on the exporter. If more than one matches, the
             script refuses and lists the busids so you pick one with -BusId.
    -Serial  handed to usbip-win2, which reports it to Windows as the device's
             serial number. It does not choose the device.
    -Port    the exporter's TCP port when it is not 3240, e.g. a NodePort.

    .\usbip-attach.ps1 -Server usb-ip-exporter -VidPid 0a12:0001
    .\usbip-attach.ps1 -Server 192.0.2.50   -BusId 1-2
    .\usbip-attach.ps1 -Server 192.0.2.10   -Port 31240 -VidPid 0a12:0001
#>
param(
  [string]$Server = 'usb-ip-exporter',
  [int]$Port = 3240,
  [string]$VidPid,
  [string]$BusId,
  [string]$Serial,
  [int]$TimeoutSec = 60
)
$ErrorActionPreference = 'Stop'
$usbip = @("C:\Program Files\USBip\usbip.exe","C:\Program Files\usbip-win2\usbip.exe") | ? { Test-Path $_ } | Select -First 1
if (-not $usbip) { throw "usbip.exe not installed (run install-usbip.ps1 first)" }
if (-not $BusId -and -not $VidPid) { throw "give -BusId (the exporter's busid) or -VidPid (vendor:product)" }
# The port is a global flag before the command, never host:port. Left out for
# 3240, so the default command line stays exactly what it always was.
$tcp = @(); if ($Port -ne 3240) { $tcp = @('--tcp-port', "$Port") }

function Resolve-BusId {
  param([string]$srv, [string]$vp)
  $out = & $usbip @tcp list -r $srv 2>&1
  $hits = @()
  foreach ($ln in $out) {
    if ("$ln" -match '(\d+-[\d.]+)\s*:' ) {
      $bus = $Matches[1]
      if ("$ln" -match '\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)' -and $Matches[1].ToLower() -eq $vp.ToLower()) {
        $hits += $bus
      }
    }
  }
  return $hits
}

function Resolve-VidPid {
  param([string]$srv, [string]$bus)
  foreach ($ln in (& $usbip @tcp list -r $srv 2>&1)) {
    if ("$ln" -match ('^\s*' + [regex]::Escape($bus) + '\s*:') -and "$ln" -match '\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)') {
      return $Matches[1].ToLower()
    }
  }
}

$target = $null
if ($BusId) {
  $target = $BusId
} else {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do {
    $hits = @(Resolve-BusId $Server $VidPid)
    if ($hits.Count -eq 1) { $target = $hits[0]; break }
    if ($hits.Count -gt 1) {
      throw "more than one $VidPid on $Server (busids: $($hits -join ', ')). Pick one with -BusId."
    }
    Start-Sleep 2
  } while ((Get-Date) -lt $deadline)
  if (-not $target) { throw "no $VidPid exported by $Server (is the exporter up and the device bound?)" }
}

if (-not $VidPid) { $VidPid = Resolve-VidPid $Server $target }   # for the power fix below

# --once: usbip-win2 retries a dropped busid on its own, and after a DEVICES
# change that slot can hold another device. The watchdog retries by vendor:product.
$args = @('attach','-r',$Server,'-b',$target,'--once')
if ($Serial) { $args += @('--serial',$Serial) }
Write-Host "attach $Server$(if($tcp){":$Port"}) busid=$target$(if($VidPid){" ($VidPid)"})$(if($Serial){" serial=$Serial"})"
& $usbip @tcp @args
if ($LASTEXITCODE) { exit $LASTEXITCODE }

# usbip carries no remote wakeup: once Windows powers the device down it never
# comes back on its own. Wait for Windows to enumerate it, then stop Windows from
# powering it down. The watchdog keeps checking after that.
if ($VidPid) {
  $pnp = 'VID_{0}&PID_{1}' -f ($VidPid.Split(':')[0].ToUpper()), ($VidPid.Split(':')[1].ToUpper())
  $deadline = (Get-Date).AddSeconds(15)
  do {
    Start-Sleep 1
    $w = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -EA SilentlyContinue | ? { $_.InstanceName -match $pnp })
  } while (-not $w.Count -and (Get-Date) -lt $deadline)
  $on = @($w | ? { $_.Enable })
  foreach ($i in $on) { Set-CimInstance -InputObject $i -Property @{ Enable = $false } }
  Write-Host "power-off disabled on $($on.Count) of $($w.Count) interface(s)"
}
