[CmdletBinding()]
param(
  [string]$SessionJsonl = "",
  [switch]$UseLatest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$logRoot = Join-Path $repoRoot "5_Vision_Extraction\out\ui_session_logs"
if (-not (Test-Path $logRoot)) {
  throw "UI session log folder not found: $logRoot"
}

if ([string]::IsNullOrWhiteSpace($SessionJsonl) -or $UseLatest) {
  $latest = Get-ChildItem -Path $logRoot -Filter "session_*.jsonl" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -eq $latest) {
    throw "No session_*.jsonl logs found in $logRoot"
  }
  $SessionJsonl = $latest.FullName
}

if (-not (Test-Path $SessionJsonl)) {
  throw "Session log not found: $SessionJsonl"
}

$rows = New-Object System.Collections.Generic.List[object]
Get-Content -Path $SessionJsonl -Encoding UTF8 | ForEach-Object {
  $line = [string]$_
  if ([string]::IsNullOrWhiteSpace($line)) { return }
  try {
    $obj = $line | ConvertFrom-Json
    [void]$rows.Add($obj)
  }
  catch {
    # ignore malformed line
  }
}

if ($rows.Count -eq 0) {
  throw "No valid JSON rows parsed from $SessionJsonl"
}

function Count-Type([string]$typeName) {
  return @($rows | Where-Object { [string]$_.type -eq $typeName }).Count
}

$summary = [ordered]@{
  session_jsonl = (Resolve-Path $SessionJsonl).Path
  total_rows = $rows.Count
  queue_events = [ordered]@{
    queued = Count-Type "engine_queue"
    started = Count-Type "engine_job_started"
    completed = Count-Type "engine_job_completed"
    failed = Count-Type "engine_job_failed"
    timeout = Count-Type "engine_job_timeout"
    replaced = Count-Type "engine_queue_replace"
    replaced_job = Count-Type "engine_job_replaced"
    skip_nochange_hash = Count-Type "engine_skip_nochange"
    skip_nochange_logical = Count-Type "engine_skip_nochange_logical"
    skip_priority = Count-Type "engine_skip_priority"
  }
}

$q = $summary.queue_events
$summary.success_rate = if (($q.started -as [int]) -gt 0) { [double]$q.completed / [double]$q.started } else { $null }
$summary.skip_rate_vs_queue = if (($q.queued -as [int]) -gt 0) { [double]($q.skip_nochange_hash + $q.skip_nochange_logical + $q.skip_priority) / [double]$q.queued } else { $null }
$summary.replace_rate_vs_queue = if (($q.queued -as [int]) -gt 0) { [double]$q.replaced / [double]$q.queued } else { $null }

$summaryJson = $summary | ConvertTo-Json -Depth 6
Write-Host "UI Queue Summary"
Write-Host $summaryJson

$outPath = Join-Path $logRoot "latest_queue_summary.json"
Set-Content -Path $outPath -Value ($summaryJson + [Environment]::NewLine) -Encoding UTF8
Write-Host ("summary_path={0}" -f $outPath)
