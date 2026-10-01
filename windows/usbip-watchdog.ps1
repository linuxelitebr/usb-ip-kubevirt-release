#Requires -RunAsAdministrator
<#
  usbip-watchdog.ps1 - keep ONE device attached and awake. `usbip attach` is not
  a daemon; it returns. When the device drops (reboot, network blip, exporter
  restart) this re-attaches it. While it is attached, this also keeps Windows
  from powering it down and restarts it if it got suspended anyway: usbip cannot
  carry the remote wakeup back, so a suspended device never returns on its own.
  Runs as a Scheduled Task (SYSTEM, at startup) via register-watchdog.ps1.

  Selection matches usbip-attach.ps1:
    -VidPid  required. Also how the watchdog knows the device is present (Windows
             PnP VID_xxxx&PID_yyyy).
    -BusId   optional. The exporter's busid (a slot on the exporter, not a
             physical hub port); use it when two identical devices share a VidPid.
    -Serial  optional. Handed to usbip-win2, which reports it to Windows as the
             device's serial number. It does not choose the device.
    -Port    optional. The exporter's TCP port when it is not 3240 (a NodePort).

    .\usbip-watchdog.ps1 -Server usb-ip-exporter -VidPid 0a12:0001
    .\usbip-watchdog.ps1 -Server 192.0.2.50 -VidPid 0a12:0001 -BusId 1-2
#>
param(
  [Parameter(Mandatory=$true)][string]$Server,
  [int]$Port = 3240,
  [Parameter(Mandatory=$true)][string]$VidPid,
  [string]$BusId,
  [string]$Serial,
  [int]$IntervalSec = 15,
  [string]$LogPath = 'C:\usbip-lab\watchdog.log'
)
$ErrorActionPreference = 'Continue'
$usbip = @("C:\Program Files\USBip\usbip.exe","C:\Program Files\usbip-win2\usbip.exe") | ? { Test-Path $_ } | Select -First 1
$tcp = @(); if ($Port -ne 3240) { $tcp = @('--tcp-port', "$Port") }   # global flag, before the command
$pnp ='VID_{0}&PID_{1}' -f ($VidPid.Split(':')[0].ToUpper()), ($VidPid.Split(':')[1].ToUpper())
$dir = Split-Path $LogPath; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
function Log($m) { "$([DateTime]::UtcNow.ToString('o')) $m" | Add-Content $LogPath }
function Present { [bool](Get-PnpDevice -PresentOnly -EA SilentlyContinue | ? { $_.InstanceId -match $pnp -and $_.Status -eq 'OK' }) }
# usbip carries no remote wakeup. Once Windows powers the device down it never
# comes back on its own, and Device Manager still says Status OK. So stop
# Windows from powering it down, and restart it if it is already suspended.
function Disable-PowerOff {
  $w = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -EA SilentlyContinue |
         ? { $_.InstanceName -match $pnp -and $_.Enable })
  foreach ($i in $w) { Set-CimInstance -InputObject $i -Property @{ Enable = $false } }
  $w.Count
}
function Test-Suspended {
  # Only the USB device itself and its input interfaces count. Other functions
  # idle on purpose: a sound card's audio function sits in D3 until something plays.
  foreach ($d in Get-PnpDevice -PresentOnly -EA SilentlyContinue | ? { $_.InstanceId -match $pnp -and
             ($_.InstanceId -match "^USB\\$pnp\\" -or $_.Class -in 'HIDClass','Keyboard','Mouse') }) {
    $pd = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_PowerData -EA SilentlyContinue).Data
    if ($pd -and [BitConverter]::ToInt32($pd, 4) -gt 1) { return $true }   # most recent state: 1 = D0
  }
  $false
}
function Restart-Device {
  $dev = Get-PnpDevice -PresentOnly -EA SilentlyContinue | ? { $_.InstanceId -match "^USB\\$pnp\\" } | Select -First 1
  if ($dev) { pnputil /restart-device "$($dev.InstanceId)" | Out-Null }
}
function Resolve-BusId {
  if ($BusId) { return $BusId }
  $out = & $usbip @tcp list -r $Server 2>&1
  foreach ($ln in $out) {
    if ("$ln" -match '(\d+-[\d.]+)\s*:' ) {
      $bus = $Matches[1]
      if ("$ln" -match '\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)' -and $Matches[1].ToLower() -eq $VidPid.ToLower()) { return $bus }
    }
  }
  return $null
}
Log "watchdog start server=$Server port=$Port vidpid=$VidPid busid=$BusId serial=$Serial pnp=$pnp"
while ($true) {
  try {
    if (-not (Present)) {
      # A dropped connection makes usbip-win2 retry the same busid by itself, 30 s
      # later, and after a DEVICES change that slot can hold another device: cancel
      # its retries, then attach by vendor:product
      & $usbip attach --stop-all 2>&1 | Out-Null
      $t = Resolve-BusId
      if ($t) {
        $a = @('attach','-r',$Server,'-b',$t,'--once'); if ($Serial) { $a += @('--serial',$Serial) }
        Log "device absent -> attach busid=$t"
        & $usbip @tcp @a 2>&1 | % { Log "  $_" }
      } else {
        Log "device absent and $VidPid not exported by $Server"
      }
    } else {
      $n = Disable-PowerOff
      if ($n) { Log "power-off allowed on $n interface(s) -> disabled" }
      if (Test-Suspended) { Log "device suspended -> restart"; Restart-Device }
    }
  } catch { Log "ERROR $_" }
  Start-Sleep $IntervalSec
}
