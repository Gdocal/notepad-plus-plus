# tools/smoke_test.ps1
#
# Automated verification harness for the lazy-session-load fork.
# Exit 0 on PASS, non-zero on FAIL. Used both manually and by the
# weekly-sync CI. See CLAUDE.md §5 for what it checks.
#
# Usage:
#   pwsh tools/smoke_test.ps1                # uses ./test_lazy
#   pwsh tools/smoke_test.ps1 -SessionXml C:\path\to\session.xml

param(
    [string]$ExePath = "$PSScriptRoot\..\PowerEditor\bin64\notepad++.exe",
    [string]$SessionXml = "$env:APPDATA\Notepad++\session.xml",
    [string]$BackupDir = "$env:APPDATA\Notepad++\backup",
    [string]$TestDir = "$PSScriptRoot\..\test_lazy",
    [int]$InitMaxMs = 300,
    [int]$ResponsiveMaxMs = 1500,
    [int]$MaxStartupDialogs = 0,
    [int]$RunSeconds = 10
)

$ErrorActionPreference = 'Stop'

function Log($msg) { Write-Output "[smoke] $msg" }

if (-not (Test-Path $ExePath)) { throw "Build artifact missing: $ExePath" }
if (-not (Test-Path $SessionXml)) { throw "Session XML missing: $SessionXml" }

Log "Resetting test environment at $TestDir"
if (-not (Test-Path $TestDir)) { New-Item -ItemType Directory -Path $TestDir | Out-Null }
foreach ($leftover in 'session.xml', 'session.xml.bak') {
    Remove-Item (Join-Path $TestDir $leftover) -Force -ErrorAction SilentlyContinue
}

# Replace the portable exe with the build we are verifying.
Copy-Item $ExePath (Join-Path $TestDir 'notepad++.exe') -Force

# Copy session + backup directory. NEVER touch the user's originals.
Copy-Item $SessionXml (Join-Path $TestDir 'session.xml') -Force
$portableBackup = Join-Path $TestDir 'backup'
if (-not (Test-Path $portableBackup)) { New-Item -ItemType Directory -Path $portableBackup | Out-Null }
Get-ChildItem $portableBackup -File -ErrorAction SilentlyContinue | Remove-Item -Force
if (Test-Path $BackupDir) {
    Copy-Item (Join-Path $BackupDir '*') $portableBackup -Force -ErrorAction SilentlyContinue
}

# Portable marker + at least minimal config (must already exist from prior runs).
$cfg = Join-Path $TestDir 'config.xml'
if (-not (Test-Path $cfg)) { throw "Portable config.xml missing in $TestDir; run NPP there once with -nosession to bootstrap." }
$cfgText = Get-Content $cfg -Raw
if (-not ($cfgText -match 'LazySessionLoad')) {
    Log "Inserting LazySessionLoad=yes into portable config"
    $cfgText = $cfgText -replace '(</GUIConfigs>)', "        <GUIConfig name=`"LazySessionLoad`">yes</GUIConfig>`r`n    `$1"
} else {
    $cfgText = $cfgText -replace '<GUIConfig name="LazySessionLoad">no</GUIConfig>', '<GUIConfig name="LazySessionLoad">yes</GUIConfig>'
}
Set-Content $cfg -Value $cfgText -Encoding utf8

# Record pre-test session entry count for the post-test integrity check.
[xml]$preXml = Get-Content (Join-Path $TestDir 'session.xml')
$preMain = @($preXml.NotepadPlus.Session.mainView.File).Count
$preSub  = @($preXml.NotepadPlus.Session.subView.File).Count
$preTotal = $preMain + $preSub
Log "Pre-test session: main=$preMain sub=$preSub total=$preTotal"

# Kill any lingering Notepad++.
Get-Process notepad++ -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1

# Native helpers: SendMessageTimeout to detect "not responding", dialog enumeration.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Smoke {
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    [DllImport("user32.dll")] public static extern uint SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@

$initLogPath = Join-Path $env:TEMP 'npp_startup.log'
Remove-Item $initLogPath -ErrorAction SilentlyContinue

$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath (Join-Path $TestDir 'notepad++.exe') -ArgumentList '-multiInst' -PassThru

