#Requires -Version 5.1
<#
.SYNOPSIS
Remove the current user's OLIV client. Config, history, and recordings are kept.
.EXAMPLE
.\uninstall-client.ps1
.EXAMPLE
.\uninstall-client.ps1 -RemoveUserData
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$RemoveUserData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This uninstaller requires Windows.' }
if (-not $env:APPDATA -or -not $env:LOCALAPPDATA) { throw 'APPDATA and LOCALAPPDATA must be set.' }
if (-not $InstallDir) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'start-oliv.ps1')) { $InstallDir = $PSScriptRoot }
    else { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Oliv' }
}
$InstallDir = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir))
$destinationExe = Join-Path $InstallDir 'oliv.exe'
$launcher = Join-Path $InstallDir 'start-oliv.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'OlivWindows'
$runCommand = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershell, $launcher
$oldRun = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run', $runName, $null)
if ($oldRun -eq $runCommand) {
    Remove-ItemProperty -LiteralPath $runKey -Name $runName
}

# Compare the complete executable path; never stop all processes named oliv.
foreach ($running in @(Get-Process -Name 'oliv' -ErrorAction SilentlyContinue)) {
    try { $runningPath = $running.Path } catch { continue }
    if ($runningPath -and [string]::Equals($runningPath, $destinationExe, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Process -InputObject $running -Force
        $running.WaitForExit()
    }
}
foreach ($name in @('oliv.exe', 'start-oliv.ps1', 'uninstall-client.ps1', 'config.example.toml')) {
    $file = Join-Path $InstallDir $name
    if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
}
if ((Test-Path -LiteralPath $InstallDir -PathType Container) -and
    @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -eq 0) {
    Remove-Item -LiteralPath $InstallDir
}
if ($RemoveUserData) {
    foreach ($dir in @((Join-Path $env:APPDATA 'oliv'), (Join-Path $env:LOCALAPPDATA 'oliv'))) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    Write-Host 'OLIV removed, including config, token, history, and pending recordings.'
} else {
    Write-Host 'OLIV removed. Config, token, history, and pending recordings were preserved.'
}
