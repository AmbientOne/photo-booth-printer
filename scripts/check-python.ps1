<#
.SYNOPSIS
    Check that the SYSTEM account can run Python and import the booth's
    dependencies. Elevated PowerShell. Changes nothing permanent.

.DESCRIPTION
    The print server runs as SYSTEM at boot in the router setup, so it never
    sees the logged-in user profile. Windows now offers three ways to install
    Python and two of them are per-user, which SYSTEM cannot reach:

        C:\Users\...\AppData\Local\Microsoft\WindowsApps\py.exe   Store / Install Manager
        C:\Users\...\AppData\Local\Programs\Python\...            python.org default button
        C:\Program Files\Python313\  +  C:\Windows\py.exe         "Install for all users"  <-- want this

    Only the third works. Worse, pip run unelevated can fall back to a per-user
    site-packages, so SYSTEM can start Python and still fail on the imports.
    This tests both, as SYSTEM, the same way the boot task will.

    Nothing on screen explains any of that when it fails at boot on a headless
    machine, which is why this exists.
#>

$ErrorActionPreference = 'Continue'

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host 'Python readiness check' -ForegroundColor Cyan
Write-Host ('-' * 64)

# --- what the logged-in user sees -----------------------------------------
Write-Host ''
Write-Host 'As you (the logged-in user):' -ForegroundColor Cyan
$found = @(Get-Command py, python -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
if ($found.Count -eq 0) {
    Write-Host '  no python on PATH at all'
} else {
    foreach ($f in $found) {
        $bad = ($f -like "$env:SystemDrive\Users\*") -or ($f -like '*\WindowsApps\*')
        $tag = if ($bad) { 'PER-USER, SYSTEM cannot use this' } else { 'machine-wide' }
        $col = if ($bad) { 'Yellow' } else { 'Green' }
        Write-Host ('  {0,-62} {1}' -f $f, $tag) -ForegroundColor $col
    }
}

Write-Host ''
Write-Host ('  C:\Windows\py.exe present : {0}' -f (Test-Path 'C:\Windows\py.exe'))
$pf = Get-ChildItem 'C:\Program Files\Python*' -Directory -ErrorAction SilentlyContinue
Write-Host ('  Program Files install    : {0}' -f $(if ($pf) { ($pf.Name -join ', ') } else { 'none' }))

# --- the real test --------------------------------------------------------
Write-Host ''
Write-Host 'As the SYSTEM account (what actually matters):' -ForegroundColor Cyan

if (-not $elevated) {
    Write-Host '  SKIPPED - rerun this from an elevated PowerShell.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$out = Join-Path $env:SystemRoot 'Temp\photobooth-pycheck.txt'
Remove-Item $out -ErrorAction SilentlyContinue

# Version first, then the imports the server actually needs. pip installing to
# a per-user site-packages fails only on the second, which is the subtler bug.
$cmd = '/c (py -V && py -c "import flask, waitress, cheroot, cryptography; print(''IMPORTS OK'')") > "' + $out + '" 2>&1'

Register-ScheduledTask -TaskName 'PhotoBoothPyCheck' -Force `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
    -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)) `
    -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmd) | Out-Null

Start-ScheduledTask -TaskName 'PhotoBoothPyCheck'

$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if ((Get-ScheduledTask -TaskName 'PhotoBoothPyCheck').State -eq 'Ready') { break }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 1

$result = if (Test-Path $out) { (Get-Content $out -Raw).Trim() } else { '' }

Unregister-ScheduledTask -TaskName 'PhotoBoothPyCheck' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $out -ErrorAction SilentlyContinue

Write-Host ''
if ($result) { $result -split "`n" | ForEach-Object { Write-Host ('  ' + $_.Trim()) } }
else { Write-Host '  (no output - the task did not run)' }
Write-Host ''
Write-Host ('-' * 64)

if ($result -match 'IMPORTS OK') {
    Write-Host 'READY. SYSTEM can run Python and import everything.' -ForegroundColor Green
    Write-Host 'The print server will start at boot.'
} elseif ($result -match 'Python \d') {
    Write-Host 'PARTLY. SYSTEM runs Python but cannot import the packages.' -ForegroundColor Yellow
    Write-Host 'pip installed them into a per-user location. Fix, elevated:'
    Write-Host '    cd ..\print-server'
    Write-Host '    py -m pip install -r requirements.txt'
} else {
    Write-Host 'NOT READY. SYSTEM cannot run Python.' -ForegroundColor Red
    Write-Host 'Install from python.org (the "Windows installer (64-bit)" file, not'
    Write-Host 'the Install Manager), run it as administrator, choose Customize'
    Write-Host 'installation and tick "Install for all users". Then switch off the'
    Write-Host 'Store aliases: Settings > Apps > Advanced app settings > App'
    Write-Host 'execution aliases > python.exe and python3.exe off.'
}
Write-Host ''
