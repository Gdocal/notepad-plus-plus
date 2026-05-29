# tools/install_to_npp.ps1
#
# Installs the freshly-built notepad++.exe into the user's NPP
# installation. Backs up the previous exe with a timestamp suffix so
# the user can always roll back.
#
# - Never touches config.xml, session.xml, themes, plugins, or
#   anything in %APPDATA%\Notepad++.
# - Refuses to overwrite if the build exe is missing or unreadable.
# - Refuses to overwrite if NPP is currently running (asks user to
#   close it first).

param(
    [string]$BuildExe = "$PSScriptRoot\..\PowerEditor\bin64\notepad++.exe",
    [string]$InstallExe = "$env:ProgramFiles\Notepad++\notepad++.exe"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BuildExe)) { throw "Build artifact missing: $BuildExe" }
if (-not (Test-Path $InstallExe)) { throw "Installed NPP not found at $InstallExe — pass -InstallExe with the right path" }

$running = Get-Process notepad++ -ErrorAction SilentlyContinue
if ($running) {
    throw ("Notepad++ is currently running (PID " + ($running.Id -join ', ') + "). Close it first.")
}

# Backups live alongside our build, NOT in Program Files (which is
# usually read-only without elevation).
$backupDir = "$env:LOCALAPPDATA\NppLazyFork\backups"
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = Join-Path $backupDir "notepad++_$stamp.exe"
Copy-Item $InstallExe $backupPath -Force
Write-Output "Backed up old exe to: $backupPath"

try {
    Copy-Item $BuildExe $InstallExe -Force
    Write-Output "Installed new exe at: $InstallExe"
} catch {
    Write-Error "Install failed: $_. Restoring backup."
    Copy-Item $backupPath $InstallExe -Force
    throw
}

# Sanity: verify file size is reasonable (not 0-byte).
$newSize = (Get-Item $InstallExe).Length
if ($newSize -lt 1MB) {
    Copy-Item $backupPath $InstallExe -Force
    throw "New exe is suspiciously small ($newSize bytes); restored backup."
}

Write-Output "Done. Backups in: $backupDir"
