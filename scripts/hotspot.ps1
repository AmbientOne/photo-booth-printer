<#
.SYNOPSIS
    Turn the mini PC's Wi-Fi access point on. Safe to run repeatedly.

.DESCRIPTION
    The booth runs on its own network so it never depends on venue Wi-Fi.
    Windows Mobile Hotspot always gives the host machine 192.168.137.1, which
    is why the print server's certificate can be pinned to that address once
    and never regenerated.

    Windows does NOT remember the hotspot across a reboot, so a scheduled task
    runs this script at every logon. It exits 0 if the hotspot is already on,
    which is what makes "just restart it" a safe instruction for the operator.

    Run with -Check to test support without changing anything.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$Ssid,
    [string]$Passphrase
)

$ErrorActionPreference = 'Stop'

# --- WinRT plumbing --------------------------------------------------------
# The tethering API is WinRT and returns IAsyncOperation, which Windows
# PowerShell 5.1 cannot await natively. This is the standard shim.
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

# ConfigureAccessPointAsync returns IAsyncAction, which carries no result and
# so needs the non-generic AsTask overload. Passing it to Await above throws a
# type-conversion error -- and because this script stops on any error, that
# aborted it before it ever started tethering.
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
})[0]

function AwaitAction($WinRtAction) {
    $netTask = $asTaskAction.Invoke($null, @($WinRtAction))
    $netTask.Wait(-1) | Out-Null
}

function Get-TetheringManager {
    $ni = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]

    # Preferred: the profile Windows considers internet-bearing.
    $profile = $ni::GetInternetConnectionProfile()

    if ($null -eq $profile) {
        # No internet (very likely at a venue -- the mini PC may be offline).
        # Any adapter with a live link is enough to hang a hotspot off.
        $profile = $ni::GetConnectionProfiles() |
            Where-Object { $_.GetNetworkConnectivityLevel() -ne 'None' } |
            Select-Object -First 1
    }

    if ($null -eq $profile) { return $null }

    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::CreateFromConnectionProfile($profile)
}

# --- report ----------------------------------------------------------------

$mgr = Get-TetheringManager

if ($null -eq $mgr) {
    Write-Warning 'No usable network profile, so the hotspot cannot start.'
    Write-Warning 'Plug in ethernet, or connect Wi-Fi to any network, then rerun.'
    exit 2
}

Write-Host ("Hotspot state : {0}" -f $mgr.TetheringOperationalState)
Write-Host ("Client limit  : {0}" -f $mgr.MaxClientCount)
# Reporting only -- on some adapters this throws (0x83120006 when the profile
# cannot tether). Never let it abort before the start attempt, which produces a
# far more useful error.
$ap = $null
try {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
} catch {
    Write-Warning ("Could not read the access point configuration: {0}" -f $_.Exception.Message)
}
Write-Host ("SSID          : {0}" -f $(if ($ap) { $ap.Ssid } else { '(unavailable)' }))

if ($Check) {
    Write-Host ''
    Write-Host 'Check only -- nothing changed.'
    exit 0
}

# --- optionally rename the network -----------------------------------------

if ($Ssid -or $Passphrase) {
    if ($Passphrase -and $Passphrase.Length -lt 8) {
        throw 'WPA2 passphrases must be at least 8 characters.'
    }
    if ($null -eq $ap) { throw 'Cannot change the SSID: this adapter would not report its access point configuration.' }
    if ($Ssid) { $ap.Ssid = $Ssid }
    if ($Passphrase) { $ap.Passphrase = $Passphrase }
    AwaitAction ($mgr.ConfigureAccessPointAsync($ap))
    Write-Host ("Reconfigured to SSID '{0}'." -f $ap.Ssid)
}

# --- start -----------------------------------------------------------------

if ($mgr.TetheringOperationalState -eq 'On') {
    Write-Host 'Already on -- nothing to do.'
    exit 0
}

$result = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])

if ($result.Status -eq 'Success') {
    Write-Host 'Hotspot started. This machine is 192.168.137.1'
    exit 0
}

Write-Warning ("Could not start the hotspot: {0}" -f $result.Status)
if ($result.AdditionalErrorMessage) { Write-Warning $result.AdditionalErrorMessage }
exit 3
