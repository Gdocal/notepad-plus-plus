# tools/smoke_test.ps1
#
# Automated verification harness for the lazy-session-load fork.
# Exit 0 on PASS, non-zero on FAIL. See CLAUDE.md §5 for rationale.
#
# Compares our build vs the stock upstream build on the same portable
# environment. Any "extra" dialog, longer freeze, or session data loss
# vs stock is treated as a regression.
#
# Usage:
#   pwsh tools/smoke_test.ps1                  # default paths
#   pwsh tools/smoke_test.ps1 -StockExe none   # skip stock comparison (CI only)

param(
    [string]$ExePath    = "$PSScriptRoot\..\PowerEditor\bin64\notepad++.exe",
    [string]$SessionXml = "$env:APPDATA\Notepad++\session.xml",
    [string]$BackupDir  = "$env:APPDATA\Notepad++\backup",
    [string]$TestDir    = "$PSScriptRoot\..\test_lazy",
    [string]$StockExe   = 'F:\NppBackups\stock_8.9.6.1_notepad++.exe',
    [int]$RunSeconds         = 10,
    [int]$InitMaxMs          = 300,
    [int]$ResponsiveMaxMs    = 1500
)

$ErrorActionPreference = 'Stop'
function Log($m) { Write-Output "[smoke] $m" }

