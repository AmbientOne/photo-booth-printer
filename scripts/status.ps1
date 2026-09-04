<#
.SYNOPSIS
    One-screen answer to "is the booth working?"

.DESCRIPTION
    Safe to run any time; changes nothing. Works for both setups and tells you
    which one it found:

      hotspot mode  install.ps1        this PC hosts the Wi-Fi
      router mode   install-router.ps1 a travel router hosts it

    Every line is either OK or says what to do about it. Intended for whoever
    is helping over the phone; the operator on site only ever restarts.
#>
$ErrorActionPreference = 'SilentlyContinue'

function Line($label, $ok, $detail) {
    $mark = if ($ok) { '  OK  ' } else { ' FAIL ' }
    $col = if ($ok) { 'Green' } else { 'Red' }
    Write-Host $mark -ForegroundColor $col -NoNewline
    Write-Host (' {0,-22} {1}' -f $label, $detail)
}
function Note($label, $detail) {
    Write-Host '      ' -NoNewline
    Write-Host (' {0,-22} {1}' -f $label, $detail) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Photo Booth status' -ForegroundColor Cyan
Write-Host ('-' * 68)

# --- which setup is this? -------------------------------------------------
$hotspotTask = Get-ScheduledTask -TaskName 'PhotoBooth Hotspot' -ErrorAction SilentlyContinue
$serverTask  = Get-ScheduledTask -TaskName 'PhotoBooth Print Server' -ErrorAction SilentlyContinue
$hotspotMode = $null -ne $hotspotTask

if ($hotspotMode) { Note 'Setup' 'hotspot -- this PC hosts the Wi-Fi' }
elseif ($serverTask) { Note 'Setup' 'router -- a travel router hosts the Wi-Fi' }
else { Note 'Setup' 'not installed -- run install.ps1 or install-router.ps1' }

# --- ask the server where it thinks it is ---------------------------------
$body = $null
try { $body = Invoke-RestMethod -Uri 'http://127.0.0.1:5000/status' -TimeoutSec 4 } catch {}
$addr = if ($body -and $body.advertised_ip) { $body.advertised_ip } else { '192.168.137.1' }

# --- the network ----------------------------------------------------------
if ($hotspotMode) {
    $apIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq '192.168.137.1' }).IPAddress
    Line 'Hotspot' ($null -ne $apIp) $(
        if ($apIp) { 'up, this machine is 192.168.137.1' }
        else { 'down -> run: .\hotspot.ps1  (needs an upstream connection)' })
} else {
    $has = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $addr }).IPAddress
    Line 'Address' ($null -ne $has) $(
        if ($has) { "$addr held on this machine" }
        else { "$addr NOT held -- check the cable and the DHCP reservation" })
}

# --- scheduled tasks ------------------------------------------------------
foreach ($t in @($hotspotTask, $serverTask)) {
    if ($null -eq $t) { continue }
    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
    $ok = $t.State -ne 'Disabled' -and ($info.LastTaskResult -eq 0 -or $null -eq $info.LastTaskResult)
    Line $t.TaskName $ok ("state={0} lastResult={1}" -f $t.State, $info.LastTaskResult)
}
if (-not $serverTask) { Line 'Print server task' $false 'not registered' }

# --- auto logon -----------------------------------------------------------
$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$autoOn = $wl.AutoAdminLogon -eq '1'
if ($hotspotMode) {
    Line 'Auto logon' $autoOn $(
        if ($autoOn) { 'on -- boots straight to the desktop' }
        else { 'off -- nothing starts until someone logs in' })
} else {
    # In router mode the server runs as SYSTEM at boot, so auto logon only
    # matters for Hot Folder Print, which is a desktop app.
    Note 'Auto logon' $(if ($autoOn) { 'on (needed for Hot Folder Print)' } else { 'off -- Hot Folder Print will not start unattended' })
}
if ($null -ne $wl.AutoLogonCount) {
    Line 'Auto logon countdown' $false ("AutoLogonCount={0} -- auto logon stops after that many boots. Rerun the installer" -f $wl.AutoLogonCount)
}

# --- listeners ------------------------------------------------------------
foreach ($port in 5000, 5443) {
    $listening = Get-NetTCPConnection -LocalPort $port -State Listen
    Line "Port $port" ($null -ne $listening) $(if ($listening) { 'listening' } else { 'nothing listening' })
}

# --- DNP Hot Folder Print -------------------------------------------------
# The server only drops files in a folder. Without HFP running, nothing prints
# and nothing complains -- so check it explicitly.
$hfp = Get-Process | Where-Object { $_.ProcessName -match 'HotFolder|HFP' }
Line 'Hot Folder Print' ($null -ne $hfp) $(
    if ($hfp) { "running (pid $($hfp[0].Id))" }
    else { 'NOT running -- files will queue but nothing will print' })

# --- the server's own opinion ---------------------------------------------
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

# --- what to open on the iPad ---------------------------------------------
Write-Host ''
Write-Host 'Booth URL for the iPad:' -ForegroundColor Cyan
Write-Host "  https://${addr}:5443/booth"
Write-Host 'Certificate, first time only (accept the warning):' -ForegroundColor Cyan
Write-Host "  https://${addr}:5443/cert"
Write-Host ''
