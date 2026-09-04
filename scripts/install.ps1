<#
.SYNOPSIS
    One-time setup so the photo booth comes back on its own after any restart.

.DESCRIPTION
    Run this ONCE on the mini PC, from an elevated PowerShell. After it
    finishes, the only recovery step anyone ever needs is "restart the
    computer" -- everything below is re-established at boot.

    What it does:
      1. Stops the hotspot switching itself off when no device is connected.
      2. Replaces the wide-open "python.exe" firewall rules with one scoped to
         the booth's own network only.
      3. Registers two scheduled tasks that run at logon: the hotspot, then
         the print server.
      4. Optionally enables automatic logon, which is what makes the tasks fire
         on a headless machine after a power cut.

.EXAMPLE
    .\install.ps1 -Ssid "PhotoBooth" -Passphrase "snapshot2026" -EnableAutoLogon
#>
[CmdletBinding()]
param(
    [string]$Ssid,
    [string]$Passphrase,
    [switch]$EnableAutoLogon
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell (right-click -> Run as administrator).'
}

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ServerDir  = Join-Path $RepoRoot 'print-server'
$Launcher   = Join-Path $ServerDir 'run_print_server.bat'
$HotspotPs1 = Join-Path $PSScriptRoot 'hotspot.ps1'

foreach ($p in @($Launcher, $HotspotPs1)) {
    if (-not (Test-Path $p)) { throw "Missing expected file: $p" }
}

Write-Host "Repo: $RepoRoot" -ForegroundColor Cyan
Write-Host ''

# --- 1. keep the hotspot up ------------------------------------------------
# Mobile Hotspot shuts down after ~5 minutes with no clients. During setup, or
# any gap between guests, that would silently take the booth off the air.

Write-Host '[1/4] Disabling the hotspot idle timeout...'
$icsSettings = 'HKLM:\System\CurrentControlSet\Services\icssvc\Settings'
New-Item -Path $icsSettings -Force | Out-Null
Set-ItemProperty -Path $icsSettings -Name 'PeerlessTimeoutEnabled' -Value 0 -Type DWord
Write-Host '      done.'

# --- 2. firewall -----------------------------------------------------------
# The rules Windows auto-creates from the "Allow access" popup permit ANY
# python script to accept inbound connections from ANY address on a Public
# network. Replace them with one rule bound to the booth's own subnet.

Write-Host '[2/4] Tightening firewall rules...'
Get-NetFirewallRule -DisplayName 'python.exe' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'PhotoBooth*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

New-NetFirewallRule -DisplayName 'PhotoBooth Print Server' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5000, 5443 `
    -Profile Private, Public -RemoteAddress 192.168.137.0/24 | Out-Null
Write-Host '      allowed: TCP 5000+5443 from 192.168.137.0/24 only.'

# --- 3. scheduled tasks ----------------------------------------------------
# At logon, not at boot: the Mobile Hotspot API needs an interactive user
# session, so a SYSTEM task at startup cannot bring the network up.

Write-Host '[3/4] Registering startup tasks...'

$user = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)

# -- hotspot first
$hsArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$HotspotPs1`""
if ($Ssid)       { $hsArgs += " -Ssid `"$Ssid`"" }
if ($Passphrase) { $hsArgs += " -Passphrase `"$Passphrase`"" }

Register-ScheduledTask -TaskName 'PhotoBooth Hotspot' -Force `
    -Description 'Brings up the booth Wi-Fi access point at logon.' `
    -Principal $principal -Settings $settings `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $hsArgs) | Out-Null
Write-Host '      "PhotoBooth Hotspot" registered.'

# -- then the server, after the network has settled
$serverTrigger = New-ScheduledTaskTrigger -AtLogOn
$serverTrigger.Delay = 'PT30S'

Register-ScheduledTask -TaskName 'PhotoBooth Print Server' -Force `
    -Description 'Runs the print server (waitress + cheroot) at logon.' `
    -Principal $principal -Settings $settings -Trigger $serverTrigger `
    -Action (New-ScheduledTaskAction -Execute $Launcher -WorkingDirectory $ServerDir) | Out-Null
Write-Host '      "PhotoBooth Print Server" registered (30s after logon).'

# --- 4. auto logon ---------------------------------------------------------
# Without this the tasks never fire on an unattended machine: after a power cut
# the mini PC sits at the lock screen forever.

Write-Host '[4/4] Automatic logon...'
if ($EnableAutoLogon) {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Write-Host ''
    Write-Warning 'Auto logon stores the account password in the registry in clear text.'
    Write-Warning 'Only do this on a machine dedicated to the booth.'
    $cred = Get-Credential -UserName $user -Message 'Password for automatic logon'
    $nc = $cred.GetNetworkCredential()
    $domain = if ($nc.Domain) { $nc.Domain } else { $env:COMPUTERNAME }

    Set-ItemProperty $winlogon -Name 'AutoAdminLogon'    -Value '1'        -Type String
    Set-ItemProperty $winlogon -Name 'DefaultUserName'   -Value $nc.UserName -Type String
    Set-ItemProperty $winlogon -Name 'DefaultDomainName' -Value $domain    -Type String
    Set-ItemProperty $winlogon -Name 'DefaultPassword'   -Value $nc.Password -Type String

    # AutoLogonCount is a countdown: Windows decrements it on each boot and
    # stops logging in automatically when it hits zero. Tools like Sysinternals
    # Autologon set it. Left behind, the booth would come back after a restart
    # a few times and then quietly stop -- the exact failure this design is
    # meant to rule out.
    Remove-ItemProperty $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue

    Write-Host ('      enabled for {0}\{1}.' -f $domain, $nc.UserName)
    Remove-Variable nc
    Write-Host '      NOTE: a Microsoft account or a required PIN can block this.'
    Write-Host '            Use a local account with a plain password.'
} else {
    Write-Host '      skipped. Re-run with -EnableAutoLogon, or set it up in netplwiz.'
    Write-Host '      Without it, someone must log in after a power cut.'
}

Write-Host ''
Write-Host 'Setup complete. Restart the machine to verify it all comes back.' -ForegroundColor Green
Write-Host 'Then check:  .\status.ps1'
