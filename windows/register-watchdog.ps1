#Requires -RunAsAdministrator
<#
  register-watchdog.ps1 - install the watchdog as a Scheduled Task (SYSTEM, at
  startup, restarts if it dies). Pass the same selection flags you would give
  usbip-watchdog.ps1.

    .\register-watchdog.ps1 -Server usb-ip-exporter -VidPid 0a12:0001
    .\register-watchdog.ps1 -Server 192.0.2.50 -VidPid 0a12:0001 -BusId 1-2
    .\register-watchdog.ps1 -Server 192.0.2.10 -Port 31240 -VidPid 0a12:0001
#>
param(
  [string]$TaskName = 'usbip-watchdog',
  [string]$ScriptPath = 'C:\usbip-lab\usbip-watchdog.ps1',
  [Parameter(Mandatory=$true)][string]$Server,
  [int]$Port = 3240,
  [Parameter(Mandatory=$true)][string]$VidPid,
  [string]$BusId,
  [string]$Serial
)
$ErrorActionPreference = 'Stop'
$argline = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Server $Server -VidPid $VidPid"
if ($Port -ne 3240) { $argline += " -Port $Port" }
if ($BusId)  { $argline += " -BusId $BusId" }
if ($Serial) { $argline += " -Serial $Serial" }
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argline
$trg = New-ScheduledTaskTrigger -AtStartup
$prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
# A running watchdog keeps its old arguments: the task ignores a second start
# (MultipleInstances IgnoreNew), so a re-run stops it before the new one goes in.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName }
Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "task '$TaskName' registered and started"