# Poll for responsiveness + count dialogs.
$samples = New-Object System.Collections.Generic.List[object]
$startupDialogIds = New-Object System.Collections.Generic.HashSet[long]
$sustainStart = $null; $sustainAt = $null
while ($sw.Elapsed.TotalSeconds -lt $RunSeconds) {
    $proc.Refresh()
    $t = [int]$sw.ElapsedMilliseconds
    $ok = $false
    if ($proc.MainWindowHandle -ne 0) {
        $r = [IntPtr]::Zero
        $rc = [Smoke]::SendMessageTimeoutW($proc.MainWindowHandle, 0, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 50, [ref]$r)
        $ok = ($rc -ne [IntPtr]::Zero)
    }
    $samples.Add(@{ms=$t; ok=$ok})
    if ($null -eq $sustainStart -and $ok) { $sustainStart = $t }
    elseif (-not $ok) { $sustainStart = $null }
    elseif ($null -eq $sustainAt -and ($t - $sustainStart) -ge 800) { $sustainAt = $sustainStart }

    # Auto-dismiss any modal dialog so we can count it without blocking the run.
    $dlg = [Smoke]::FindWindowW('#32770', $null)
    while ($dlg -ne [IntPtr]::Zero) {
        $id = [long]$dlg.ToInt64()
        if ($startupDialogIds.Add($id)) {
            Log "  Startup dialog at +${t}ms (hwnd=$id)"
        }
        # Prefer "No" button (IDNO = 7); fall back to closing the dialog.
        $btn = [Smoke]::GetDlgItem($dlg, 7)
        if ($btn -ne [IntPtr]::Zero) {
            [Smoke]::SendMessageW($btn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        } else {
            [Smoke]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
        Start-Sleep -Milliseconds 50
        $dlg = [Smoke]::FindWindowW('#32770', $null)
    }
    Start-Sleep -Milliseconds 100
}

# Initiate clean close, count any close-time dialogs.
$closeDialogIds = New-Object System.Collections.Generic.HashSet[long]
[Smoke]::PostMessage($proc.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
$closeTimer = [Diagnostics.Stopwatch]::StartNew()
while (-not $proc.HasExited -and $closeTimer.Elapsed.TotalSeconds -lt 60) {
    $dlg = [Smoke]::FindWindowW('#32770', $null)
    while ($dlg -ne [IntPtr]::Zero) {
        $id = [long]$dlg.ToInt64()
        if ($closeDialogIds.Add($id)) {
            Log "  Close dialog (hwnd=$id)"
        }
        $btn = [Smoke]::GetDlgItem($dlg, 7)
        if ($btn -ne [IntPtr]::Zero) {
            [Smoke]::SendMessageW($btn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        } else {
            [Smoke]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
        Start-Sleep -Milliseconds 50
        $dlg = [Smoke]::FindWindowW('#32770', $null)
    }
    Start-Sleep -Milliseconds 200
    $proc.Refresh()
}
if (-not $proc.HasExited) {
    Log "Hard-killing stuck process"
    Stop-Process -Id $proc.Id -Force
}

# Read instrumentation timeline (only present if NPP was built with
# NPP_STARTUP_TRACE=1).
$initMs = $null
if (Test-Path $initLogPath) {
    $lines = Get-Content $initLogPath
    foreach ($line in $lines) {
        if ($line -match '^([0-9.]+)ms\s+after launchDocumentBackupTask') {
            $initMs = [double]$Matches[1]
            break
        }
    }
}

# Post-test integrity: session count preserved?
[xml]$postXml = Get-Content (Join-Path $TestDir 'session.xml')
$postMain = @($postXml.NotepadPlus.Session.mainView.File).Count
$postSub  = @($postXml.NotepadPlus.Session.subView.File).Count
$postTotal = $postMain + $postSub

# Evaluate verdicts.
$verdicts = @()
if ($null -ne $initMs) {
    $verdicts += if ($initMs -le $InitMaxMs) { @{name='init_ms'; pass=$true; val=$initMs} } else { @{name='init_ms'; pass=$false; val=$initMs} }
} else {
    Log "(init time not recorded — NPP_STARTUP_TRACE was off in this build; skipping init_ms check)"
}
if ($null -ne $sustainAt) {
    $verdicts += if ($sustainAt -le $ResponsiveMaxMs) { @{name='sustained_responsive_ms'; pass=$true; val=$sustainAt} } else { @{name='sustained_responsive_ms'; pass=$false; val=$sustainAt} }
} else {
    $verdicts += @{name='sustained_responsive_ms'; pass=$false; val='NEVER'}
}
$verdicts += if ($startupDialogIds.Count -le $MaxStartupDialogs) { @{name='startup_dialogs'; pass=$true; val=$startupDialogIds.Count} } else { @{name='startup_dialogs'; pass=$false; val=$startupDialogIds.Count} }
$verdicts += if ($postTotal -ge $preTotal) { @{name='session_integrity'; pass=$true; val="$preTotal -> $postTotal"} } else { @{name='session_integrity'; pass=$false; val="$preTotal -> $postTotal"} }

''
'================ smoke_test.ps1 verdict ================'
foreach ($v in $verdicts) {
    $tag = if ($v.pass) { 'PASS' } else { 'FAIL' }
    "  [$tag] $($v.name) = $($v.val)"
}
'  Startup-time dialogs dismissed: ' + $startupDialogIds.Count
'  Close-time dialogs dismissed:   ' + $closeDialogIds.Count
'  Total smoke run:                ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's'
''
$anyFail = $verdicts | Where-Object { -not $_.pass }
if ($anyFail) { exit 1 } else { exit 0 }
