param(
    [int]$ProcessId = 0,
    [string]$LabelsPath = "2_Neural_Brain/local_pipeline/data/raw_spots/solver_reference_labels.jsonl",
    [string]$ErrorsPath = "2_Neural_Brain/local_pipeline/reports/offline_label_errors.jsonl",
    [string]$ManifestPath = "2_Neural_Brain/local_pipeline/reports/offline_label_manifest.json",
    [int]$StaleMinutes = 10,
    [switch]$ForceRestart,
    [switch]$NoRelaunch,
    [switch]$Loop,
    [int]$PollSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LabelerProcess {
    param([int]$PidHint)
    if ($PidHint -gt 0) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PidHint" -ErrorAction SilentlyContinue
        if ($null -ne $p -and [string]$p.CommandLine -match "label_reference_offline.py") {
            return $p
        }
    }
    $all = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match "^python(\.exe)?$" -and [string]$_.CommandLine -match "label_reference_offline.py"
    }
    if ($null -eq $all) { return $null }
    return ($all | Sort-Object ProcessId | Select-Object -First 1)
}

function Get-MostRecentWrite {
    param(
        [string[]]$Paths
    )
    $latest = $null
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        if ($null -eq $latest -or $item.LastWriteTime -gt $latest) {
            $latest = $item.LastWriteTime
        }
    }
    return $latest
}

function Test-JsonLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        $trimmed = ""
    } else {
        $trimmed = $Line.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $true }
    try {
        $null = $trimmed | ConvertFrom-Json -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Repair-JsonlTail {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path))
    if ($lines.Length -eq 0) { return }
    $last = $lines.Length - 1
    while ($last -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$last])) {
        $last--
    }
    if ($last -lt 0) { return }
    if (Test-JsonLine -Line $lines[$last]) { return }

    $trimCount = $last
    if ($trimCount -lt 0) {
        [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), "", [System.Text.Encoding]::UTF8)
        Write-Host "Repaired tail: cleared malformed-only file $Path"
        return
    }

    $newLines = if ($trimCount -eq 0) { @() } else { $lines[0..($trimCount - 1)] }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $writer = New-Object System.IO.StreamWriter($resolved, $false, [System.Text.Encoding]::UTF8)
    try {
        foreach ($line in $newLines) {
            $writer.WriteLine($line)
        }
    } finally {
        $writer.Dispose()
    }
    Write-Host "Repaired tail: removed malformed final JSONL line in $Path"
}

function Split-ExecutableAndArgs {
    param([string]$CommandLine)
    $cmd = [string]$CommandLine
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        throw "Cannot relaunch: empty command line."
    }
    $cmd = $cmd.Trim()
    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -lt 1) {
            throw "Cannot parse executable from command line: $cmd"
        }
        $exe = $cmd.Substring(1, $end - 1)
        $args = $cmd.Substring($end + 1).Trim()
        return @($exe, $args)
    }
    $parts = $cmd.Split(" ", 2, [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Length -eq 0) {
        throw "Cannot parse executable from command line: $cmd"
    }
    $exe = $parts[0]
    $args = if ($parts.Length -gt 1) { $parts[1] } else { "" }
    return @($exe, $args)
}

function Get-ArgValueFromCommandLine {
    param(
        [string]$CommandLine,
        [string]$Name,
        [double]$DefaultValue
    )
    $pattern = "(?:^|\s)--" + [Regex]::Escape($Name) + "\s+([^\s`"]+)"
    $m = [Regex]::Match([string]$CommandLine, $pattern)
    if (-not $m.Success) {
        return $DefaultValue
    }
    $raw = [string]$m.Groups[1].Value
    $out = 0.0
    if ([double]::TryParse($raw, [ref]$out)) {
        return $out
    }
    return $DefaultValue
}

function Get-MinExpectedQuietMinutes {
    param([string]$LabelerCommandLine)
    $timeoutSec = Get-ArgValueFromCommandLine -CommandLine $LabelerCommandLine -Name "timeout-sec" -DefaultValue 180.0
    $maxRetries = Get-ArgValueFromCommandLine -CommandLine $LabelerCommandLine -Name "max-retries" -DefaultValue 2.0
    $retryDelay = Get-ArgValueFromCommandLine -CommandLine $LabelerCommandLine -Name "retry-delay-sec" -DefaultValue 2.0
    if ($timeoutSec -lt 1) { $timeoutSec = 1.0 }
    if ($maxRetries -lt 0) { $maxRetries = 0.0 }
    if ($retryDelay -lt 0) { $retryDelay = 0.0 }
    $attempts = [Math]::Floor($maxRetries) + 1.0
    $quietSeconds = ($attempts * ($timeoutSec + 10.0)) + ([Math]::Floor($maxRetries) * $retryDelay)
    return [Math]::Ceiling(($quietSeconds / 60.0) + 1.0)
}

