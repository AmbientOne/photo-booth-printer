<#
.SYNOPSIS
    Set up the booth on a machine whose Wi-Fi comes from a travel router.
    Elevated PowerShell, run once.

.DESCRIPTION
    The alternative to install.ps1. Use this one when a router provides the
    network and the PC joins it by ethernet:

        iPad --wifi--> travel router --ethernet--> this PC

    Nothing here touches the Wi-Fi adapter, which is the whole point: the
    hotspot API, its need for an upstream connection to share, and whether the
    adapter can be client and access point at the same time all stop mattering.

    Compared with install.ps1 (the hotspot path):
      - No hotspot task. The router is always on.
      - The print server starts AT BOOT as SYSTEM rather than at logon, so it
        is serving before anyone signs in.
      - The address is yours to choose instead of being fixed at 192.168.137.1.

    Auto logon is still needed, but only for DNP Hot Folder Print, which is a
    desktop application and has to run in a logged-in session. The print server
    no longer depends on it: prints queue in the hot folder until HFP appears.

.EXAMPLE
    .\install-router.ps1 -ServerIP 192.168.8.2 -Subnet 192.168.8.0/24
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerIP,
    [Parameter(Mandatory = $true)][string]$Subnet,
    [string]$Token,
    [switch]$SkipFirewall
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (right-click, Run as administrator).'
}

