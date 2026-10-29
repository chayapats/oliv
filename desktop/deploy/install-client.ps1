#Requires -Version 5.1
<#
.SYNOPSIS
Install an already-built OLIV Windows client for the current user.
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-client.ps1
.EXAMPLE
.\desktop\deploy\install-client.ps1 -BinaryPath .\desktop\target\x86_64-pc-windows-msvc\release\oliv.exe -NoStart
#>
[CmdletBinding()]
param(
    [string]$BinaryPath,
    [string]$InstallDir,
    [switch]$NoStart,
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }
if (-not $env:APPDATA -or -not $env:LOCALAPPDATA) { throw 'APPDATA and LOCALAPPDATA must be set.' }
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Oliv' }
$InstallDir = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir))

function Find-SourceFile([string[]]$Candidates, [string]$Description) {
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Cannot find $Description. Extract the complete release ZIP or build desktop/Cargo.toml first."
}

function Copy-IfDifferentPath([string]$Source, [string]$Destination) {
    if (-not [string]::Equals([IO.Path]::GetFullPath($Source), [IO.Path]::GetFullPath($Destination), [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Set-PrivateAcl([string]$Path, [switch]$Directory) {
    # Only this user and SYSTEM inherit access to new config/history/recordings.
    $acl = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() }
        else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($identity in @($sid, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if ($BinaryPath) {
    $sourceExe = Find-SourceFile @($BinaryPath) 'oliv.exe'
} else {
    $sourceExe = Find-SourceFile @(
        (Join-Path $PSScriptRoot 'oliv.exe'),
        (Join-Path $PSScriptRoot '..\target\release\oliv.exe'),
        (Join-Path $PSScriptRoot '..\target\x86_64-pc-windows-msvc\release\oliv.exe')
    ) 'oliv.exe'
}
$example = Find-SourceFile @(
    (Join-Path $PSScriptRoot 'config.example.toml'),
    (Join-Path $PSScriptRoot '..\config.example.toml')
) 'config.example.toml'
$uninstaller = Find-SourceFile @((Join-Path $PSScriptRoot 'uninstall-client.ps1')) 'uninstall-client.ps1'
$destinationExe = Join-Path $InstallDir 'oliv.exe'
$launcher = Join-Path $InstallDir 'start-oliv.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'OlivWindows'
$runCommand = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershell, $launcher
if (-not $NoAutoStart) {
    $oldRun = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run', $runName, $null)
    if ($oldRun -and $oldRun -ne $runCommand) {
        throw "The $runName startup entry belongs to another installation. Uninstall that installation before changing InstallDir."
    }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
# Never kill another checkout or an unrelated program with the same process name.
foreach ($running in @(Get-Process -Name 'oliv' -ErrorAction SilentlyContinue)) {
    try { $runningPath = $running.Path } catch { continue }
    if ($runningPath -and [string]::Equals($runningPath, $destinationExe, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Process -InputObject $running -Force
        $running.WaitForExit()
    }
}
Copy-IfDifferentPath $sourceExe $destinationExe
Copy-IfDifferentPath $uninstaller (Join-Path $InstallDir 'uninstall-client.ps1')
Copy-IfDifferentPath $example (Join-Path $InstallDir 'config.example.toml')

$configDir = Join-Path $env:APPDATA 'oliv'
$dataDir = Join-Path $env:LOCALAPPDATA 'oliv'
foreach ($dir in @($configDir, $dataDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-PrivateAcl -Path $dir -Directory
}
$config = Join-Path $configDir 'config.toml'
$newConfig = -not (Test-Path -LiteralPath $config)
if ($newConfig) {
    # No credentials are downloaded, logged, embedded, or requested on the CLI.
    Copy-Item -LiteralPath $example -Destination $config
}
# An existing file can have a protected, broadly readable ACL of its own.
# Securing only its parent would leave that token accessible to other users.
Set-PrivateAcl -Path $config

# Windows PowerShell ships with Windows; this does not require VBScript.
# A literal here-string also keeps user-specific paths out of executable code.
$launcherText = @'
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$executable = Join-Path $PSScriptRoot 'oliv.exe'
foreach ($running in @(Get-CimInstance Win32_Process -Filter "Name = 'oliv.exe'")) {
    # `retry` can run for a long time; it must not prevent the daemon starting.
    # Match the complete CLI, accounting for a quoted executable path/argument.
    if ($running.ExecutablePath -and
        [string]::Equals($running.ExecutablePath, $executable, [StringComparison]::OrdinalIgnoreCase) -and
        $running.CommandLine -match '^\s*(?:"[^"]*"|\S+)\s+(?:"daemon"|daemon)\s*$') {
        return
    }
}
$dataDir = Join-Path $env:LOCALAPPDATA 'oliv'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$daemon = Start-Process -FilePath $executable -ArgumentList 'daemon' -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $dataDir 'daemon.stdout.log') `
    -RedirectStandardError (Join-Path $dataDir 'daemon.stderr.log')
try {
    $null = $daemon.Handle
    if ($daemon.WaitForExit(1000)) {
        throw "OLIV daemon exited during startup (code $($daemon.ExitCode)). Check $(Join-Path $dataDir 'daemon.stderr.log')."
    }
} finally {
    $daemon.Dispose()
}
'@
[IO.File]::WriteAllText($launcher, $launcherText, (New-Object Text.UTF8Encoding($false)))
if (-not $NoAutoStart) {
    if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $runKey -Name $runName -Value $runCommand -PropertyType String -Force | Out-Null
}

Write-Host "Installed: $destinationExe"
Write-Host "Config (preserved if already present): $config"
Write-Host "History, pending recordings, and logs: $dataDir"
if ($newConfig) {
    Write-Host 'Before first use, edit config.toml with the HTTPS API URL and per-device token from your API operator.'
    Write-Host "Then start OLIV with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
} elseif (-not $NoStart) {
    & $launcher
    Write-Host 'OLIV started. Hold Right Shift to record; release to dictate; Escape cancels.'
}
if ($NoAutoStart) { Write-Host 'Startup entry was left unchanged (-NoAutoStart).' }
else { Write-Host 'OLIV will start hidden when this user next signs in.' }