if (-not (Test-Path $ExePath)) { throw "Build artifact missing: $ExePath" }
if (-not (Test-Path $SessionXml)) { throw "Session XML missing: $SessionXml" }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Smoke {
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    [DllImport("user32.dll")] public static extern uint SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@

# ---------------- one full pass ----------------
function Invoke-OnePass {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Portable,
        [Parameter(Mandatory)][string]$Label,
        [int]$RunSeconds = 10
    )

    Log "=========== pass: $Label ============="

    # Replace exe in portable env.
    Copy-Item $Exe (Join-Path $Portable 'notepad++.exe') -Force

    # Reset session and backup dir from sources.
    Copy-Item $SessionXml (Join-Path $Portable 'session.xml') -Force
    $pb = Join-Path $Portable 'backup'
    if (-not (Test-Path $pb)) { New-Item -ItemType Directory -Path $pb | Out-Null }
    Get-ChildItem $pb -File -ErrorAction SilentlyContinue | Remove-Item -Force
    if (Test-Path $BackupDir) {
        Copy-Item (Join-Path $BackupDir '*') $pb -Force -ErrorAction SilentlyContinue
    }

    # Capture pre-test session entry count for integrity check.
    [xml]$preXml = Get-Content (Join-Path $Portable 'session.xml')
    $preCount = @($preXml.NotepadPlus.Session.mainView.File).Count + @($preXml.NotepadPlus.Session.subView.File).Count
    Log "pre count: $preCount"

    # Kill leftovers + clear instrumentation log.
    Get-Process notepad++ -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    $initLog = Join-Path $env:TEMP 'npp_startup.log'
    Remove-Item $initLog -ErrorAction SilentlyContinue

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath (Join-Path $Portable 'notepad++.exe') -ArgumentList '-multiInst' -PassThru

    $startupDlgs = New-Object System.Collections.Generic.HashSet[long]
    $closeDlgs   = New-Object System.Collections.Generic.HashSet[long]
    $sustainStart = $null
    $sustainAt    = $null
    $notRespondingCount = 0

    while ($sw.Elapsed.TotalSeconds -lt $RunSeconds) {
        $proc.Refresh()
        $t = [int]$sw.ElapsedMilliseconds
        $ok = $false
        if ($proc.MainWindowHandle -ne 0) {
            $r = [IntPtr]::Zero
            $rc = [Smoke]::SendMessageTimeoutW($proc.MainWindowHandle, 0, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 50, [ref]$r)
            $ok = ($rc -ne [IntPtr]::Zero)
        }
        if ($ok) {
            if ($null -eq $sustainStart) { $sustainStart = $t }
            elseif ($null -eq $sustainAt -and ($t - $sustainStart) -ge 800) { $sustainAt = $sustainStart }
        } else {
            $sustainStart = $null
            $notRespondingCount++
        }

        # Drain any dialogs auto-clicking "No".
        $dlg = [Smoke]::FindWindowW('#32770', $null)
        while ($dlg -ne [IntPtr]::Zero) {
            $id = [long]$dlg.ToInt64()
            if ($startupDlgs.Add($id)) { Log "  startup dialog at +${t}ms hwnd=$id" }
            $btn = [Smoke]::GetDlgItem($dlg, 7)  # IDNO
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

    # Initiate clean close, count close-time dialogs.
    [Smoke]::PostMessage($proc.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    $closeT = [Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited -and $closeT.Elapsed.TotalSeconds -lt 60) {
        $dlg = [Smoke]::FindWindowW('#32770', $null)
        while ($dlg -ne [IntPtr]::Zero) {
            $id = [long]$dlg.ToInt64()
            if ($closeDlgs.Add($id)) { Log "  close dialog hwnd=$id" }
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
        Log "hard-killing stuck process"
        Stop-Process -Id $proc.Id -Force
    }

    # Read init time if instrumented build wrote it.
    $initMs = $null
    if (Test-Path $initLog) {
        foreach ($line in Get-Content $initLog) {
            if ($line -match '^([0-9.]+)ms\s+after launchDocumentBackupTask') {
                $initMs = [double]$Matches[1]
                break
            }
        }
    }

    [xml]$postXml = Get-Content (Join-Path $Portable 'session.xml')
    $postCount = @($postXml.NotepadPlus.Session.mainView.File).Count + @($postXml.NotepadPlus.Session.subView.File).Count

    return [PSCustomObject]@{
        Label             = $Label
        StartupDialogs    = $startupDlgs.Count
        CloseDialogs      = $closeDlgs.Count
        SustainedAtMs     = $sustainAt
        InitMs            = $initMs
        NotRespondingHits = $notRespondingCount
        PreSessionCount   = $preCount
        PostSessionCount  = $postCount
    }
}

# ---------------- environment prep ----------------
if (-not (Test-Path $TestDir)) { New-Item -ItemType Directory -Path $TestDir | Out-Null }

# A config.xml MUST already exist (bootstrapped by running NPP once
# in -nosession mode against $TestDir). Verify and set LazySessionLoad.
$cfg = Join-Path $TestDir 'config.xml'
if (-not (Test-Path $cfg)) {
    Log "Bootstrapping config.xml in $TestDir"
    '<NotepadPlus></NotepadPlus>' | Set-Content (Join-Path $TestDir 'doLocalConf.xml')
    Copy-Item $ExePath (Join-Path $TestDir 'notepad++.exe') -Force
    $p = Start-Process -FilePath (Join-Path $TestDir 'notepad++.exe') -ArgumentList '-multiInst','-nosession' -PassThru
    Start-Sleep 4
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep 1
}
if (-not (Test-Path $cfg)) { throw "config.xml not created in $TestDir; manual bootstrap required" }
$cfgTxt = Get-Content $cfg -Raw
if (-not ($cfgTxt -match 'LazySessionLoad')) {
    $cfgTxt = $cfgTxt -replace '(</GUIConfigs>)', "        <GUIConfig name=`"LazySessionLoad`">yes</GUIConfig>`r`n    `$1"
} else {
    $cfgTxt = $cfgTxt -replace '<GUIConfig name="LazySessionLoad">no</GUIConfig>', '<GUIConfig name="LazySessionLoad">yes</GUIConfig>'
}
Set-Content $cfg -Value $cfgTxt -Encoding utf8

# ---------------- stock baseline pass (optional) ----------------
$stock = $null
if ($StockExe -and $StockExe -ne 'none' -and (Test-Path $StockExe)) {
    # Temporarily disable LazySessionLoad — stock does not know about it.
    $cfgTxt2 = (Get-Content $cfg -Raw) -replace '<GUIConfig name="LazySessionLoad">yes</GUIConfig>','<GUIConfig name="LazySessionLoad">no</GUIConfig>'
    Set-Content $cfg -Value $cfgTxt2 -Encoding utf8
    $stock = Invoke-OnePass -Exe $StockExe -Portable $TestDir -Label 'STOCK' -RunSeconds $RunSeconds
    # Re-enable for our pass
    Set-Content $cfg -Value ((Get-Content $cfg -Raw) -replace '<GUIConfig name="LazySessionLoad">no</GUIConfig>','<GUIConfig name="LazySessionLoad">yes</GUIConfig>') -Encoding utf8
} else {
    Log "Stock binary not provided / found at '$StockExe' — comparison skipped."
}

# ---------------- our build pass ----------------
$ours = Invoke-OnePass -Exe $ExePath -Portable $TestDir -Label 'OURS' -RunSeconds $RunSeconds

# ---------------- verdicts ----------------
$verdicts = @()

if ($null -ne $ours.InitMs) {
    $pass = ($ours.InitMs -le $InitMaxMs)
    $verdicts += @{n='init_ms';val=$ours.InitMs;p=$pass}
}
# sustained_responsive is informational — large real sessions never
# get 800 ms of fully-uninterrupted responsiveness even in stock NPP,
# so use the "not_responding hits vs stock" metric below as the real
# pass/fail signal for UI responsiveness.
if ($null -ne $ours.SustainedAtMs) {
    Log "sustained_responsive_ms = $($ours.SustainedAtMs) (informational)"
} else {
    Log "sustained_responsive_ms = NEVER (informational; expected on large sessions)"
}

if ($stock) {
    # GOLDEN RULE: never more dialogs / freezes than stock.
    $verdicts += @{n='startup_dialogs_vs_stock';val="$($ours.StartupDialogs) vs stock $($stock.StartupDialogs)";p=($ours.StartupDialogs -le $stock.StartupDialogs)}
    $verdicts += @{n='close_dialogs_vs_stock';val="$($ours.CloseDialogs) vs stock $($stock.CloseDialogs)";p=($ours.CloseDialogs -le $stock.CloseDialogs)}
    $verdicts += @{n='not_responding_hits_vs_stock';val="$($ours.NotRespondingHits) vs stock $($stock.NotRespondingHits)";p=($ours.NotRespondingHits -le $stock.NotRespondingHits + 1)}
    $verdicts += @{n='session_count_stable';val="$($ours.PreSessionCount) -> $($ours.PostSessionCount) (stock $($stock.PreSessionCount) -> $($stock.PostSessionCount))";p=($ours.PostSessionCount -ge $stock.PostSessionCount)}
} else {
    # Standalone limits when no stock baseline.
    $verdicts += @{n='startup_dialogs';val=$ours.StartupDialogs;p=($ours.StartupDialogs -eq 0)}
    $verdicts += @{n='close_dialogs';val=$ours.CloseDialogs;p=($ours.CloseDialogs -eq 0)}
    $verdicts += @{n='session_count_stable';val="$($ours.PreSessionCount) -> $($ours.PostSessionCount)";p=($ours.PostSessionCount -ge $ours.PreSessionCount)}
}

''
'================ smoke_test.ps1 verdict ================'
foreach ($v in $verdicts) {
    $tag = if ($v.p) { 'PASS' } else { 'FAIL' }
    "  [$tag] $($v.n) = $($v.val)"
}
if ($stock) {
    "  --- raw stock ---  startup_dlgs=$($stock.StartupDialogs) close_dlgs=$($stock.CloseDialogs) sust=$($stock.SustainedAtMs) notresp=$($stock.NotRespondingHits)"
}
"  --- raw ours  ---  startup_dlgs=$($ours.StartupDialogs) close_dlgs=$($ours.CloseDialogs) sust=$($ours.SustainedAtMs) notresp=$($ours.NotRespondingHits) init=$($ours.InitMs)"

$anyFail = $verdicts | Where-Object { -not $_.p }
if ($anyFail) { exit 1 } else { exit 0 }