if ($ServerIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "ServerIP is not an IPv4 address: $ServerIP" }
if ($Subnet -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { throw "Subnet should look like 192.168.8.0/24 : $Subnet" }

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $RepoRoot 'print-server'
$AppPy     = Join-Path $ServerDir 'app.py'
$CertPem   = Join-Path $ServerDir 'certs\cert.pem'
if (-not (Test-Path $AppPy)) { throw "Missing expected file: $AppPy" }

Write-Host "Repo   : $RepoRoot"
Write-Host "Address: $ServerIP  (subnet $Subnet)"
Write-Host ""

# --- 1. does this machine actually hold that address? ---------------------
Write-Host "[1/5] Checking the address..."
$held = Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
    Where-Object { $_.IPAddress -eq $ServerIP }
if ($held) {
    Write-Host ("      held on " + $held.InterfaceAlias)
} else {
    Write-Warning "This machine does not currently hold $ServerIP."
    Write-Warning "Give it a static address, or reserve it in the router DHCP,"
    Write-Warning "or HTTPS fails with a certificate name mismatch."
}

# --- 2. can SYSTEM run Python? --------------------------------------------
# A per-user Python install lives under C:\Users and is invisible to SYSTEM,
# so the boot task would fail silently at every restart.
Write-Host "[2/5] Checking Python is visible to the SYSTEM account..."
$py = (Get-Command py -EA SilentlyContinue).Source
if (-not $py) { $py = (Get-Command python -EA SilentlyContinue).Source }
if (-not $py) { throw "Python not found. Install it for all users from python.org." }

$pyBad = ($py -like "$env:SystemDrive\Users\*") -or ($py -like "*\WindowsApps\*")
if ($pyBad) {
    Write-Warning "Python is not usable by the SYSTEM account: $py"
    if ($py -like "*\WindowsApps\*") {
        Write-Warning "That is the Microsoft Store build. Its files live under"
        Write-Warning "C:\Program Files\WindowsApps, which is locked down and not"
        Write-Warning "runnable by SYSTEM."
    }
    Write-Warning "Install Python from python.org, elevated, with Install for all"
    Write-Warning "users ticked, then reinstall requirements.txt elevated and rerun this."
} else {
    Write-Host "      $py"
}

# --- 3. tell the server which address to advertise ------------------------
# Machine scope, so the SYSTEM account sees it too.
Write-Host "[3/5] Recording the advertised address..."
[Environment]::SetEnvironmentVariable("PHOTOBOOTH_ADVERTISED_IP", $ServerIP, "Machine")
Write-Host "      PHOTOBOOTH_ADVERTISED_IP = $ServerIP (machine scope)"

# --- 3b. a token you chose -------------------------------------------------
# On a headless machine a random token is unhelpful: it is written to
# C:\PhotoBooth\token.txt and nobody can read it without a monitor. Setting one
# here makes the booth URL predictable from anywhere.
if ($Token) {
    if ($Token.Length -lt 8) { throw "Token should be at least 8 characters." }
    if ($Token -notmatch "^[A-Za-z0-9_-]+$") { throw "Token: letters, numbers, dash and underscore only, it goes in a URL." }
    [Environment]::SetEnvironmentVariable("PHOTOBOOTH_TOKEN", $Token, "Machine")
    Write-Host "      PHOTOBOOTH_TOKEN set (machine scope)"
} else {
    Write-Host "      PHOTOBOOTH_TOKEN not set: a random one is generated and written"
    Write-Host "      to C:\PhotoBooth\token.txt, which needs a monitor to read."
}

# --- 4. firewall ----------------------------------------------------------
if ($SkipFirewall) {
    Write-Host "[4/5] Firewall: skipped."
} else {
    Write-Host "[4/5] Firewall..."
    Get-NetFirewallRule -DisplayName "python.exe" -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
    Get-NetFirewallRule -DisplayName "PhotoBooth*" -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
    New-NetFirewallRule -DisplayName "PhotoBooth Print Server" `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5000, 5443 `
        -Profile Private, Public -RemoteAddress $Subnet | Out-Null
    Write-Host "      allowed: TCP 5000+5443 from $Subnet only."
}

# --- 5. boot task ---------------------------------------------------------
# SYSTEM at startup needs no interactive session, so the booth is serving
# before anyone logs in. The hotspot path could never do this.
Write-Host "[5/5] Registering the boot task..."

Get-ScheduledTask -TaskName "PhotoBooth Hotspot" -EA SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = "PT20S"      # let the network stack settle

Register-ScheduledTask -TaskName "PhotoBooth Print Server" -Force `
    -Description "Runs the print server at boot (router setup, no hotspot)." `
    -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit ([TimeSpan]::Zero) `
                 -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)) `
    -Trigger $trigger `
    -Action (New-ScheduledTaskAction -Execute $py -Argument "app.py" -WorkingDirectory $ServerDir) | Out-Null
Write-Host "      PhotoBooth Print Server runs as SYSTEM, 20s after boot."

Write-Host ""
Write-Host "      Proving SYSTEM can actually run it..."
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like "*app.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
Start-Sleep -Seconds 2

Start-ScheduledTask -TaskName "PhotoBooth Print Server"
$ok = $false
$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline) {
    try {
        $probe = Invoke-RestMethod -Uri "http://127.0.0.1:5000/status" -TimeoutSec 3
        if ($probe) { $ok = $true; break }
    } catch { Start-Sleep -Milliseconds 750 }
}

if ($ok) {
    Write-Host "      Confirmed: the server answered on port 5000." -ForegroundColor Green
} else {
    Write-Warning "The task ran but the server never answered."
    Write-Warning "Almost always Python not being reachable by SYSTEM. Check:"
    Write-Warning "  Get-ScheduledTaskInfo -TaskName 'PhotoBooth Print Server'"
    Write-Warning "A LastTaskResult of 267011 means it is still running; 2147942402"
    Write-Warning "means the executable could not be found by SYSTEM."
}

# --- what is left for a human ---------------------------------------------
Write-Host ""
Write-Host "Machine configured." -ForegroundColor Green
Write-Host ""

$certOk = $false
if (Test-Path $CertPem) {
    $txt = & certutil -dump $CertPem 2>$null | Out-String
    $certOk = $txt -match [regex]::Escape($ServerIP)
}
if (-not $certOk) {
    Write-Host "STILL TO DO:" -ForegroundColor Yellow
    Write-Host "  1. The certificate does not cover $ServerIP. Regenerate it:"
    Write-Host "         cd $ServerDir"
    Write-Host "         py make_cert.py $ServerIP"
    Write-Host "     Then reinstall it on every iPad, removing the old profile first."
} else {
    Write-Host "  1. Certificate already covers $ServerIP." -ForegroundColor Green
}

Write-Host ""
Write-Host "  2. DNP Hot Folder Print is a desktop app and must run in a logged-in"
Write-Host "     session. Put a shortcut to it in the Startup folder (paste"
Write-Host "     shell:startup into Explorer) and enable auto logon for a dedicated"
Write-Host "     local Booth account so it comes up unattended. The print server"
Write-Host "     itself no longer needs that: prints queue until HFP appears."
Write-Host ""
Write-Host "  3. Turn OFF client isolation / AP isolation on the router, or the"
Write-Host "     iPad cannot reach this machine."
Write-Host ""
Write-Host "  4. Restart, then run .\status.ps1 to confirm."
if ($Token) {
    Write-Host ""
    Write-Host "  Booth URL for the iPad:" -ForegroundColor Cyan
    Write-Host "      https://${ServerIP}:5443/booth?k=$Token"
    Write-Host "  Certificate, first time only (accept the warning):" -ForegroundColor Cyan
    Write-Host "      https://${ServerIP}:5443/cert"
}
Write-Host ""
