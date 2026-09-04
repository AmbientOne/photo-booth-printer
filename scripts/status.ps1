<#
.SYNOPSIS
    One-screen answer to "is the booth working?"

.DESCRIPTION
    Safe to run any time; changes nothing. Every line is either OK or tells you
    what to do about it. Intended for whoever is helping over the phone -- the
    operator on site only ever needs to restart the machine.
#>
$ErrorActionPreference = 'SilentlyContinue'

function Line($label, $ok, $detail) {
    $mark = if ($ok) { '  OK  ' } else { ' FAIL ' }
    $col = if ($ok) { 'Green' } else { 'Red' }
    Write-Host $mark -ForegroundColor $col -NoNewline
    Write-Host (' {0,-22} {1}' -f $label, $detail)
}

Write-Host ''
Write-Host 'Photo Booth status' -ForegroundColor Cyan
Write-Host ('-' * 62)

# --- the access point ------------------------------------------------------
$apIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -eq '192.168.137.1' }).IPAddress
Line 'Hotspot' ($null -ne $apIp) $(
    if ($apIp) { 'up, this machine is 192.168.137.1' }
    else { 'down -> run: .\hotspot.ps1' })

# --- the two scheduled tasks ----------------------------------------------
foreach ($name in 'PhotoBooth Hotspot', 'PhotoBooth Print Server') {
    $t = Get-ScheduledTask -TaskName $name
    Line $name ($null -ne $t -and $t.State -ne 'Disabled') $(
        if ($t) { "state=$($t.State)" } else { 'not registered -> run: .\install.ps1' })
}

# --- automatic logon, the thing that makes a restart sufficient ------------
$auto = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon
Line 'Auto logon' ($auto -eq '1') $(
    if ($auto -eq '1') { 'on -- boots straight to the desktop' }
    else { 'off -- someone must log in after a power cut' })

# --- listeners -------------------------------------------------------------
foreach ($port in 5000, 5443) {
    $listening = Get-NetTCPConnection -LocalPort $port -State Listen
    Line "Port $port" ($null -ne $listening) $(
        if ($listening) { 'listening' } else { 'nothing listening' })
}

# --- the server's own opinion ---------------------------------------------
$body = $null
try {
    $body = Invoke-RestMethod -Uri 'http://127.0.0.1:5000/status' -TimeoutSec 4
} catch {}

if ($body) {
    Line 'Print server' ($body.status -eq 'ready') "status=$($body.status)"
    Line 'DNP hot folder' ([bool]$body.hot_folder_ready) $body.hot_folder
    Line 'HTTPS (camera)' ([bool]$body.https_ready) $(
        if ($body.https_ready) { 'certificate loaded' }
        else { 'no cert -> run: py ..\print-server\make_cert.py' })
    Write-Host ''
    Write-Host ('  Prints this install : {0}' -f $body.prints_this_install)
    Write-Host ('  Queued at printer   : {0}' -f $body.queued_in_hot_folder)
    Write-Host ('  Uptime              : {0} min' -f [int]($body.uptime_seconds / 60))
} else {
    Line 'Print server' $false 'not responding -> restart the computer'
}

# --- what to type into the iPad -------------------------------------------
$tokenFile = 'C:\PhotoBooth\token.txt'
if (Test-Path $tokenFile) {
    $token = (Get-Content $tokenFile -Raw).Trim()
    Write-Host ''
    Write-Host 'Booth URL for the iPad:' -ForegroundColor Cyan
    Write-Host "  https://192.168.137.1:5443/booth?k=$token"
    Write-Host 'Certificate (first time only):' -ForegroundColor Cyan
    Write-Host '  http://192.168.137.1:5000/cert'
}
Write-Host ''
