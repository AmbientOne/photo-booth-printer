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
# The server answers 503 when the hot folder is not ready. That is a reply,
# not silence -- Invoke-RestMethod throws on it, which made a degraded booth
# look identical to a dead one.
$body = $null
$httpCode = 0
try {
    $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:5000/status' -UseBasicParsing -TimeoutSec 5
    $httpCode = [int]$resp.StatusCode
    $body = $resp.Content | ConvertFrom-Json
} catch {
    $r = $_.Exception.Response
    if ($r) {
        $httpCode = [int]$r.StatusCode
        try {
            $reader = New-Object System.IO.StreamReader($r.GetResponseStream())
            $body = $reader.ReadToEnd() | ConvertFrom-Json
            $reader.Close()
        } catch {}
    }
}

# Fall back to what the installer recorded rather than the hotspot address --
# on a router setup 192.168.137.1 is simply the wrong guess.
$configured = [Environment]::GetEnvironmentVariable('PHOTOBOOTH_ADVERTISED_IP', 'Machine')
if ($body -and $body.advertised_ip) { $addr = $body.advertised_ip }
elseif ($configured)                { $addr = $configured }
else                                { $addr = '192.168.137.1' }

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
    # 267009 SCHED_S_TASK_RUNNING and 267011 SCHED_S_TASK_HAS_NOT_RUN are
    # informational. The print server is meant to run forever, so 267009 is
    # exactly what a healthy task looks like.
    $goodResults = @(0, 267009, 267011)
    $ok = $t.State -ne 'Disabled' -and
          ($null -eq $info.LastTaskResult -or $goodResults -contains $info.LastTaskResult)
    $detail = "state={0} lastResult={1}" -f $t.State, $info.LastTaskResult
    if ($info.LastTaskResult -eq 267009) { $detail += " (running)" }
    Line $t.TaskName $ok $detail
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
} elseif ($httpCode -ne 0) {
    Line 'Print server' $false ("answered HTTP {0} but the reply could not be read" -f $httpCode)
} else {
    Line 'Print server' $false 'not responding on port 5000 -> restart the computer'
}

# --- what to open on the iPad ---------------------------------------------
Write-Host ''
Write-Host 'Booth URL for the iPad:' -ForegroundColor Cyan
Write-Host "  https://${addr}:5443/booth"
Write-Host 'Certificate, first time only (accept the warning):' -ForegroundColor Cyan
Write-Host "  https://${addr}:5443/cert"
Write-Host ''
