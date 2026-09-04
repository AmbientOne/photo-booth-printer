<#
.SYNOPSIS
    Put a "Start Photo Booth" icon on the Desktop. Run once. No admin needed.

.DESCRIPTION
    The shortcut launches start-booth.ps1 with an execution-policy bypass, so
    it works regardless of the machine's script settings, and opens a normal
    window the operator can read and close.
#>
$ErrorActionPreference = 'Stop'

$target  = Join-Path $PSScriptRoot 'start-booth.ps1'
if (-not (Test-Path $target)) { throw "Cannot find $target" }

$desktop = [Environment]::GetFolderPath('Desktop')
$link    = Join-Path $desktop 'Start Photo Booth.lnk'

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($link)
$sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$target`""
$sc.WorkingDirectory = $PSScriptRoot
$sc.Description      = 'Starts the photo booth Wi-Fi and print server.'
# imageres.dll #174 is the camera icon, so it reads as a photo booth on the desktop.
$sc.IconLocation     = "$env:SystemRoot\System32\imageres.dll,174"
$sc.Save()

Write-Host ''
Write-Host "  Created: $link" -ForegroundColor Green
Write-Host ''
Write-Host '  The operator double-clicks that and waits for the green box.'
Write-Host ''
