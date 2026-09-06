<#
.SYNOPSIS
    Tails the print server's log, live.

.DESCRIPTION
    The print server runs as a scheduled task with no visible console, so the
    log file is the only way to see what it's doing -- including the iPad's
    own camera/capture diagnostics, which the booth page forwards here over
    POST /log so they don't require a Mac and a cable to read.

    Asks the running server where its data directory actually is (falling
    back to PHOTOBOOTH_DATA_DIR, then C:\PhotoBooth) rather than assuming the
    default, so a customised install is still found.

.PARAMETER Lines
    How many existing lines to show before following new ones as they are
    written. Default 50.

.EXAMPLE
    .\logs.ps1
    .\logs.ps1 -Lines 200
#>
param(
    [int]$Lines = 50
)
$ErrorActionPreference = 'SilentlyContinue'

$dataDir = $null
try {
    $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:5000/status' -UseBasicParsing -TimeoutSec 5
    $dataDir = ($resp.Content | ConvertFrom-Json).data_dir
} catch {}

if (-not $dataDir) { $dataDir = [Environment]::GetEnvironmentVariable('PHOTOBOOTH_DATA_DIR', 'Machine') }
if (-not $dataDir) { $dataDir = 'C:\PhotoBooth' }

$logFile = Join-Path $dataDir 'logs\print_server.log'

if (-not (Test-Path $logFile)) {
    Write-Host "No log file at $logFile -- is the print server running? Try .\status.ps1" -ForegroundColor Red
    exit 1
}

Write-Host "Watching $logFile (Ctrl+C to stop)" -ForegroundColor Cyan
Write-Host ('-' * 68)
Get-Content -Path $logFile -Tail $Lines -Wait