function Get-ProcessStartTimeUtc {
    param([int]$TargetProcessId)
    try {
        $proc = Get-Process -Id $TargetProcessId -ErrorAction Stop
        return $proc.StartTime.ToUniversalTime()
    } catch {
        return $null
    }
}

function Stop-LabelerAndSolver {
    param([int]$TargetProcessId)
    try {
        Stop-Process -Id $TargetProcessId -Force -ErrorAction Stop
        Write-Host "Stopped labeler PID $TargetProcessId"
    } catch {
        Write-Host "Labeler PID $TargetProcessId was not running at kill time."
    }

    $solverProcs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -ieq "shark_cli.exe"
    }
    foreach ($solver in @($solverProcs)) {
        try {
            Stop-Process -Id ([int]$solver.ProcessId) -Force -ErrorAction Stop
            Write-Host "Stopped shark_cli PID $($solver.ProcessId)"
        } catch {
            Write-Host "Failed to stop shark_cli PID $($solver.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Invoke-GuardPass {
    $labeler = Get-LabelerProcess -PidHint $ProcessId
    if ($null -eq $labeler) {
        Write-Host "No running label_reference_offline.py process found."
        return
    }
    $labelerPid = [int]$labeler.ProcessId
    $cmd = [string]$labeler.CommandLine
    $processStartUtc = Get-ProcessStartTimeUtc -TargetProcessId $labelerPid

    $latestWrite = Get-MostRecentWrite -Paths @($LabelsPath, $ErrorsPath, $ManifestPath)
    $now = Get-Date
    $stale = $false
    $ageMin = [double]::PositiveInfinity
    $activityTimestamp = $null
    $minExpectedQuietMinutes = Get-MinExpectedQuietMinutes -LabelerCommandLine $cmd
    $effectiveThreshold = [Math]::Max([double]$StaleMinutes, [double]$minExpectedQuietMinutes)
    if ($null -ne $latestWrite) {
        $activityTimestamp = $latestWrite
        if ($null -ne $processStartUtc -and $latestWrite.ToUniversalTime() -lt $processStartUtc) {
            $activityTimestamp = $processStartUtc.ToLocalTime()
        }
        $ageMin = ($now - $activityTimestamp).TotalMinutes
        $stale = $ageMin -ge $effectiveThreshold
    } elseif ($null -ne $processStartUtc) {
        $activityTimestamp = $processStartUtc.ToLocalTime()
        $ageMin = ($now - $activityTimestamp).TotalMinutes
        $stale = $ageMin -ge $effectiveThreshold
    }
    if ($ForceRestart) {
        $stale = $true
    }

    if (-not $stale) {
        if ($null -ne $activityTimestamp -and $null -ne $latestWrite -and $activityTimestamp -ne $latestWrite) {
            Write-Host ("Labeler healthy: no new writes since launch; process start {0} ({1:N1} min ago), threshold={2} min (configured={3}, computed_floor={4})." -f $activityTimestamp, $ageMin, $effectiveThreshold, $StaleMinutes, $minExpectedQuietMinutes)
        } else {
            Write-Host ("Labeler healthy: last activity {0} ({1:N1} min ago), threshold={2} min (configured={3}, computed_floor={4})." -f $activityTimestamp, $ageMin, $effectiveThreshold, $StaleMinutes, $minExpectedQuietMinutes)
        }
        return
    }

    if ($null -eq $activityTimestamp) {
        Write-Host "Stale trigger: no output files found yet."
    } elseif ($null -ne $latestWrite -and $activityTimestamp -ne $latestWrite) {
        Write-Host ("Stale trigger: no new writes since launch; process start {0} ({1:N1} min ago), threshold={2} min (configured={3}, computed_floor={4})." -f $activityTimestamp, $ageMin, $effectiveThreshold, $StaleMinutes, $minExpectedQuietMinutes)
    } else {
        Write-Host ("Stale trigger: last activity {0} ({1:N1} min ago), threshold={2} min (configured={3}, computed_floor={4})." -f $activityTimestamp, $ageMin, $effectiveThreshold, $StaleMinutes, $minExpectedQuietMinutes)
    }

    Stop-LabelerAndSolver -TargetProcessId $labelerPid
    Start-Sleep -Seconds 1

    Repair-JsonlTail -Path $LabelsPath
    Repair-JsonlTail -Path $ErrorsPath

    if ($NoRelaunch) {
        Write-Host "NoRelaunch set; exiting after cleanup."
        return
    }

    $split = Split-ExecutableAndArgs -CommandLine $cmd
    $exe = $split[0]
    $args = $split[1]
    $newProc = Start-Process -FilePath $exe -ArgumentList $args -PassThru
    Write-Host "Relaunched labeler PID $($newProc.Id)"
}

if ($Loop) {
    while ($true) {
        try {
            Invoke-GuardPass
        } catch {
            Write-Host "Guard pass error: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds))
    }
} else {
    Invoke-GuardPass
}
