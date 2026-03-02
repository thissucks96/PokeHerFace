<#
.SYNOPSIS
Run a repeatable fast_live tuning sweep and report latency/quality deltas.

.DESCRIPTION
Starts bridge_server.py with per-run FAST_LIVE environment overrides, runs the
stateful simulator against each config, and writes a ranked summary (JSON/CSV).
This is designed to push fast_live strength while explicitly tracking latency cost.
#>
[CmdletBinding()]
param(
    [string]$Preset = "local_qwen3_coder_30b",
    [int]$Hands = 12,
    [ValidateSet("scripted_tight","scripted_aggressive","engine_random")]
    [string]$VillainMode = "scripted_aggressive",
    [int]$TimeoutSec = 60,
    [string]$OutputDir = "",
    [string[]]$ConfigNames = @()
)

$ErrorActionPreference = "Stop"

function Resolve-VenvPython {
    param([string]$WorkspaceRoot)
    $candidate = Join-Path $WorkspaceRoot ".venv\Scripts\python.exe"
    if (Test-Path $candidate) {
        return (Resolve-Path $candidate).Path
    }
    return "python"
}

function Stop-BridgeProcesses {
    param([string]$WorkspaceRoot)
    $rootNorm = [System.IO.Path]::GetFullPath($WorkspaceRoot).ToLowerInvariant()
    $targets = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $cmd = [string]$_.CommandLine
        if (-not $cmd) { return $false }
        $cmdNorm = $cmd.ToLowerInvariant()
        return ($cmdNorm -like "*bridge_server.py*") -and ($cmdNorm -like "*$rootNorm*")
    }
    foreach ($proc in $targets) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Wait-BridgeHealthy {
    param(
        [string]$HealthUrl,
        [int]$TimeoutSec = 30
    )
    $deadline = (Get-Date).AddSeconds([Math]::Max(3, $TimeoutSec))
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 3
            if ($resp -and $resp.status -eq "ok") {
                return $true
            }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Set-EnvOverrides {
    param([hashtable]$Overrides)
    $previous = @{}
    foreach ($k in $Overrides.Keys) {
        $previous[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
        [Environment]::SetEnvironmentVariable($k, [string]$Overrides[$k], "Process")
    }
    return $previous
}

function Restore-EnvOverrides {
    param(
        [hashtable]$Previous,
        [hashtable]$Overrides
    )
    foreach ($k in $Overrides.Keys) {
        $old = $null
        if ($Previous.ContainsKey($k)) {
            $old = $Previous[$k]
        }
        [Environment]::SetEnvironmentVariable($k, $old, "Process")
    }
}

$workspaceRoot = (Resolve-Path "$PSScriptRoot\..").Path
$pythonExe = Resolve-VenvPython -WorkspaceRoot $workspaceRoot
$bridgeDir = Join-Path $workspaceRoot "4_LLM_Bridge"
$simScript = Join-Path $bridgeDir "run_stateful_sim.py"
$healthUrl = "http://127.0.0.1:8000/health"

if (-not (Test-Path $simScript)) {
    throw "Cannot find simulator script: $simScript"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $workspaceRoot "4_LLM_Bridge\examples\synthetic_hands\fast_live_tuning"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $workspaceRoot $OutputDir
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not (Test-Path $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$runStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$logDir = Join-Path $workspaceRoot "5_Vision_Extraction\out\ui_session_logs"
if (-not (Test-Path $logDir)) {
    $null = New-Item -ItemType Directory -Path $logDir -Force
}

$configs = @(
    @{
        name = "baseline"
        env = @{}
        note = "Current fast_live defaults"
    },
    @{
        name = "iter4_threads6"
        env = @{
            FAST_LIVE_SPOT_MAX_ITERATIONS = "4"
            FAST_LIVE_SPOT_MAX_THREADS = "6"
        }
        note = "Slightly deeper solve"
    },
    @{
        name = "iter5_threads8"
        env = @{
            FAST_LIVE_SPOT_MAX_ITERATIONS = "5"
            FAST_LIVE_SPOT_MAX_THREADS = "8"
        }
        note = "Deeper solve + wider CPU"
    },
    @{
        name = "wider_bets_raisecap5"
        env = @{
            FAST_LIVE_SPOT_MAX_ITERATIONS = "4"
            FAST_LIVE_SPOT_MAX_THREADS = "8"
            FAST_LIVE_SPOT_MAX_RAISE_CAP = "5"
            FAST_LIVE_SPOT_BET_SIZES = "0.25,0.33,0.5,0.75,1.0,1.25"
            FAST_LIVE_SPOT_RAISE_SIZES = "1.0,2.0,3.0,4.0"
        }
        note = "More action granularity"
    },
    @{
        name = "deeper_time_active"
        env = @{
            FAST_LIVE_SPOT_MAX_ITERATIONS = "5"
            FAST_LIVE_SPOT_MAX_THREADS = "8"
            FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC = "9"
            FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC = "6"
            FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC = "5"
            FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC = "10"
            FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC = "12"
        }
        note = "Bigger postflop budget"
    }
)

if ($ConfigNames -and $ConfigNames.Count -gt 0) {
    $wanted = @($ConfigNames | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    $configs = @($configs | Where-Object { $wanted -contains ([string]$_.name).ToLowerInvariant() })
    if ($configs.Count -eq 0) {
        throw "No configs matched ConfigNames: $($ConfigNames -join ', ')"
    }
}

$results = New-Object System.Collections.Generic.List[object]

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " FAST_LIVE Tuning Sweep" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Hands per config: $Hands"
Write-Host "Villain mode    : $VillainMode"
Write-Host "Preset          : $Preset"
Write-Host "Configs         : $($configs.Count)"
Write-Host ""

foreach ($cfg in $configs) {
    $name = [string]$cfg.name
    $envMap = [hashtable]$cfg.env
    $note = [string]$cfg.note
    $reportPath = Join-Path $OutputDir ("stateful_sim_report.fast_live.{0}hands.{1}.{2}.json" -f $Hands, $name, $runStamp)
    $artifactDir = Join-Path $OutputDir ("artifacts_{0}_{1}" -f $name, $runStamp)
    if (-not (Test-Path $artifactDir)) {
        $null = New-Item -ItemType Directory -Path $artifactDir -Force
    }

    Write-Host ("[{0}] {1}" -f $name, $note) -ForegroundColor Yellow
    $previousEnv = Set-EnvOverrides -Overrides $envMap
    Stop-BridgeProcesses -WorkspaceRoot $workspaceRoot

    $bridgeOut = Join-Path $logDir ("bridge_fastlive_sweep_{0}_{1}.out.log" -f $name, $runStamp)
    $bridgeErr = Join-Path $logDir ("bridge_fastlive_sweep_{0}_{1}.err.log" -f $name, $runStamp)
    $bridgeProc = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $bridgeProc = Start-Process -FilePath $pythonExe -ArgumentList "bridge_server.py" -WorkingDirectory $bridgeDir -WindowStyle Hidden -RedirectStandardOutput $bridgeOut -RedirectStandardError $bridgeErr -PassThru
        if (-not (Wait-BridgeHealthy -HealthUrl $healthUrl -TimeoutSec 40)) {
            throw "Bridge health did not become ready for config '$name'."
        }

        $args = @(
            $simScript,
            "--hands", $Hands,
            "--preset", $Preset,
            "--runtime-profile", "fast_live",
            "--villain-mode", $VillainMode,
            "--timeout", $TimeoutSec,
            "--output", $reportPath,
            "--artifact-dir", $artifactDir
        )
        $proc = Start-Process -FilePath $pythonExe -ArgumentList $args -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "run_stateful_sim failed for '$name' with exit code $($proc.ExitCode)."
        }

        if (-not (Test-Path $reportPath)) {
            throw "Expected report missing for '$name': $reportPath"
        }

        $report = Get-Content $reportPath -Raw | ConvertFrom-Json
        $agg = $report.aggregate
        $strategy = @{}
        if ($agg.strategy_sources) {
            foreach ($p in $agg.strategy_sources.PSObject.Properties) {
                $strategy[$p.Name] = [int]$p.Value
            }
        }

        $resultObj = [pscustomobject]@{
            config_name = $name
            note = $note
            hands = [int]$agg.total_hands
            wins = [int]$agg.win_loss.win
            losses = [int]$agg.win_loss.loss
            ties = [int]$agg.win_loss.tie
            net_bb = [double]$agg.net_bb_won
            bb_100 = [double]$agg.bb_100
            avg_latency_flop = [double]$agg.avg_latency.flop
            avg_latency_turn = [double]$agg.avg_latency.turn
            avg_latency_river = [double]$agg.avg_latency.river
            strategy_sources = $strategy
            wall_time_sec = [double]$sw.Elapsed.TotalSeconds
            report_path = $reportPath
            artifact_dir = $artifactDir
            env_overrides = $envMap
        }
        [void]$results.Add($resultObj)

        Write-Host ("  net_bb={0:N1} bb100={1:N1} lat(f/t/r)={2:N2}/{3:N2}/{4:N2}s wall={5:N1}s" -f `
            [double]$resultObj.net_bb, [double]$resultObj.bb_100, `
            [double]$resultObj.avg_latency_flop, [double]$resultObj.avg_latency_turn, [double]$resultObj.avg_latency_river, [double]$resultObj.wall_time_sec)
    }
    finally {
        $sw.Stop()
        if ($bridgeProc -and -not $bridgeProc.HasExited) {
            try { Stop-Process -Id $bridgeProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        Stop-BridgeProcesses -WorkspaceRoot $workspaceRoot
        Restore-EnvOverrides -Previous $previousEnv -Overrides $envMap
    }
}

if ($results.Count -eq 0) {
    throw "Sweep produced no successful runs."
}

$baseline = $results | Where-Object { $_.config_name -eq "baseline" } | Select-Object -First 1
if (-not $baseline) {
    $baseline = $results[0]
}

$rows = @()
foreach ($row in $results) {
    $rows += [pscustomobject]@{
        config_name = $row.config_name
        hands = $row.hands
        net_bb = [math]::Round([double]$row.net_bb, 3)
        bb_100 = [math]::Round([double]$row.bb_100, 3)
        avg_latency_flop = [math]::Round([double]$row.avg_latency_flop, 4)
        avg_latency_turn = [math]::Round([double]$row.avg_latency_turn, 4)
        avg_latency_river = [math]::Round([double]$row.avg_latency_river, 4)
        delta_flop_vs_baseline = [math]::Round(([double]$row.avg_latency_flop - [double]$baseline.avg_latency_flop), 4)
        delta_turn_vs_baseline = [math]::Round(([double]$row.avg_latency_turn - [double]$baseline.avg_latency_turn), 4)
        delta_river_vs_baseline = [math]::Round(([double]$row.avg_latency_river - [double]$baseline.avg_latency_river), 4)
        delta_bb100_vs_baseline = [math]::Round(([double]$row.bb_100 - [double]$baseline.bb_100), 3)
        wall_time_sec = [math]::Round([double]$row.wall_time_sec, 3)
        report_path = $row.report_path
    }
}

$summaryJson = Join-Path $OutputDir ("fast_live_tuning_sweep_{0}.json" -f $runStamp)
$summaryCsv = Join-Path $OutputDir ("fast_live_tuning_sweep_{0}.csv" -f $runStamp)
$summary = [pscustomobject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    hands_per_config = $Hands
    villain_mode = $VillainMode
    preset = $Preset
    baseline_config = $baseline.config_name
    results = $rows
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryJson -Encoding UTF8
$rows | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Sweep completed." -ForegroundColor Green
Write-Host "Summary JSON: $summaryJson" -ForegroundColor Green
Write-Host "Summary CSV : $summaryCsv" -ForegroundColor Green
Write-Host ""
$rows | Sort-Object bb_100 -Descending | Format-Table config_name, bb_100, avg_latency_flop, avg_latency_turn, avg_latency_river, delta_bb100_vs_baseline, delta_flop_vs_baseline -AutoSize

exit 0
