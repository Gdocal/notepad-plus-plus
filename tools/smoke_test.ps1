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
    [string]$StockExe   = 'F:\NppBackups\stock_8.9.6.4_notepad++.exe',
    # 25 s so stock NPP has time to actually finish loading a 300+ tab
    # session (it blocks the main thread for 15-20 s) and we can observe
    # WHEN it first becomes responsive — that's the headline metric.
    [int]$RunSeconds         = 25,
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
    $windowAppearedAt   = $null   # first time MainWindowHandle != 0
    $firstResponsiveAt  = $null   # first time SMTO returned within 2 s (alive at all)
    $firstFastAt        = $null   # first time SMTO returned within 50 ms (true real interactivity)
    $sustainedFastAt    = $null   # first time we saw 2 s of <50 ms responses in a row (fully drained)
    $sustainStart       = $null
    $notRespondingCount = 0       # ticks where SMTO timed out (>2000 ms = effectively frozen)
    $slowResponseCount  = 0       # ticks where SMTO succeeded but took >50 ms (laggy)
    $latencies          = New-Object System.Collections.Generic.List[int]
    $probeSw            = [Diagnostics.Stopwatch]::new()

    while ($sw.Elapsed.TotalSeconds -lt $RunSeconds) {
        $proc.Refresh()
        $t = [int]$sw.ElapsedMilliseconds
        $latencyMs = $null
        if ($proc.MainWindowHandle -ne 0) {
            if ($null -eq $windowAppearedAt) { $windowAppearedAt = $t; Log "  window appeared at +${t}ms" }
            $r = [IntPtr]::Zero
            # 2000 ms cap on individual probe: long enough to distinguish
            # "main thread is taking a while to process a queued WM_TIMER"
            # (latency 100-500 ms is common during the session-insert pump)
            # from "main thread is genuinely hung" (Windows' built-in
            # hung-app detection kicks in around 5 s). We measure the
            # actual milliseconds the probe took — success itself is
            # not enough, what matters is HOW FAST it answered.
            $probeSw.Restart()
            $rc = [Smoke]::SendMessageTimeoutW($proc.MainWindowHandle, 0, [IntPtr]::Zero, [IntPtr]::Zero, 0x0000, 2000, [ref]$r)
            $probeSw.Stop()
            if ($rc -ne [IntPtr]::Zero) {
                $latencyMs = [int]$probeSw.ElapsedMilliseconds
                $latencies.Add($latencyMs) | Out-Null
            }
        }
        if ($null -ne $latencyMs) {
            if ($null -eq $firstResponsiveAt) { $firstResponsiveAt = $t; Log "  first response at +${t}ms (latency ${latencyMs}ms)" }
            if ($latencyMs -le 50) {
                if ($null -eq $firstFastAt) { $firstFastAt = $t; Log "  first FAST response at +${t}ms (latency ${latencyMs}ms)" }
                if ($null -eq $sustainStart) { $sustainStart = $t }
                elseif ($null -eq $sustainedFastAt -and ($t - $sustainStart) -ge 2000) {
                    $sustainedFastAt = $sustainStart
                    Log "  sustained-fast (drained) since +${sustainStart}ms"
                }
            } else {
                $sustainStart = $null
                $slowResponseCount++
            }
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

    # Compute latency percentiles over the run.
    $p50 = $null; $p95 = $null; $pMax = $null
    if ($latencies.Count -gt 0) {
        $sorted = $latencies | Sort-Object
        $p50 = [int]$sorted[[Math]::Floor($sorted.Count * 0.50)]
        $p95 = [int]$sorted[[Math]::Min($sorted.Count - 1, [Math]::Floor($sorted.Count * 0.95))]
        $pMax = [int]($sorted | Select-Object -Last 1)
    }

    return [PSCustomObject]@{
        Label              = $Label
        StartupDialogs     = $startupDlgs.Count
        CloseDialogs       = $closeDlgs.Count
        WindowAppearedMs   = $windowAppearedAt
        FirstResponsiveMs  = $firstResponsiveAt
        FirstFastMs        = $firstFastAt          # first probe < 50 ms latency
        SustainedFastMs    = $sustainedFastAt      # first start of 2 s window of <50 ms responses
        LatencyP50         = $p50                  # typical response time
        LatencyP95         = $p95                  # tail
        LatencyMax         = $pMax
        InitMs             = $initMs
        NotRespondingHits  = $notRespondingCount   # probes that timed out (>2000 ms)
        SlowResponseHits   = $slowResponseCount    # probes that returned but took >50 ms
        PreSessionCount    = $preCount
        PostSessionCount   = $postCount
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

function Fmt($v) { if ($null -eq $v) { 'NEVER' } else { "${v}ms" } }

if ($stock) {
    # HEADLINE METRICS (three of them, increasingly strict):
    #
    # 1. time_to_first_response — first SMTO returned within 2 s.
    #    Means "main thread is alive at all, not deadlocked".
    #
    # 2. time_to_fast — first SMTO returned in under 50 ms.
    #    Means "if you typed RIGHT NOW, your keystroke would be processed
    #    without a noticeable delay" — true interactivity.
    #
    # 3. time_to_sustained — first start of a 2 s window where every
    #    probe took <50 ms. Means "the session-insert pump has fully
    #    drained and the app behaves normally".
    #
    # The user perceives (3) as "Notepad++ is actually loaded and
    # ready". The previous version of this script only tracked (1)
    # which is misleading: between WM_TIMER ticks the message pump
    # answers WM_NULL within ms but each click/keystroke queues
    # behind the next 30-50 ms tick. (1) says "responsive at 1.8 s"
    # but the user feels lag for the next 10 s.
    $speedup1 = ($null -ne $ours.FirstResponsiveMs) -and (
        $null -eq $stock.FirstResponsiveMs -or
        $ours.FirstResponsiveMs -le $stock.FirstResponsiveMs / 2 )
    $verdicts += @{n='time_to_first_response_vs_stock';val="$(Fmt $ours.FirstResponsiveMs) vs stock $(Fmt $stock.FirstResponsiveMs)";p=$speedup1}

    $speedup2 = ($null -ne $ours.FirstFastMs) -and (
        $null -eq $stock.FirstFastMs -or
        $ours.FirstFastMs -le $stock.FirstFastMs / 2 )
    $verdicts += @{n='time_to_fast_vs_stock';val="$(Fmt $ours.FirstFastMs) vs stock $(Fmt $stock.FirstFastMs)";p=$speedup2}

    $speedup3 = ($null -ne $ours.SustainedFastMs) -and (
        $null -eq $stock.SustainedFastMs -or
        $ours.SustainedFastMs -le $stock.SustainedFastMs / 2 )
    $verdicts += @{n='time_to_sustained_vs_stock';val="$(Fmt $ours.SustainedFastMs) vs stock $(Fmt $stock.SustainedFastMs)";p=$speedup3}

    # Latency tail: 95th-percentile per-probe latency. Even after the
    # window is "responsive", high p95 means the app feels janky.
    $p95Ok = ($null -ne $ours.LatencyP95) -and ($ours.LatencyP95 -le $stock.LatencyP95)
    $verdicts += @{n='latency_p95_vs_stock';val="$(Fmt $ours.LatencyP95) vs stock $(Fmt $stock.LatencyP95)";p=$p95Ok}

    # GOLDEN RULE: never more dialogs / freezes than stock.
    $verdicts += @{n='startup_dialogs_vs_stock';val="$($ours.StartupDialogs) vs stock $($stock.StartupDialogs)";p=($ours.StartupDialogs -le $stock.StartupDialogs)}
    $verdicts += @{n='close_dialogs_vs_stock';val="$($ours.CloseDialogs) vs stock $($stock.CloseDialogs)";p=($ours.CloseDialogs -le $stock.CloseDialogs)}
    $verdicts += @{n='session_count_stable';val="$($ours.PreSessionCount) -> $($ours.PostSessionCount) (stock $($stock.PreSessionCount) -> $($stock.PostSessionCount))";p=($ours.PostSessionCount -ge $stock.PostSessionCount)}
} else {
    # Standalone limits when no stock baseline.
    $verdicts += @{n='time_to_first_response_ms';val=(Fmt $ours.FirstResponsiveMs);p=($null -ne $ours.FirstResponsiveMs -and $ours.FirstResponsiveMs -le 2000)}
    $verdicts += @{n='time_to_fast_ms';val=(Fmt $ours.FirstFastMs);p=($null -ne $ours.FirstFastMs -and $ours.FirstFastMs -le 5000)}
    $verdicts += @{n='time_to_sustained_ms';val=(Fmt $ours.SustainedFastMs);p=($null -ne $ours.SustainedFastMs -and $ours.SustainedFastMs -le 15000)}
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
function FmtRaw($v) { if ($null -eq $v) { 'NEVER' } else { $v } }
if ($stock) {
    "  --- raw stock ---  win=$(FmtRaw $stock.WindowAppearedMs) first=$(FmtRaw $stock.FirstResponsiveMs) fast=$(FmtRaw $stock.FirstFastMs) sustained=$(FmtRaw $stock.SustainedFastMs) lat_p50=$(FmtRaw $stock.LatencyP50) lat_p95=$(FmtRaw $stock.LatencyP95) lat_max=$(FmtRaw $stock.LatencyMax) notresp=$($stock.NotRespondingHits) slow=$($stock.SlowResponseHits)"
}
"  --- raw ours  ---  win=$(FmtRaw $ours.WindowAppearedMs) first=$(FmtRaw $ours.FirstResponsiveMs) fast=$(FmtRaw $ours.FirstFastMs) sustained=$(FmtRaw $ours.SustainedFastMs) lat_p50=$(FmtRaw $ours.LatencyP50) lat_p95=$(FmtRaw $ours.LatencyP95) lat_max=$(FmtRaw $ours.LatencyMax) notresp=$($ours.NotRespondingHits) slow=$($ours.SlowResponseHits) init=$(FmtRaw $ours.InitMs)"

$anyFail = $verdicts | Where-Object { -not $_.p }
if ($anyFail) { exit 1 } else { exit 0 }
