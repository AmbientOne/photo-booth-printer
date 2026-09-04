<#
.SYNOPSIS
    Undo everything install.ps1 changed on this machine. Elevated PowerShell.

.DESCRIPTION
    Leaves the repo and the photos alone -- this only reverses machine state:
    the scheduled tasks, the firewall rule, the hotspot timeout, auto logon.
    See SECURITY-CLEANUP.md for the iPad side and the photo archive.
#>
[CmdletBinding()]
param([switch]$KeepAutoLogon)

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell.'
}

Write-Host 'Removing scheduled tasks...'
foreach ($name in 'PhotoBooth Hotspot', 'PhotoBooth Print Server') {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host 'Removing firewall rules...'
Get-NetFirewallRule -DisplayName 'PhotoBooth*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'python.exe' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

Write-Host 'Restoring the hotspot idle timeout...'
Remove-ItemProperty 'HKLM:\System\CurrentControlSet\Services\icssvc\Settings' `
    -Name 'PeerlessTimeoutEnabled' -ErrorAction SilentlyContinue

if (-not $KeepAutoLogon) {
    Write-Host 'Disabling automatic logon and clearing the stored password...'
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String
    Remove-ItemProperty $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
}

Write-Host 'Stopping anything still running...'
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='py.exe'" |
    Where-Object { $_.CommandLine -like '*app.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Machine state reverted.' -ForegroundColor Green
Write-Host 'Still to do by hand: remove the profile from the iPad, and decide'
Write-Host 'what happens to C:\PhotoBooth\archive. See SECURITY-CLEANUP.md.'
