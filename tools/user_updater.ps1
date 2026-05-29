# tools/user_updater.ps1
#
# Run periodically (Windows Task Scheduler) to pull the latest
# Notepad++ build from our fork's GitHub Releases and install it
# in place of the user's existing notepad++.exe.
#
# - Checks the most recent Release tag on Gdocal/notepad-plus-plus.
# - Skips if the local installed exe is already at that tag.
# - Refuses to update while NPP is running (will retry on the next
#   scheduled tick).
# - Always backs up the existing exe before replacing.
# - Logs every run to %TEMP%\npp_updater.log so failures are
#   diagnosable after the fact.

param(
    [string]$ForkOwner = 'Gdocal',
    [string]$ForkRepo = 'notepad-plus-plus',
    [string]$InstallExe = "$env:ProgramFiles\Notepad++\notepad++.exe",
    [string]$LogFile = "$env:TEMP\npp_updater.log"
)

$ErrorActionPreference = 'Continue'

function Log($msg) {
    $line = "[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $msg
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

try {
    Log "=== updater run starting ==="

    if (-not (Test-Path $InstallExe)) { Log "Install exe missing: $InstallExe"; return }

    # Don't fight with the user.
    $running = Get-Process notepad++ -ErrorAction SilentlyContinue
    if ($running) {
        Log "NPP currently running (PIDs $($running.Id -join ',')); skipping this tick"
        return
    }

    # Fetch the latest release from GitHub.
    $api = "https://api.github.com/repos/$ForkOwner/$ForkRepo/releases/latest"
    $headers = @{ 'User-Agent' = 'npp-lazy-updater' }
    $release = Invoke-RestMethod -Uri $api -Headers $headers -ErrorAction Stop
    $tag = $release.tag_name
    Log "Latest release tag on fork: $tag"

    # Map the local installed exe to a release tag via the
    # %ProgramFiles%\Notepad++\npp_lazy_installed.tag file written by
    # this script after a successful install.
    $tagFile = Join-Path (Split-Path $InstallExe) 'npp_lazy_installed.tag'
    $currentTag = if (Test-Path $tagFile) { (Get-Content $tagFile -Raw).Trim() } else { '' }
    Log "Currently installed tag: '$currentTag'"

    if ($currentTag -eq $tag) {
        Log "Already up to date. Done."
        return
    }

    $asset = $release.assets | Where-Object { $_.name -eq 'notepad++.exe' } | Select-Object -First 1
    if (-not $asset) {
        Log "Release $tag has no notepad++.exe asset; skipping"
        return
    }

    $tmp = Join-Path $env:TEMP "npp_lazy_$tag.exe"
    Log "Downloading $($asset.browser_download_url) -> $tmp"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -Headers $headers -ErrorAction Stop

    if ((Get-Item $tmp).Length -lt 1MB) {
        Log "Downloaded exe is too small ($((Get-Item $tmp).Length) bytes); aborting"
        Remove-Item $tmp -Force
        return
    }

    # Re-check NPP isn't running just before the swap.
    $running = Get-Process notepad++ -ErrorAction SilentlyContinue
    if ($running) { Log "NPP started running during download; aborting"; return }

    # Back up, then replace. Backups live in LOCALAPPDATA — Program
    # Files is read-only without elevation.
    $backupDir = "$env:LOCALAPPDATA\NppLazyFork\backups"
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = Join-Path $backupDir "notepad++_$stamp.exe"
    Copy-Item $InstallExe $backupPath -Force
    Log "Backup: $backupPath"

    try {
        Copy-Item $tmp $InstallExe -Force
        Set-Content -Path $tagFile -Value $tag -Encoding utf8
        Log "Installed $tag"
    } catch {
        Log "Install failed: $_. Restoring backup."
        Copy-Item $backupPath $InstallExe -Force
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    Log "=== updater run done ==="
} catch {
    Log "ERROR: $_"
}
