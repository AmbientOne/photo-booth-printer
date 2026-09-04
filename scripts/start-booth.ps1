<#
.SYNOPSIS
    Start the photo booth. Double-click the desktop shortcut; this is it.

.DESCRIPTION
    Written for someone non-technical: it brings up the Wi-Fi and the print
    server, checks both actually work, and says in plain words whether the
    booth is ready. No arguments, no output to interpret.

    Closing the window stops the booth.
#>
param([switch]$NoWait)   # -NoWait: skip the keypress loop (for testing)

$ErrorActionPreference = 'Continue'
$Here      = $PSScriptRoot
$ServerDir = Join-Path (Split-Path -Parent $Here) 'print-server'
$AP_IP     = '192.168.137.1'

function Pause-Safely($prompt) {
    # ReadKey throws when there is no interactive console. Never let that turn
    # into a spinning loop -- just hold the window open instead.
    Write-Host $prompt -ForegroundColor DarkGray
    try {
        return $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Start-Sleep -Seconds 3600
        return $null
    }
}

function Banner($text, $colour) {
    Write-Host ''
    Write-Host ('  ' + ('=' * 56)) -ForegroundColor $colour
    foreach ($line in $text) { Write-Host ('   ' + $line) -ForegroundColor $colour }
    Write-Host ('  ' + ('=' * 56)) -ForegroundColor $colour
    Write-Host ''
}

Clear-Host
Write-Host ''
Write-Host '   Starting the photo booth...' -ForegroundColor Cyan
Write-Host ''

# --- 1. Wi-Fi --------------------------------------------------------------
Write-Host '   [1/3] Turning on the booth Wi-Fi...' -NoNewline
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Here 'hotspot.ps1') *> $null

$deadline = (Get-Date).AddSeconds(25)
$wifiUp = $false
while ((Get-Date) -lt $deadline) {
    if (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
            Where-Object { $_.IPAddress -eq $AP_IP }) { $wifiUp = $true; break }
    Start-Sleep -Milliseconds 500
}

if (-not $wifiUp) {
    Write-Host ' FAILED' -ForegroundColor Red
    Banner @(
        'THE BOOTH WI-FI DID NOT START',
        '',
        'Make sure this laptop is connected to a Wi-Fi network or',
        'has a network cable plugged in -- Windows needs that before',
        'it will share its own network.',
        '',
        'Then close this window and start the booth again.'
    ) 'Red'
    $null = Pause-Safely '   Press any key to close...'
    exit 1
}
Write-Host ' done' -ForegroundColor Green

# --- 2. print server -------------------------------------------------------
Write-Host '   [2/3] Starting the print server...' -NoNewline

$already = Get-NetTCPConnection -LocalPort 5000 -State Listen -EA SilentlyContinue
$proc = $null
if ($already) {
    Write-Host ' already running' -ForegroundColor Yellow
} else {
    $py = (Get-Command py -EA SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command python -EA SilentlyContinue).Source }
    if (-not $py) {
        Write-Host ' FAILED' -ForegroundColor Red
        Banner @('PYTHON IS NOT INSTALLED', '', 'Call your technical contact.') 'Red'
        $null = Pause-Safely '   Press any key to close...'
        exit 1
    }
    $proc = Start-Process -FilePath $py -ArgumentList 'app.py' `
        -WorkingDirectory $ServerDir -WindowStyle Hidden -PassThru
    Write-Host ' done' -ForegroundColor Green
}

# --- 3. does it actually work? --------------------------------------------
Write-Host '   [3/3] Checking the printer...' -NoNewline

$status = $null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    try {
        $status = Invoke-RestMethod -Uri 'http://127.0.0.1:5000/status' -TimeoutSec 3
        break
    } catch { Start-Sleep -Milliseconds 750 }
}

if (-not $status) {
    Write-Host ' FAILED' -ForegroundColor Red
    Banner @(
        'THE PRINT SERVER DID NOT START',
        '',
        'Close this window, restart the laptop, and try again.'
    ) 'Red'
    if ($proc) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
    $null = Pause-Safely '   Press any key to close...'
    exit 1
}
Write-Host ' done' -ForegroundColor Green

# --- ready ----------------------------------------------------------------
if ($status.hot_folder_ready) {
    Banner @(
        'THE BOOTH IS READY',
        '',
        'On the iPad: tap the PhotoBooth icon and take a photo.',
        '',
        'Leave this window open. Closing it stops the booth.'
    ) 'Green'
} else {
    Banner @(
        'ALMOST -- THE PRINTER IS NOT READY',
        '',
        'Check the printer is switched on and has paper and ribbon,',
        'then close this window and start the booth again.',
        '',
        'Guests can still take photos, but nothing will print.'
    ) 'Yellow'
}

Write-Host ('   Photos printed so far : {0}' -f $status.prints_this_install) -ForegroundColor DarkGray
Write-Host ('   Booth address         : {0}' -f $AP_IP) -ForegroundColor DarkGray
Write-Host ''
Write-Host ''

if ($NoWait) { return }

while ($true) {
    $key = Pause-Safely '   Press Q to stop the booth, or just close this window.'
    if ($null -eq $key) { break }
    if ($key.Character -eq 'q' -or $key.Character -eq 'Q') { break }
}

Write-Host '   Stopping the booth...' -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like '*app.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
Write-Host '   Stopped.' -ForegroundColor Green
Start-Sleep -Seconds 1
