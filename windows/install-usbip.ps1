#Requires -RunAsAdministrator
<#
  install-usbip.ps1 - install the signed usbip-win2 client, the same way every time.

  Flow:
    1. Use -InstallerPath (a copy you staged) OR download the pinned release.
    2. Check the SHA256 (when you pass -Sha256) and the installer's Authenticode
       signature (fails unless it is Valid, or Valid-offline, see below).
    3. Install silently (InnoSetup) with a timeout, in case a driver dialog is
       waiting on the VM console.
    4. Find usbip.exe and check the driver packages in the driver store. Under
       Secure Boot they must be Microsoft-signed (attestation); fails loudly if not.

  Examples:
    .\install-usbip.ps1 -InstallerPath C:\usbip-lab\USBip-0.9.8.0-x64.exe -Sha256 <hash>
    .\install-usbip.ps1 -Sha256 <hash>    (downloads v0.9.8.0; needs egress to GitHub's CDN)
#>
param(
  [string]$Version = '0.9.8.0',
  [string]$Url,
  [string]$InstallerPath,
  [string]$Sha256,
  [string]$ExpectedSigner = 'Scheibling|Cloudyne',
  [int]$InstallTimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $Url) { $Url = "https://github.com/vadimgrn/usbip-win2/releases/download/v.$Version/USBip-$Version-x64.exe" }

if (-not $InstallerPath) {
  $InstallerPath = Join-Path $env:TEMP "USBip-$Version-x64.exe"
  Write-Host "[1] downloading $Url"
  try { & curl.exe -L --connect-timeout 15 --max-time 300 -o $InstallerPath $Url | Out-Null } catch {}
  if (-not (Test-Path $InstallerPath)) { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $InstallerPath }
} else {
  Write-Host "[1] using the staged installer: $InstallerPath"
}
if (-not (Test-Path $InstallerPath)) { throw "installer not found: $InstallerPath (can the VM reach GitHub's CDN?)" }
Write-Host ("[2] file: {0} ({1:N1} MB)" -f $InstallerPath, ((Get-Item $InstallerPath).Length/1MB))

if ($Sha256) {
  $h = (Get-FileHash $InstallerPath -Algorithm SHA256).Hash
  if ($h -ne $Sha256.ToUpper()) { throw "SHA256 mismatch: $h != $($Sha256.ToUpper())" }
  Write-Host "    sha256 OK ($h)"
}

$sig = Get-AuthenticodeSignature $InstallerPath
$signer = if ($sig.SignerCertificate) { ($sig.SignerCertificate.Subject -split ',')[0] } else { '(no certificate)' }
$issuer = if ($sig.SignerCertificate) { ($sig.SignerCertificate.Issuer -split ',')[0] } else { '' }
Write-Host ("[3] installer signature: {0} / {1} / issuer {2}" -f $sig.Status, $signer, $issuer)
$sigOk = $false
if ($sig.Status -eq 'Valid') {
  $sigOk = $true
} elseif ($sig.Status -eq 'UnknownError' -and $sig.SignerCertificate) {
  # Isolated VM: the online revocation check cannot run. Build the chain offline
  # and check the publisher instead.
  $ch = New-Object System.Security.Cryptography.X509Certificates.X509Chain
  $ch.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
  $built = $ch.Build($sig.SignerCertificate)
  $subjOk = ($sig.SignerCertificate.Subject -match $ExpectedSigner)
  if ($built -and $subjOk) {
    Write-Warning "signature valid offline (chain builds, publisher '$signer' matches); online revocation not checked on this isolated VM"
    $sigOk = $true
  }
}
if (-not $sigOk) { throw "installer signature rejected: Status=$($sig.Status) signer=$signer (expected publisher /$ExpectedSigner/)" }

Write-Host "[4] installing (silent, timeout ${InstallTimeoutSec}s)..."
$p = Start-Process -FilePath $InstallerPath -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -PassThru
if (-not $p.WaitForExit($InstallTimeoutSec * 1000)) {
  try { $p.Kill() } catch {}
  throw "TIMEOUT: the installer did not finish in ${InstallTimeoutSec}s (a driver trust dialog on the VM console?)"
}
Write-Host ("    exit={0}" -f $p.ExitCode)
Start-Sleep 3

$usbip = @("C:\Program Files\USBip\usbip.exe","C:\Program Files\usbip-win2\usbip.exe") | ? { Test-Path $_ } | Select -First 1
if (-not $usbip) { $usbip = (Get-ChildItem 'C:\Program Files' -Recurse -Filter usbip.exe -EA SilentlyContinue | Select -First 1).FullName }
if (-not $usbip) { throw "usbip.exe not found after the install (exit=$($p.ExitCode))" }
Write-Host ("[5] usbip.exe: {0}" -f $usbip)

# The drivers land in the driver store, not next to usbip.exe. A test-signed
# build would install fine and then refuse to load under Secure Boot.
$sys = @(Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Directory -Filter 'usbip2*' -EA SilentlyContinue |
         % { Get-ChildItem $_.FullName -Filter *.sys -EA SilentlyContinue })
if (-not $sys.Count) { throw "no usbip2 driver in the driver store after the install (exit=$($p.ExitCode))" }
foreach ($f in $sys) {
  $d = Get-AuthenticodeSignature $f.FullName
  $ds = if ($d.SignerCertificate) { ($d.SignerCertificate.Subject -split ',')[0] } else { '(no certificate)' }
  Write-Host ("[6] driver {0}: {1} / {2}" -f $f.Name, $d.Status, $ds)
  if ($d.Status -notin 'Valid','UnknownError' -or $ds -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
    throw "driver $($f.Name) is not Microsoft-signed ($($d.Status), $ds): it will not load under Secure Boot"
  }
}
# What got installed, read from the binary: an -InstallerPath of another
# release installs that release, whatever -Version says.
$installed = (Get-Item $usbip).VersionInfo.ProductVersion
Write-Host "[7] OK: usbip-win2 $installed installed."
