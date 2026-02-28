[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-StaSession {
  if ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA) {
    return $true
  }
  if (-not $PSCommandPath) {
    throw "tesseract_test.ps1 must run in STA mode. Re-run with: pwsh -STA -File .\tesseract_test.ps1"
  }

  $hostExe = "powershell.exe"
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $hostExe = "pwsh"
  }
  Start-Process -FilePath $hostExe -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-STA",
    "-File", "`"$PSCommandPath`""
  ) | Out-Null
  return $false
}

if (-not (Ensure-StaSession)) {
  return
}

function Resolve-TesseractExecutable {
  $candidates = @(
    $env:TESSERACT_PATH,
    "tesseract",
    "C:\Program Files\Tesseract-OCR\tesseract.exe",
    "C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"
  ) | Where-Object { $_ -and ([string]$_).Trim() -ne "" }

  foreach ($candidate in $candidates) {
    try {
      if ($candidate -eq "tesseract") {
        $cmd = Get-Command tesseract -ErrorAction Stop
        if ($cmd -and $cmd.Source) {
          return $cmd.Source
        }
      }
      elseif (Test-Path $candidate) {
        return $candidate
      }
    }
    catch {
      continue
    }
  }
  return $null
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
  Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class NativeDpi {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
}
"@ -ErrorAction SilentlyContinue | Out-Null
  [void][NativeDpi]::SetProcessDPIAware()
}
catch {
  # Non-fatal if DPI API is unavailable.
}

$tesseractExe = Resolve-TesseractExecutable
$ollamaHost = if ($env:OLLAMA_HOST) { [string]$env:OLLAMA_HOST } else { "http://127.0.0.1:11434" }
$ollamaVisionModel = if ($env:OLLAMA_VISION_MODEL) { [string]$env:OLLAMA_VISION_MODEL } else { "llava:13b" }
$ollamaVisionKeepAlive = if ($env:OLLAMA_VISION_KEEP_ALIVE) { ([string]$env:OLLAMA_VISION_KEEP_ALIVE).Trim() } else { "0s" }
if (-not $ollamaVisionKeepAlive) {
  $ollamaVisionKeepAlive = "0s"
}
$bridgeSolveEndpoint = if ($env:BRIDGE_SOLVE_ENDPOINT) { [string]$env:BRIDGE_SOLVE_ENDPOINT } else { "http://127.0.0.1:8000/solve" }
$bridgeHealthEndpoint = "http://127.0.0.1:8000/health"
try {
  $uri = [System.Uri]$bridgeSolveEndpoint
  $bridgeHealthEndpoint = ("{0}://{1}:{2}/health" -f $uri.Scheme, $uri.Host, $uri.Port)
}
catch {
  if ($bridgeSolveEndpoint.ToLowerInvariant().EndsWith("/solve")) {
    $bridgeHealthEndpoint = ($bridgeSolveEndpoint.Substring(0, $bridgeSolveEndpoint.Length - 6) + "/health")
  }
}
$engineSpotTemplatePath = if ($env:ENGINE_SPOT_TEMPLATE_PATH) { [string]$env:ENGINE_SPOT_TEMPLATE_PATH } else { (Join-Path $PSScriptRoot "4_LLM_Bridge\examples\spot.sample.json") }
$engineOutputDir = if ($env:ENGINE_OCR_OUT_DIR) { [string]$env:ENGINE_OCR_OUT_DIR } else { (Join-Path $PSScriptRoot "5_Vision_Extraction\out\flop_engine") }
$engineLlmPreset = if ($env:ENGINE_LLM_PRESET) { [string]$env:ENGINE_LLM_PRESET } else { "local_qwen3_coder_30b" }
$engineRuntimeProfile = "fast"
if ($env:ENGINE_RUNTIME_PROFILE) {
  $parsedRuntimeProfile = ([string]$env:ENGINE_RUNTIME_PROFILE).Trim().ToLowerInvariant()
  if ($parsedRuntimeProfile -in @("fast", "normal")) {
    $engineRuntimeProfile = $parsedRuntimeProfile
  }
}
$engineEnableMultiNode = $false
if ($env:ENGINE_ENABLE_MULTI_NODE -and ([string]$env:ENGINE_ENABLE_MULTI_NODE).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) {
  $engineEnableMultiNode = $true
}
$engineSolverTimeoutSec = 180
if ($env:ENGINE_SOLVER_TIMEOUT_SEC -and [int]::TryParse([string]$env:ENGINE_SOLVER_TIMEOUT_SEC, [ref]$engineSolverTimeoutSec)) {
  if ($engineSolverTimeoutSec -lt 30) { $engineSolverTimeoutSec = 30 }
}
$engineJobMaxAgeSec = [int]([Math]::Max(120, $engineSolverTimeoutSec + 45))
if ($env:ENGINE_JOB_MAX_AGE_SEC) {
  $parsedMaxAge = 0
  if ([int]::TryParse([string]$env:ENGINE_JOB_MAX_AGE_SEC, [ref]$parsedMaxAge)) {
    if ($parsedMaxAge -ge 60) {
      $engineJobMaxAgeSec = [int]$parsedMaxAge
    }
  }
}
$enginePriorityRoutingEnabled = $true
if ($env:ENGINE_PRIORITY_ROUTING -and ([string]$env:ENGINE_PRIORITY_ROUTING).Trim().ToLowerInvariant() -in @("0", "false", "no", "off")) {
  $enginePriorityRoutingEnabled = $false
}
$enginePriorityHoldSec = 1.5
if ($env:ENGINE_PRIORITY_HOLD_SEC) {
  $parsedHold = 0.0
  if ([double]::TryParse([string]$env:ENGINE_PRIORITY_HOLD_SEC, [ref]$parsedHold)) {
    if ($parsedHold -ge 0.0 -and $parsedHold -le 30.0) {
      $enginePriorityHoldSec = [double]$parsedHold
    }
  }
}
$backendAutoStart = $true
if ($env:BACKEND_AUTOSTART -and ([string]$env:BACKEND_AUTOSTART).Trim().ToLowerInvariant() -in @("0", "false", "no", "off")) {
  $backendAutoStart = $false
}
$uiSessionId = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
$uiLogRoot = Join-Path $PSScriptRoot "5_Vision_Extraction\out\ui_session_logs"
$uiLogTextPath = Join-Path $uiLogRoot ("session_{0}.log" -f $uiSessionId)
$uiLogJsonlPath = Join-Path $uiLogRoot ("session_{0}.jsonl" -f $uiSessionId)
$uiLogLatestPath = Join-Path $uiLogRoot "latest_session.json"
$roiStatePath = Join-Path (Join-Path $env:APPDATA "PokeHerFace") "vision_tester_rois.json"
$roiAutoScale = $false
if ($env:POKE_ROI_AUTOSCALE -and ([string]$env:POKE_ROI_AUTOSCALE).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) {
  $roiAutoScale = $true
}
$rankOnlyMode = $false
if ($env:POKE_RANK_ONLY -and ([string]$env:POKE_RANK_ONLY).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) {
  $rankOnlyMode = $true
}
$ocrParallelEnabled = $true
if ($env:POKE_OCR_PARALLEL -and ([string]$env:POKE_OCR_PARALLEL).Trim().ToLowerInvariant() -in @("0", "false", "no", "off")) {
  $ocrParallelEnabled = $false
}
$ocrParallelMaxWorkers = 3
if ($env:POKE_OCR_PARALLEL_MAX_WORKERS) {
  $parsedWorkers = 0
  if ([int]::TryParse([string]$env:POKE_OCR_PARALLEL_MAX_WORKERS, [ref]$parsedWorkers)) {
    if ($parsedWorkers -ge 1 -and $parsedWorkers -le 8) {
      $ocrParallelMaxWorkers = [int]$parsedWorkers
    }
  }
}
$selectedRegion = [System.Drawing.Rectangle]::Empty
$isBusy = $false
$engineHandoffBusy = $false
$enginePendingJobs = @{}
$engineLastQueuedStateHash = ""
$engineLastCompletedStateHash = ""
$engineLastQueuedLogicalKey = ""
$engineLastCompletedLogicalKey = ""
$engineStateVersion = 0
$engineQueueReplaceCount = 0
$engineQueueSkipNoChangeCount = 0
$engineQueuePrioritySkipCount = 0
$engineQueueCompletedCount = 0
$suppressHeroAutoSend = $false
$heroCards = @{
  hero1 = "??"
  hero2 = "??"
}
$lastBoardTokens = @()
$lastHeroAutoSendKey = ""
$managedOllamaProcess = $null
$managedBridgeProcess = $null
$managedOllamaStartedByUi = $false
$managedBridgeStartedByUi = $false
$autoEnabled = $false
$overlayVisible = $true
$cardSlotOrder = @("flop1", "flop2", "flop3", "turn", "river")
$playerSlotOrder = @("hero1", "hero2")
$actionSlotOrder = @("fold_btn", "call_btn", "bet_btn", "raise_btn")
$allSlotOrder = @("flop1", "flop2", "flop3", "turn", "river", "hero1", "hero2", "fold_btn", "call_btn", "bet_btn", "raise_btn")
$cardRegions = @{}
$overlayForms = @{}
$overlayColors = @{
  board = [System.Drawing.Color]::FromArgb(40, 200, 255)
  flop1 = [System.Drawing.Color]::FromArgb(80, 230, 140)
  flop2 = [System.Drawing.Color]::FromArgb(80, 230, 140)
  flop3 = [System.Drawing.Color]::FromArgb(80, 230, 140)
  turn  = [System.Drawing.Color]::FromArgb(255, 215, 90)
  river = [System.Drawing.Color]::FromArgb(255, 150, 80)
  hero1 = [System.Drawing.Color]::FromArgb(150, 110, 255)
  hero2 = [System.Drawing.Color]::FromArgb(150, 110, 255)
  fold_btn = [System.Drawing.Color]::FromArgb(255, 86, 86)
  call_btn = [System.Drawing.Color]::FromArgb(70, 180, 255)
  bet_btn = [System.Drawing.Color]::FromArgb(110, 220, 130)
  raise_btn = [System.Drawing.Color]::FromArgb(255, 180, 70)
}
foreach ($slot in $allSlotOrder) {
  $cardRegions[$slot] = [System.Drawing.Rectangle]::Empty
}

function Get-RoiTargets {
  return $allSlotOrder
}

function Get-RoiRectByKey {
  param([string]$Key)
  if ($cardRegions.ContainsKey($Key)) {
    return (Convert-ToRectangleSafe -Value $cardRegions[$Key])
  }
  return [System.Drawing.Rectangle]::Empty
}

function Set-RoiRectByKey {
  param(
    [string]$Key,
    [System.Drawing.Rectangle]$Rect
  )
  $rectSafe = Convert-ToRectangleSafe -Value $Rect
  if ($cardRegions.ContainsKey($Key)) {
    $cardRegions[$Key] = $rectSafe
  }
}

function Clone-Flop1ToAllCardRois {
  $flop1Rect = Get-RoiRectByKey -Key "flop1"
  if (-not (Test-RegionSelected -Rect $flop1Rect)) {
    return $false
  }
  foreach ($slot in $cardSlotOrder) {
    Set-RoiRectByKey -Key $slot -Rect $flop1Rect
  }
  Save-RoiState -ForceWriteEmpty
  Refresh-RoiOverlays
  return $true
}

function Clone-Hero1ToHero2Roi {
  $heroRect = Get-RoiRectByKey -Key "hero1"
  if (-not (Test-RegionSelected -Rect $heroRect)) {
    return $false
  }
  Set-RoiRectByKey -Key "hero2" -Rect $heroRect
  Save-RoiState -ForceWriteEmpty
  Refresh-RoiOverlays
  return $true
}

function Get-EngineStateFingerprintFromJson {
  param(
    [Parameter(Mandatory = $true)][string]$JsonText
  )
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$JsonText)
      $hash = $sha.ComputeHash($bytes)
      return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
      $sha.Dispose()
    }
  }
  catch {
    return ""
  }
}

function Stop-AllEngineJobs {
  param(
    [string]$Reason = "replace_obsolete"
  )
  foreach ($jobId in @($enginePendingJobs.Keys)) {
    try { Stop-Job -Id ([int]$jobId) -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Id ([int]$jobId) -Force -ErrorAction SilentlyContinue } catch {}
    Write-Log ("Engine job {0} canceled ({1})." -f [int]$jobId, $Reason) -Type "engine_job_replaced" -Data @{
      job_id = [int]$jobId
      reason = [string]$Reason
    }
  }
  if ($enginePendingJobs.Count -gt 0) {
    $script:engineQueueReplaceCount = [int]$engineQueueReplaceCount + 1
  }
  $enginePendingJobs.Clear()
  $script:engineHandoffBusy = $false
  Update-EngineButtonState
}

function Get-ShortHash {
  param([string]$HashValue)
  $v = ([string]$HashValue).Trim().ToLowerInvariant()
  if (-not $v) { return "" }
  if ($v.Length -le 10) { return $v }
  return $v.Substring(0, 10)
}

function Get-EngineLogicalStateKey {
  param(
    [Parameter(Mandatory = $true)][string[]]$BoardTokens,
    [AllowEmptyCollection()][string[]]$HeroTokens = @(),
    [Parameter(Mandatory = $true)][string]$StageLabel
  )
  $boardNorm = @($BoardTokens | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() }) -join ","
  $heroInput = @()
  if ($null -ne $HeroTokens) {
    $heroInput = @($HeroTokens)
  }
  $heroNorm = @($heroInput | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() }) -join ","
  $stageNorm = ([string]$StageLabel).Trim().ToLowerInvariant()
  $streetNorm = "flop"
  if ($boardNorm.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Count -ge 5) {
    $streetNorm = "river"
  }
  elseif ($boardNorm.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Count -eq 4) {
    $streetNorm = "turn"
  }
  return ("street={0}|board={1}|hero={2}|stage={3}" -f $streetNorm, $boardNorm, $heroNorm, $stageNorm)
}

function Get-EngineStagePriority {
  param([string]$StageLabel)
  $stage = ([string]$StageLabel).Trim().ToLowerInvariant()
  switch ($stage) {
    "hero_auto" { return 130 }
    "manual_single" { return 120 }
    "flop" { return 110 }
    "turn" { return 80 }
    "river" { return 70 }
    default { return 50 }
  }
}

function Get-OldestPendingEngineMeta {
  if ($enginePendingJobs.Count -le 0) {
    return $null
  }
  $oldestJobId = $null
  $oldestMeta = $null
  $oldestTime = $null
  foreach ($jid in @($enginePendingJobs.Keys)) {
    $meta = $enginePendingJobs[$jid]
    if ($null -eq $meta) { continue }
    $queuedUtc = $null
    if ($meta.ContainsKey("queued_utc") -and $meta.queued_utc) {
      try { $queuedUtc = [datetime]$meta.queued_utc } catch { $queuedUtc = $null }
    }
    if ($null -eq $queuedUtc) {
      $queuedUtc = (Get-Date).ToUniversalTime()
    }
    if ($null -eq $oldestTime -or $queuedUtc -lt $oldestTime) {
      $oldestTime = $queuedUtc
      $oldestJobId = [int]$jid
      $oldestMeta = $meta
    }
  }
  if ($null -eq $oldestMeta) {
    return $null
  }
  $stage = if ($oldestMeta.ContainsKey("stage")) { [string]$oldestMeta.stage } else { "" }
  $priority = Get-EngineStagePriority -StageLabel $stage
  $ageSec = 0.0
  if ($null -ne $oldestTime) {
    $ageSec = ((Get-Date).ToUniversalTime() - $oldestTime).TotalSeconds
  }
  return [pscustomobject]@{
    job_id = [int]$oldestJobId
    stage = $stage
    priority = [int]$priority
    age_sec = [double]$ageSec
  }
}

function Should-OfferFlopClonePrompt {
  param([string]$Target)
  if (([string]$Target).Trim().ToLowerInvariant() -ne "flop1") {
    return $false
  }
  # Only prompt when board ROIs beyond flop1 are still empty.
  foreach ($slot in @("flop2", "flop3", "turn", "river")) {
    $slotRect = Get-RoiRectByKey -Key $slot
    if (Test-RegionSelected -Rect $slotRect) {
      return $false
    }
  }
  return $true
}

function Save-RoiState {
  param(
    [switch]$ForceWriteEmpty
  )
  try {
    $dir = Split-Path -Parent $roiStatePath
    if (-not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $payload = [ordered]@{}
    $payload["_meta"] = [ordered]@{
      virtual_x = [int]$virtual.X
      virtual_y = [int]$virtual.Y
      virtual_w = [int]$virtual.Width
      virtual_h = [int]$virtual.Height
      saved_utc = [DateTime]::UtcNow.ToString("o")
    }
    foreach ($key in (Get-RoiTargets)) {
      $r = Get-RoiRectByKey -Key $key
      $payload[$key] = @{
        x = [int]$r.X
        y = [int]$r.Y
        w = [int]$r.Width
        h = [int]$r.Height
      }
    }
    $json = ConvertTo-Json $payload -Depth 4
    Set-Content -Path $roiStatePath -Value $json -Encoding UTF8
  }
  catch {
    # Non-fatal.
  }
}

function Load-RoiState {
  if (-not (Test-Path $roiStatePath)) {
    return
  }
  try {
    $json = Get-Content -Path $roiStatePath -Raw -ErrorAction Stop
    $obj = $json | ConvertFrom-Json -ErrorAction Stop
    $scaleX = 1.0
    $scaleY = 1.0
    if ($roiAutoScale) {
      $meta = $obj._meta
      if ($null -ne $meta) {
        $savedW = [double]$meta.virtual_w
        $savedH = [double]$meta.virtual_h
        if ($savedW -gt 0 -and $savedH -gt 0) {
          $currentVirtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
          $scaleX = [double]$currentVirtual.Width / $savedW
          $scaleY = [double]$currentVirtual.Height / $savedH
          if ([Math]::Abs($scaleX - 1.0) -lt 0.02) { $scaleX = 1.0 }
          if ([Math]::Abs($scaleY - 1.0) -lt 0.02) { $scaleY = 1.0 }
        }
      }
    }
    foreach ($key in (Get-RoiTargets)) {
      $node = $obj.$key
      if ($null -eq $node) {
        continue
      }
      $x = [int][Math]::Round(([double]$node.x) * $scaleX)
      $y = [int][Math]::Round(([double]$node.y) * $scaleY)
      $w = [int][Math]::Round(([double]$node.w) * $scaleX)
      $h = [int][Math]::Round(([double]$node.h) * $scaleY)
      if ($w -gt 0 -and $h -gt 0) {
        Set-RoiRectByKey -Key $key -Rect (New-Object System.Drawing.Rectangle($x, $y, $w, $h))
      }
    }
  }
  catch {
    # Non-fatal.
  }
}

function Test-RegionSelected {
  param([System.Drawing.Rectangle]$Rect)
  return ($Rect.Width -gt 0 -and $Rect.Height -gt 0)
}

function Convert-ToRectangleSafe {
  param([object]$Value)
  if ($null -eq $Value) {
    return [System.Drawing.Rectangle]::Empty
  }
  if ($Value -is [System.Drawing.Rectangle]) {
    return $Value
  }
  if ($Value -is [System.Array]) {
    foreach ($item in $Value) {
      if ($item -is [System.Drawing.Rectangle]) {
        return $item
      }
    }
    return [System.Drawing.Rectangle]::Empty
  }
  try {
    return [System.Drawing.Rectangle]$Value
  }
  catch {
    return [System.Drawing.Rectangle]::Empty
  }
}

function Format-CardSlotStatus {
  $missingBoard = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $cardSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missingBoard.Add([string]$slot)
    }
  }

  $missingHero = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $playerSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missingHero.Add([string]$slot)
    }
  }

  $missingActions = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $actionSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missingActions.Add([string]$slot)
    }
  }

  $boardStatus = if ($missingBoard.Count -eq 0) { "board ready" } else { ("board missing: {0}" -f ($missingBoard -join ", ")) }
  $heroStatus = if ($missingHero.Count -eq 0) { "hero ROIs ready" } else { ("hero missing: {0}" -f ($missingHero -join ", ")) }
  $actionStatus = if ($missingActions.Count -eq 0) { "action ROIs ready" } else { ("action missing: {0}" -f ($missingActions -join ", ")) }
  return ("Card ROIs: {0} | {1} | {2}" -f $boardStatus, $heroStatus, $actionStatus)
}

function Get-HeroCardsReady {
  return ((Test-CardTokenStrict -Token $heroCards["hero1"]) -and (Test-CardTokenStrict -Token $heroCards["hero2"]))
}

function Get-HeroCardsText {
  return ("{0} {1}" -f [string]$heroCards["hero1"], [string]$heroCards["hero2"])
}

function Get-BoardReadyFromTokens {
  param([string[]]$Tokens)
  if ($Tokens.Count -lt 3 -or $Tokens.Count -gt 5) {
    return $false
  }
  foreach ($tk in $Tokens) {
    if (-not (Test-CardTokenStrict -Token $tk)) {
      return $false
    }
  }
  return $true
}

function Update-LastBoardTokenFromSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  $idx = -1
  $targetCount = 0
  if ($Slot -eq "flop1") { $idx = 0; $targetCount = 3 }
  elseif ($Slot -eq "flop2") { $idx = 1; $targetCount = 3 }
  elseif ($Slot -eq "flop3") { $idx = 2; $targetCount = 3 }
  elseif ($Slot -eq "turn") { $idx = 3; $targetCount = 4 }
  elseif ($Slot -eq "river") { $idx = 4; $targetCount = 5 }
  else { return }

  $existing = @()
  if ($lastBoardTokens -is [System.Array] -and $lastBoardTokens.Count -gt 0) {
    $existing = @($lastBoardTokens)
  }
  $arr = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $targetCount; $i++) {
    if ($i -lt $existing.Count) {
      $arr.Add([string]$existing[$i])
    }
    else {
      $arr.Add("??")
    }
  }
  if (Test-CardTokenStrict -Token $Token) {
    $arr[$idx] = ([string]$Token).Trim().ToUpperInvariant()
  }
  else {
    $arr[$idx] = "??"
  }
  $script:lastBoardTokens = @($arr)
}

function Get-BoardTokensText {
  if (-not ($lastBoardTokens -is [System.Array]) -or $lastBoardTokens.Count -eq 0) {
    return "(none)"
  }
  return (@($lastBoardTokens) -join " ")
}

function Normalize-CardToken {
  param([string]$Text)
  $v = ([string]$Text).ToUpperInvariant()
  if (-not $v) {
    return ""
  }
  $v = $v -replace "♠", "S"
  $v = $v -replace "♣", "C"
  $v = $v -replace "♥", "H"
  $v = $v -replace "♦", "D"
  $v = $v -replace "SPADES?", "S"
  $v = $v -replace "CLUBS?", "C"
  $v = $v -replace "HEARTS?", "H"
  $v = $v -replace "DIAMONDS?", "D"
  $v = $v -replace "\s+", ""
  $v = $v -replace "10", "T"
  $v = $v -replace "[^A-Z0-9]", ""
  if (-not $v) {
    return ""
  }

  $rankMatch = [regex]::Match($v, "[AKQJT98765432]")
  if (-not $rankMatch.Success) {
    return ""
  }
  $suitMatch = [regex]::Match($v, "[SHDC]")
  if (-not $suitMatch.Success) {
    return ("{0}?" -f [string]$rankMatch.Value)
  }
  return ("{0}{1}" -f [string]$rankMatch.Value, [string]$suitMatch.Value)
}

function Convert-RankFragmentToToken {
  param([string]$RankFragment)
  $r = ([string]$RankFragment).Trim().ToUpperInvariant()
  if (-not $r) { return "" }
  switch -Regex ($r) {
    "^(A|ACE)$" { return "A" }
    "^(K|KING)$" { return "K" }
    "^(Q|QUEEN)$" { return "Q" }
    "^(J|JACK)$" { return "J" }
    "^(10|T|TEN)$" { return "T" }
    "^(9|NINE)$" { return "9" }
    "^(8|EIGHT)$" { return "8" }
    "^(7|SEVEN)$" { return "7" }
    "^(6|SIX)$" { return "6" }
    "^(5|FIVE)$" { return "5" }
    "^(4|FOUR)$" { return "4" }
    "^(3|THREE)$" { return "3" }
    "^(2|TWO)$" { return "2" }
    default { return "" }
  }
}

function Convert-SuitFragmentToToken {
  param([string]$SuitFragment)
  $s = ([string]$SuitFragment).Trim().ToUpperInvariant()
  if (-not $s) { return "" }
  $s = $s -replace "[^A-Z♠♥♦♣]", ""
  switch -Regex ($s) {
    "^(S|SP|SPA|SPAD|SPADE|SPADES|♠)$" { return "S" }
    "^(H|HE|HEA|HEAR|HEART|HEARTS|♥)$" { return "H" }
    "^(D|DI|DIA|DIAM|DIAMO|DIAMON|DIAMOND|DIAMONDS|♦)$" { return "D" }
    "^(C|CL|CLU|CLUB|CLUBS|♣)$" { return "C" }
    default { return "" }
  }
}

function Extract-CardTokenFromText {
  param([string]$Text)
  $raw = ([string]$Text).Trim()
  if (-not $raw) {
    return ""
  }

  # 1) Compact token style: "Qc", "10h", "4 s"
  $compact = [regex]::Match($raw, "(?i)\b(10|[2-9TJQKA])\s*([SHDC])\b")
  if ($compact.Success) {
    $rank = Convert-RankFragmentToToken -RankFragment $compact.Groups[1].Value
    $suit = Convert-SuitFragmentToToken -SuitFragment $compact.Groups[2].Value
    if ($rank -and $suit) {
      return ("{0}{1}" -f $rank, $suit)
    }
  }

  # 2) Verbose style: "Seven of Diamonds", "4 of Sp"
  $verboseMatches = [regex]::Matches($raw, "(?i)\b(ACE|KING|QUEEN|JACK|TEN|NINE|EIGHT|SEVEN|SIX|FIVE|FOUR|THREE|TWO|10|[2-9TJQKA])\b(?:\s+OF)?\s+([A-Z♠♥♦♣]{1,12})")
  foreach ($m in $verboseMatches) {
    $rank = Convert-RankFragmentToToken -RankFragment ([string]$m.Groups[1].Value)
    $suit = Convert-SuitFragmentToToken -SuitFragment ([string]$m.Groups[2].Value)
    if ($rank -and $suit) {
      return ("{0}{1}" -f $rank, $suit)
    }
  }

  # 3) Last-resort normalization only for very short responses.
  if ($raw.Length -le 6) {
    $n = Normalize-CardToken -Text $raw
    if ($n -match "^[AKQJT98765432][SHDC]$") {
      return $n
    }
  }

  return ""
}

function Get-StrictCardTokenFromVisionText {
  param([string]$Text)
  $raw = ([string]$Text).Trim()
  if (-not $raw) {
    return ""
  }

  $direct = Extract-CardTokenFromText -Text $raw
  if ($direct -match "^[AKQJT98765432][SHDC]$") {
    return $direct
  }

  try {
    $candidateJson = $raw
    if ($raw.Contains("{") -and $raw.Contains("}")) {
      $start = $raw.IndexOf("{")
      $end = $raw.LastIndexOf("}")
      if ($end -gt $start) {
        $candidateJson = $raw.Substring($start, $end - $start + 1)
      }
    }
    $obj = $candidateJson | ConvertFrom-Json -ErrorAction Stop
    $fieldCandidates = @($obj.card, $obj.token, $obj.value)
    foreach ($value in $fieldCandidates) {
      if ($null -eq $value) { continue }
      $token = Extract-CardTokenFromText -Text ([string]$value)
      if ($token -match "^[AKQJT98765432][SHDC]$") {
        return $token
      }
    }
    if ($null -ne $obj.rank -and $null -ne $obj.suit) {
      $rank = Convert-RankFragmentToToken -RankFragment ([string]$obj.rank)
      $suit = Convert-SuitFragmentToToken -SuitFragment ([string]$obj.suit)
      if ($rank -and $suit) {
        return ("{0}{1}" -f $rank, $suit)
      }
    }
  }
  catch {
    # Non-JSON or malformed payload; leave empty.
  }

  return ""
}

function Get-OcrProfileSpec {
  param([string]$ProfileName)
  $name = [string]$ProfileName
  switch ($name) {
    "Cards (ranks/suits)" {
      return @(
        @{ psm = 10; whitelist = "AKQJT98765432shdcSHDC"; label = "cards_psm10" },
        @{ psm = 7; whitelist = "AKQJT98765432shdcSHDC"; label = "cards_psm7" },
        @{ psm = 13; whitelist = "AKQJT98765432shdcSHDC"; label = "cards_psm13" },
        @{ psm = 8; whitelist = "AKQJT98765432shdcSHDC"; label = "cards_psm8" }
      )
    }
    "Numeric (pot/stack)" {
      return @(
        @{ psm = 7; whitelist = "0123456789.,:$/"; label = "numeric_psm7" },
        @{ psm = 6; whitelist = "0123456789.,:$/"; label = "numeric_psm6" }
      )
    }
    default {
      return @(
        @{ psm = 6; whitelist = $null; label = "general_psm6" },
        @{ psm = 7; whitelist = $null; label = "general_psm7" }
      )
    }
  }
}

function Score-OcrCandidate {
  param(
    [string]$Text,
    [string]$ProfileName
  )
  $value = ([string]$Text).Trim()
  if (-not $value) {
    return 0
  }
  switch ($ProfileName) {
    "Cards (ranks/suits)" {
      # Reward valid card-ish tokens and penalize junk symbols.
      $tokenMatches = [regex]::Matches($value, "(?i)\b(?:10|[2-9TJQKA])(?:[SHDC])?\b").Count
      $junk = [regex]::Matches($value, "[^A-Za-z0-9\s]").Count
      return ($tokenMatches * 10) - $junk
    }
    "Numeric (pot/stack)" {
      $digitCount = [regex]::Matches($value, "\d").Count
      $alphaCount = [regex]::Matches($value, "[A-Za-z]").Count
      return ($digitCount * 3) - ($alphaCount * 5)
    }
    default {
      return [Math]::Min(100, $value.Length)
    }
  }
}

function New-HighContrastVariant {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$TargetPath
  )

  $src = [System.Drawing.Bitmap]::FromFile($SourcePath)
  try {
    $w = [Math]::Max(2, $src.Width * 2)
    $h = [Math]::Max(2, $src.Height * 2)
    $scaled = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($scaled)
    try {
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $g.DrawImage($src, 0, 0, $w, $h)
    }
    finally {
      $g.Dispose()
    }

    # Simple grayscale + threshold binarization.
    for ($x = 0; $x -lt $scaled.Width; $x++) {
      for ($y = 0; $y -lt $scaled.Height; $y++) {
        $c = $scaled.GetPixel($x, $y)
        $gray = [int](($c.R * 0.299) + ($c.G * 0.587) + ($c.B * 0.114))
        $v = if ($gray -ge 160) { 255 } else { 0 }
        $scaled.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($v, $v, $v))
      }
    }
    $scaled.Save($TargetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $scaled.Dispose()
  }
  finally {
    $src.Dispose()
  }
}

function Select-ScreenRegion {
  $virtualScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $state = [pscustomobject]@{
    Start = [System.Drawing.Point]::Empty
    Current = [System.Drawing.Point]::Empty
    Dragging = $false
    AnchorMode = $false
    Accepted = $false
    SelectedRect = [System.Drawing.Rectangle]::Empty
  }

  $selector = New-Object System.Windows.Forms.Form
  $selector.FormBorderStyle = "None"
  $selector.StartPosition = "Manual"
  $selector.Bounds = $virtualScreen
  $selector.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $selector.WindowState = "Normal"
  $selector.TopMost = $true
  $selector.ShowInTaskbar = $false
  $selector.BackColor = [System.Drawing.Color]::Black
  $selector.Opacity = 0.35
  $selector.Cursor = [System.Windows.Forms.Cursors]::Cross
  $selector.KeyPreview = $true

  $selector.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $selector.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
      $selector.Close()
    }
  })

  $selector.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $state.Start = $e.Location
      $state.Current = $e.Location
      $state.Dragging = $true
      $state.AnchorMode = $false
      $selector.Capture = $true
      $selector.Invalidate()
    }
    elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      if (-not $state.AnchorMode) {
        # Right-click first corner.
        $state.Start = $e.Location
        $state.Current = $e.Location
        $state.AnchorMode = $true
        $selector.Invalidate()
      }
      else {
        # Right-click second corner.
        $state.Current = $e.Location
        $x = [Math]::Min($state.Start.X, $state.Current.X)
        $y = [Math]::Min($state.Start.Y, $state.Current.Y)
        $w = [Math]::Abs($state.Start.X - $state.Current.X)
        $h = [Math]::Abs($state.Start.Y - $state.Current.Y)
        if ($w -ge 6 -and $h -ge 6) {
          $state.SelectedRect = New-Object System.Drawing.Rectangle(($x + $virtualScreen.X), ($y + $virtualScreen.Y), $w, $h)
          $state.Accepted = $true
          $selector.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
        else {
          $selector.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        }
        $selector.Close()
      }
    }
  })

  $selector.Add_MouseMove({
    param($sender, $e)
    if ($state.Dragging) {
      $state.Current = $e.Location
      $selector.Invalidate()
    }
  })

  $selector.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $state.Dragging) {
      $state.Dragging = $false
      $selector.Capture = $false
      $state.Current = $e.Location
      $x = [Math]::Min($state.Start.X, $state.Current.X)
      $y = [Math]::Min($state.Start.Y, $state.Current.Y)
      $w = [Math]::Abs($state.Start.X - $state.Current.X)
      $h = [Math]::Abs($state.Start.Y - $state.Current.Y)
      if ($w -ge 6 -and $h -ge 6) {
        # Convert selector client coords back to global screen coords.
        $state.SelectedRect = New-Object System.Drawing.Rectangle(($x + $virtualScreen.X), ($y + $virtualScreen.Y), $w, $h)
        $state.Accepted = $true
        $selector.DialogResult = [System.Windows.Forms.DialogResult]::OK
      }
      else {
        $selector.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
      }
      $selector.Close()
    }
  })

  $selector.Add_Paint({
    param($sender, $e)
    if ($state.Dragging -or $state.AnchorMode) {
      $x = [Math]::Min($state.Start.X, $state.Current.X)
      $y = [Math]::Min($state.Start.Y, $state.Current.Y)
      $w = [Math]::Abs($state.Start.X - $state.Current.X)
      $h = [Math]::Abs($state.Start.Y - $state.Current.Y)
      if ($w -gt 0 -and $h -gt 0) {
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 0, 200, 120))
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(250, 40, 230, 120), 2)
        $rect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
        $e.Graphics.FillRectangle($brush, $rect)
        $e.Graphics.DrawRectangle($pen, $rect)
        $brush.Dispose()
        $pen.Dispose()
      }
    }
  })

  $selector.Add_Shown({
    $selector.Activate()
    $selector.Focus()
  })

  [void]$selector.ShowDialog()
  if ($state.Accepted) {
    return $state.SelectedRect
  }
  return [System.Drawing.Rectangle]::Empty
}

function Capture-RegionImage {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    throw "Capture-RegionImage received an empty/invalid region."
  }
  $bmp = New-Object System.Drawing.Bitmap($Region.Width, $Region.Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bmp)
  $graphics.CopyFromScreen($Region.X, $Region.Y, 0, 0, $bmp.Size)
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose()
  $bmp.Dispose()
}

function Test-CardTokenStrict {
  param([string]$Token)
  return (([string]$Token).Trim().ToUpperInvariant() -match "^[AKQJT98765432][SHDC]$")
}

function Resolve-EngineTemplatePath {
  $p = [string]$engineSpotTemplatePath
  if (-not [System.IO.Path]::IsPathRooted($p)) {
    $p = Join-Path $PSScriptRoot $p
  }
  return [System.IO.Path]::GetFullPath($p)
}

function Build-EngineSpotPayload {
  param(
    [Parameter(Mandatory = $true)][string[]]$BoardCards,
    [string]$Label = "board",
    [string[]]$HeroCards = @()
  )
  if ($BoardCards.Count -lt 3 -or $BoardCards.Count -gt 5) {
    throw "Build-EngineSpotPayload requires 3 to 5 board cards."
  }
  foreach ($card in $BoardCards) {
    if (-not (Test-CardTokenStrict -Token $card)) {
      throw ("Invalid {0} card token for engine payload: {1}" -f $Label, $card)
    }
  }
  if ($HeroCards.Count -ne 0 -and $HeroCards.Count -ne 2) {
    throw "HeroCards must be empty or contain exactly 2 cards."
  }
  foreach ($card in $HeroCards) {
    if (-not (Test-CardTokenStrict -Token $card)) {
      throw ("Invalid hero card token for engine payload: {0}" -f $card)
    }
  }

  $templatePath = Resolve-EngineTemplatePath
  if (-not (Test-Path $templatePath)) {
    throw ("Engine spot template not found: {0}" -f $templatePath)
  }
  $templateRaw = Get-Content -Path $templatePath -Raw -Encoding UTF8
  $spot = $templateRaw | ConvertFrom-Json -ErrorAction Stop
  $spot.board = @()
  foreach ($card in $BoardCards) {
    $spot.board += ([string]$card).Trim()
  }
  if ($HeroCards.Count -eq 2) {
    if (-not ($spot.PSObject.Properties.Name -contains "meta") -or $null -eq $spot.meta) {
      $spot | Add-Member -NotePropertyName meta -NotePropertyValue @{} -Force
    }
    $spot.meta.hero_cards = @(
      ([string]$HeroCards[0]).Trim()
      ([string]$HeroCards[1]).Trim()
    )
    $spot.meta.capture_source = "vision_tester"
  }
  return $spot
}

function Get-CardPresenceSignalFromRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region
  )

  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    return [pscustomobject]@{
      likely_card = $false
      white_ratio = 0.0
      green_ratio = 0.0
      sampled = 0
    }
  }

  $bmp = $null
  $gfx = $null
  try {
    $bmp = New-Object System.Drawing.Bitmap($Region.Width, $Region.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($Region.X, $Region.Y, 0, 0, $bmp.Size)

    [int]$white = 0
    [int]$green = 0
    [int]$total = 0

    # Sample every other pixel for speed.
    for ($y = 0; $y -lt $bmp.Height; $y += 2) {
      for ($x = 0; $x -lt $bmp.Width; $x += 2) {
        $px = $bmp.GetPixel($x, $y)
        [int]$r = $px.R
        [int]$g = $px.G
        [int]$b = $px.B
        $total += 1

        if ($r -ge 175 -and $g -ge 175 -and $b -ge 175) {
          $white += 1
        }
        if ($g -ge 70 -and $g -ge ($r + 20) -and $g -ge ($b + 10)) {
          $green += 1
        }
      }
    }

    if ($total -le 0) {
      return [pscustomobject]@{
        likely_card = $false
        white_ratio = 0.0
        green_ratio = 0.0
        sampled = 0
      }
    }

    $whiteRatio = [double]$white / [double]$total
    $greenRatio = [double]$green / [double]$total

    # Conservative "no card" rule: little white card-face signal + strong felt signal.
    $likelyCard = $true
    if ($whiteRatio -lt 0.10 -and $greenRatio -gt 0.60) {
      $likelyCard = $false
    }

    return [pscustomobject]@{
      likely_card = $likelyCard
      white_ratio = [double]$whiteRatio
      green_ratio = [double]$greenRatio
      sampled = [int]$total
    }
  }
  catch {
    return [pscustomobject]@{
      likely_card = $true
      white_ratio = 0.0
      green_ratio = 0.0
      sampled = 0
    }
  }
  finally {
    if ($null -ne $gfx) {
      $gfx.Dispose()
    }
    if ($null -ne $bmp) {
      $bmp.Dispose()
    }
  }
}

function Get-BestOcrForRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$ProfileName,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$Tag
  )
  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    return $null
  }
  $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
  $imgPath = Join-Path $TmpDir ("capture_{0}_{1}.png" -f $Tag, $stamp)
  Capture-RegionImage -Region $Region -Path $imgPath

  $specs = Get-OcrProfileSpec -ProfileName $ProfileName
  $variantPaths = New-Object System.Collections.Generic.List[string]
  [void]$variantPaths.Add([string]$imgPath)
  $contrastPath = Join-Path $TmpDir ("capture_{0}_{1}.contrast.png" -f $Tag, $stamp)
  try {
    New-HighContrastVariant -SourcePath $imgPath -TargetPath $contrastPath
    [void]$variantPaths.Add([string]$contrastPath)
  }
  catch {
    Write-Log ("Preprocess warning ({0}): {1}" -f $Tag, $_.Exception.Message)
  }

  $bestText = ""
  $bestScore = [int]::MinValue
  $bestLabel = ""
  $bestVariant = ""
  $attempt = 0

  foreach ($variant in $variantPaths) {
    foreach ($spec in $specs) {
      $attempt += 1
      $outBase = Join-Path $TmpDir ("capture_{0}_{1}.try{2}" -f $Tag, $stamp, $attempt)
      $cmd = New-Object System.Collections.Generic.List[string]
      [void]$cmd.Add([string]$variant)
      [void]$cmd.Add([string]$outBase)
      [void]$cmd.Add("--oem")
      [void]$cmd.Add("1")
      [void]$cmd.Add("--psm")
      [void]$cmd.Add([string]$spec.psm)
      if ($spec.whitelist) {
        [void]$cmd.Add("-c")
        [void]$cmd.Add(("tessedit_char_whitelist={0}" -f [string]$spec.whitelist))
      }
      $null = & $tesseractExe @cmd 2>$null
      $txtPath = "$outBase.txt"
      if (-not (Test-Path $txtPath)) {
        continue
      }
      $raw = Get-Content $txtPath -Raw -ErrorAction SilentlyContinue
      $candidateText = if ($raw -is [System.Array]) { ($raw -join [Environment]::NewLine) } else { [string]$raw }
      $candidateScore = Score-OcrCandidate -Text $candidateText -ProfileName $ProfileName
      if ($candidateScore -gt $bestScore) {
        $bestScore = $candidateScore
        $bestText = $candidateText
        $bestLabel = [string]$spec.label
        $bestVariant = [IO.Path]::GetFileName($variant)
      }
    }
  }

  if (-not $bestText) {
    return $null
  }

  return [pscustomobject]@{
    text = $bestText
    label = $bestLabel
    variant = $bestVariant
    score = $bestScore
  }
}

function Get-CardTokenScore {
  param([string]$Token)
  $t = ([string]$Token).Trim().ToUpperInvariant()
  if (-not $t) {
    return -1000
  }
  if ($t -match "^[AKQJT98765432][SHDC]$") {
    return 100
  }
  if ($t -match "^[AKQJT98765432]\?$") {
    return 60
  }
  if ($t -match "^[AKQJT98765432]$") {
    return 50
  }
  return 0
}

function Convert-ToRankOnlyToken {
  param([string]$Token)
  $t = ([string]$Token).Trim().ToUpperInvariant()
  if ($t -match "^[AKQJT98765432][SHDC]$") {
    return ("{0}?" -f $t.Substring(0, 1))
  }
  if ($t -match "^[AKQJT98765432]\?$") {
    return $t
  }
  if ($t -match "^[AKQJT98765432]$") {
    return ("{0}?" -f $t)
  }
  return "??"
}

function Get-VisionSourceBonus {
  param([string]$SourceTag)
  switch (([string]$SourceTag).Trim().ToLowerInvariant()) {
    "rankcrop2" { return 30 }
    "rankcrop3" { return 24 }
    "rankcrop1" { return 16 }
    "full" { return 0 }
    default { return 0 }
  }
}

function Get-VisionRawPenalty {
  param([string]$RawText)
  $raw = ([string]$RawText).Trim()
  if (-not $raw) {
    return -20
  }

  $penalty = 0
  # Penalize long prose responses; they correlate with hallucinated card guesses.
  if ($raw.Length -gt 28) {
    $penalty -= 12
  }
  if ($raw -match "(?i)\b(the|card|visible|shown|image|from a|provided)\b") {
    $penalty -= 12
  }
  return $penalty
}

function Get-CardSuitHintFromRegionColor {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region
  )

  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    return $null
  }

  if ($Region.Width -lt 12 -or $Region.Height -lt 16) {
    return $null
  }

  $bmp = $null
  $gfx = $null
  try {
    $bmp = New-Object System.Drawing.Bitmap($Region.Width, $Region.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($Region.X, $Region.Y, 0, 0, $bmp.Size)

    # Detect likely card face via near-white pixels first. This reduces table-color bleed.
    [int]$w = [int]$Region.Width
    [int]$h = [int]$Region.Height
    [int]$minX = $w
    [int]$minY = $h
    [int]$maxX = -1
    [int]$maxY = -1
    [int]$lightCount = 0
    for ($y = 0; $y -lt $h; $y += 2) {
      for ($x = 0; $x -lt $w; $x += 2) {
        $px = $bmp.GetPixel($x, $y)
        if ($px.R -ge 175 -and $px.G -ge 175 -and $px.B -ge 175) {
          if ($x -lt $minX) { $minX = $x }
          if ($y -lt $minY) { $minY = $y }
          if ($x -gt $maxX) { $maxX = $x }
          if ($y -gt $maxY) { $maxY = $y }
          $lightCount += 1
        }
      }
    }

    [int]$cardX = 0
    [int]$cardY = 0
    [int]$cardW = $w
    [int]$cardH = $h
    if ($lightCount -ge 18 -and $maxX -gt $minX -and $maxY -gt $minY) {
      $cardX = [int][Math]::Max(0, $minX - 2)
      $cardY = [int][Math]::Max(0, $minY - 2)
      $cardW = [int][Math]::Min($w - $cardX, ($maxX - $minX + 5))
      $cardH = [int][Math]::Min($h - $cardY, ($maxY - $minY + 5))
    }

    # Focus on most of card face (exclude bottom where chips often overlap).
    [int]$sampleX = [int][Math]::Max(0, $cardX + [int]($cardW * 0.04))
    [int]$sampleY = [int][Math]::Max(0, $cardY + [int]($cardH * 0.04))
    [int]$sampleW = [int][Math]::Max(10, [int]($cardW * 0.90))
    [int]$sampleH = [int][Math]::Max(12, [int]($cardH * 0.74))
    if (($sampleX + $sampleW) -gt $w) {
      $sampleW = [int][Math]::Max(1, $w - $sampleX)
    }
    if (($sampleY + $sampleH) -gt $h) {
      $sampleH = [int][Math]::Max(1, $h - $sampleY)
    }

    $scores = @{
      H = 0.0  # red hearts
      D = 0.0  # blue diamonds
      C = 0.0  # green clubs
      S = 0.0  # black spades
    }
    $classified = 0

    for ($y = $sampleY; $y -lt ($sampleY + $sampleH); $y += 1) {
      for ($x = $sampleX; $x -lt ($sampleX + $sampleW); $x += 1) {
        $px = $bmp.GetPixel($x, $y)
        [int]$r = $px.R
        [int]$g = $px.G
        [int]$b = $px.B

        [int]$max = [Math]::Max($r, [Math]::Max($g, $b))
        [int]$min = [Math]::Min($r, [Math]::Min($g, $b))
        [int]$sat = $max - $min
        [int]$lum = [int](($r + $g + $b) / 3)

        # Ignore white card background.
        if ($lum -ge 238 -and $sat -le 20) {
          continue
        }

        # Spades/black suit symbols.
        if ($lum -le 95 -and $sat -le 65) {
          $scores["S"] += 2.6
          $classified += 1
          continue
        }
        if ($lum -le 78) {
          $scores["S"] += 1.2
          $classified += 1
          continue
        }

        # Four-color deck heuristics used by many poker clients:
        # hearts=red, diamonds=blue, clubs=green, spades=black/dark.
        if ($r -ge 120 -and $r -ge ($g + 22) -and $r -ge ($b + 22)) {
          $scores["H"] += 3.0
          $classified += 1
          continue
        }
        if ($b -ge 105 -and $b -ge ($r + 16) -and $b -ge ($g + 10)) {
          $scores["D"] += 3.0
          $classified += 1
          continue
        }
        if ($g -ge 105 -and $g -ge ($r + 16) -and $g -ge ($b + 9)) {
          $scores["C"] += 2.6
          $classified += 1
          continue
        }
      }
    }

    if ($classified -lt 8) {
      return $null
    }

    $ordered = @(
      [pscustomobject]@{ suit = "H"; score = [double]$scores["H"] }
      [pscustomobject]@{ suit = "D"; score = [double]$scores["D"] }
      [pscustomobject]@{ suit = "C"; score = [double]$scores["C"] }
      [pscustomobject]@{ suit = "S"; score = [double]$scores["S"] }
    ) | Sort-Object -Property score -Descending

    if ($ordered.Count -lt 1) {
      return $null
    }
    $top = $ordered[0]
    $secondScore = if ($ordered.Count -ge 2) { [double]$ordered[1].score } else { 0.0 }
    if ($top.score -lt 10.0) {
      return $null
    }

    $confidence = if ($secondScore -gt 0) { [double]($top.score / $secondScore) } else { 9.99 }
    if ($confidence -lt 1.14) {
      return $null
    }

    return [pscustomobject]@{
      suit = [string]$top.suit
      score = [double]$top.score
      confidence = [double]$confidence
    }
  }
  catch {
    return $null
  }
  finally {
    if ($null -ne $gfx) {
      $gfx.Dispose()
    }
    if ($null -ne $bmp) {
      $bmp.Dispose()
    }
  }
}

function Apply-SuitHintOverride {
  param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region
  )

  $t = ([string]$Token).Trim().ToUpperInvariant()
  if ($t -notmatch "^[AKQJT98765432][SHDC]$") {
    return [pscustomobject]@{
      token = $t
      changed = $false
      reason = ""
    }
  }

  $hint = Get-CardSuitHintFromRegionColor -Region $Region
  if ($null -eq $hint -or -not $hint.suit) {
    return [pscustomobject]@{
      token = $t
      changed = $false
      reason = ""
    }
  }

  $hintSuit = ([string]$hint.suit).ToUpperInvariant()
  $tokenSuit = $t.Substring(1, 1).ToUpperInvariant()
  $rank = $t.Substring(0, 1)
  if ($hintSuit -eq $tokenSuit) {
    return [pscustomobject]@{
      token = $t
      changed = $false
      reason = ""
    }
  }

  # Bias fix: model frequently defaults to clubs when uncertain.
  $clubBiasOverride = ($tokenSuit -eq "C" -and $hintSuit -ne "C" -and [double]$hint.score -ge 9.0 -and [double]$hint.confidence -ge 1.10)
  $strongOverride = ([double]$hint.score -ge 10.0 -and [double]$hint.confidence -ge 1.12)
  if (-not ($clubBiasOverride -or $strongOverride)) {
    return [pscustomobject]@{
      token = $t
      changed = $false
      reason = ""
    }
  }

  $newToken = ("{0}{1}" -f $rank, $hintSuit)
  return [pscustomobject]@{
    token = $newToken
    changed = $true
    reason = ("color hint {0} (score={1:N2}, conf={2:N2})" -f $hintSuit, [double]$hint.score, [double]$hint.confidence)
  }
}

function Resolve-BoardCardCollisions {
  param(
    [hashtable]$Cards,
    [hashtable]$CardScores
  )

  $slotsByToken = @{}
  foreach ($slot in $cardSlotOrder) {
    $token = ([string]$Cards[$slot]).Trim().ToUpperInvariant()
    if ($token -notmatch "^[AKQJT98765432][SHDC]$") {
      continue
    }
    if (-not $slotsByToken.ContainsKey($token)) {
      $slotsByToken[$token] = New-Object System.Collections.Generic.List[string]
    }
    [void]$slotsByToken[$token].Add($slot)
  }

  $warnings = New-Object System.Collections.Generic.List[string]
  foreach ($token in $slotsByToken.Keys) {
    $slots = $slotsByToken[$token]
    if ($slots.Count -le 1) {
      continue
    }

    # Try to recover duplicate exact-token collisions by re-inferring suit from ROI colors.
    # This helps when vision gets rank correct but confuses suit on nearby duplicate ranks.
    $rank = [string]$token.Substring(0, 1)
    foreach ($slot in $slots) {
      $slotRect = Get-RoiRectByKey -Key $slot
      if (-not (Test-RegionSelected -Rect $slotRect)) {
        continue
      }
      $hint = Get-CardSuitHintFromRegionColor -Region $slotRect
      if ($null -eq $hint -or -not $hint.suit) {
        continue
      }
      $candidateToken = ("{0}{1}" -f $rank, ([string]$hint.suit).ToUpperInvariant())
      if ($candidateToken -match "^[AKQJT98765432][SHDC]$" -and $candidateToken -ne $Cards[$slot]) {
        $Cards[$slot] = $candidateToken
        $baseScore = if ($CardScores.ContainsKey($slot)) { [int]$CardScores[$slot] } else { 0 }
        $CardScores[$slot] = [Math]::Max($baseScore, 95)
        [void]$warnings.Add(("Suit recovery adjusted {0}: {1} -> {2} (color confidence {3:N2})." -f $slot, $token, $candidateToken, [double]$hint.confidence))
      }
    }

    # Recompute duplicates after suit recovery. If collision remains, keep strongest and clear rest.
    $freshSlots = New-Object System.Collections.Generic.List[string]
    foreach ($slot in $slots) {
      $currentToken = ([string]$Cards[$slot]).Trim().ToUpperInvariant()
      if ($currentToken -eq $token) {
        [void]$freshSlots.Add($slot)
      }
    }
    if ($freshSlots.Count -le 1) {
      continue
    }

    $keepSlot = $freshSlots[0]
    $keepScore = if ($CardScores.ContainsKey($keepSlot)) { [int]$CardScores[$keepSlot] } else { -100000 }
    foreach ($slot in $freshSlots) {
      $score = if ($CardScores.ContainsKey($slot)) { [int]$CardScores[$slot] } else { -100000 }
      if ($score -gt $keepScore) {
        $keepScore = $score
        $keepSlot = $slot
      }
    }
    foreach ($slot in $freshSlots) {
      if ($slot -ne $keepSlot) {
        $Cards[$slot] = "??"
      }
    }
    [void]$warnings.Add(("Duplicate card token {0} detected in {1}; kept {2}, cleared others to ??." -f $token, ($freshSlots -join ","), $keepSlot))
  }

  return [pscustomobject]@{
    cards = $Cards
    warnings = $warnings
  }
}

function Get-CardTokenFromRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$SlotTag
  )
  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    return $null
  }

  try {
    $regions = New-Object System.Collections.Generic.List[object]
    [void]$regions.Add([pscustomobject]@{ tag = "full"; rect = $Region })

    if ($Region.Width -ge 20 -and $Region.Height -ge 20) {
      [int]$x = [int](@($Region.X)[0])
      [int]$y = [int](@($Region.Y)[0])
      [int]$w = [int](@($Region.Width)[0])
      [int]$h = [int](@($Region.Height)[0])
      [void]$regions.Add([pscustomobject]@{
        tag = "rankcrop1"
        rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.60)), [Math]::Max(8, [int]($h * 0.70)))
      })
      [void]$regions.Add([pscustomobject]@{
        tag = "rankcrop2"
        rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.45)), [Math]::Max(8, [int]($h * 0.52)))
      })
      [int]$xOffset = [Math]::Max(0, [int]($w * 0.03))
      [int]$yOffset = [Math]::Max(0, [int]($h * 0.05))
      [int]$cropW = [Math]::Max(8, [int]($w * 0.55))
      [int]$cropH = [Math]::Max(8, [int]($h * 0.65))
      [void]$regions.Add([pscustomobject]@{
        tag = "rankcrop3"
        rect = New-Object System.Drawing.Rectangle(
          [int]($x + $xOffset),
          [int]($y + $yOffset),
          $cropW,
          $cropH
        )
      })
    }

    $bestToken = ""
    $bestRawText = ""
    $bestLabel = ""
    $bestVariant = ""
    $bestSource = ""
    $bestScore = -100000

    foreach ($entry in $regions) {
      $best = Get-BestOcrForRegion -Region $entry.rect -ProfileName "Cards (ranks/suits)" -TmpDir $TmpDir -Tag ("{0}_{1}" -f $SlotTag, $entry.tag)
      if (-not $best) {
        continue
      }
      $rawText = if ($best.text -is [System.Array]) {
        [string]::Join([Environment]::NewLine, ($best.text | ForEach-Object { [string]$_ }))
      }
      else {
        [string]$best.text
      }
      $rawText = $rawText.Trim()
      $token = Extract-CardTokenFromText -Text $rawText
      $tokenScore = Get-CardTokenScore -Token $token
      $combinedScore = [int]$tokenScore + [int]$best.score
      if ($combinedScore -gt $bestScore) {
        $bestScore = $combinedScore
        $bestToken = $token
        $bestRawText = $rawText
        $bestLabel = [string]$best.label
        $bestVariant = [string]$best.variant
        $bestSource = [string]$entry.tag
      }
    }

    if (-not $bestRawText) {
      return $null
    }

    if (-not $bestToken) {
      $bestToken = "??"
    }

    return [pscustomobject]@{
      token = $bestToken
      raw_text = $bestRawText
      label = $bestLabel
      variant = $bestVariant
      source = $bestSource
      score = $bestScore
    }
  }
  catch {
    Write-Log ("Card OCR internal error ({0}): {1}" -f $SlotTag, $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("Card OCR internal error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
    return $null
  }
}

function Invoke-OllamaVisionCard {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath
  )
  $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
  $b64 = [Convert]::ToBase64String($bytes)
  $prompt = 'Read exactly one poker community card from this image crop. Return JSON only with key: {"card":"??"}. Replace ?? with a valid rank+suit token only when clearly visible, using ranks AKQJT98765432 and suits shdc (for example Qd, Tc, 7h). If uncertain keep ??. Do not guess and do not default to any fixed card. No prose.'
  $payload = @{
    model = $ollamaVisionModel
    prompt = $prompt
    images = @($b64)
    stream = $false
    keep_alive = $ollamaVisionKeepAlive
    format = "json"
    options = @{
      temperature = 0
      top_p = 0.1
      num_predict = 32
    }
  }
  $jsonBody = ConvertTo-Json $payload -Depth 8 -Compress
  $resp = Invoke-RestMethod -Uri ("{0}/api/generate" -f $ollamaHost.TrimEnd("/")) -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec 90
  if ($null -eq $resp) {
    return ""
  }
  if ($resp.response -is [System.Array]) {
    return [string]::Join(" ", ($resp.response | ForEach-Object { [string]$_ }))
  }
  return [string]$resp.response
}

function Invoke-OllamaVisionCardRelaxed {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath
  )
  $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
  $b64 = [Convert]::ToBase64String($bytes)
  $prompt = "Read exactly one poker community card from this image crop. Output one token only in rank+suit form using AKQJT98765432 and shdc (examples: Qd, Tc, 7h). No prose."
  $payload = @{
    model = $ollamaVisionModel
    prompt = $prompt
    images = @($b64)
    stream = $false
    keep_alive = $ollamaVisionKeepAlive
    options = @{
      temperature = 0
      top_p = 0.2
      num_predict = 12
    }
  }
  $jsonBody = ConvertTo-Json $payload -Depth 8 -Compress
  $resp = Invoke-RestMethod -Uri ("{0}/api/generate" -f $ollamaHost.TrimEnd("/")) -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec 90
  if ($null -eq $resp) {
    return ""
  }
  if ($resp.response -is [System.Array]) {
    return [string]::Join(" ", ($resp.response | ForEach-Object { [string]$_ }))
  }
  return [string]$resp.response
}

function Test-OllamaEndpoint {
  try {
    $null = Invoke-RestMethod -Uri ("{0}/api/tags" -f $ollamaHost.TrimEnd("/")) -Method Get -TimeoutSec 5
    return $true
  }
  catch {
    return $false
  }
}

function Release-OllamaVisionModel {
  try {
    if (-not (Test-OllamaEndpoint)) {
      return
    }
    $payload = @{
      model = $ollamaVisionModel
      prompt = ""
      stream = $false
      keep_alive = "0s"
      options = @{
        num_predict = 0
      }
    }
    $jsonBody = ConvertTo-Json $payload -Depth 6 -Compress
    $null = Invoke-RestMethod -Uri ("{0}/api/generate" -f $ollamaHost.TrimEnd("/")) -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec 12
  }
  catch {
    # Best effort only.
  }
}

function Get-CardTokenFromVisionRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$SlotTag,
    [switch]$FastMode
  )
  try {
    $Region = Convert-ToRectangleSafe -Value $Region
    if ($Region.Width -le 0 -or $Region.Height -le 0) {
      return $null
    }

    $regions = New-Object System.Collections.Generic.List[object]
    if ($Region.Width -ge 20 -and $Region.Height -ge 20) {
      [int]$x = [int](@($Region.X)[0])
      [int]$y = [int](@($Region.Y)[0])
      [int]$w = [int](@($Region.Width)[0])
      [int]$h = [int](@($Region.Height)[0])
      if ($FastMode) {
        [void]$regions.Add([pscustomobject]@{
          tag = "rankcrop2"
          rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.45)), [Math]::Max(8, [int]($h * 0.52)))
        })
      }
      else {
        [void]$regions.Add([pscustomobject]@{
          tag = "rankcrop1"
          rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.60)), [Math]::Max(8, [int]($h * 0.70)))
        })
        [void]$regions.Add([pscustomobject]@{
          tag = "rankcrop2"
          rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.45)), [Math]::Max(8, [int]($h * 0.52)))
        })
        [void]$regions.Add([pscustomobject]@{
          tag = "rankcrop3"
          rect = New-Object System.Drawing.Rectangle(
            [int]($x + [Math]::Max(0, [int]($w * 0.03))),
            [int]($y + [Math]::Max(0, [int]($h * 0.05))),
            [Math]::Max(8, [int]($w * 0.55)),
            [Math]::Max(8, [int]($h * 0.65))
          )
        })
      }
    }
    # Evaluate full card last. Rank-corner crops are generally more reliable.
    [void]$regions.Add([pscustomobject]@{ tag = "full"; rect = $Region })

    $bestToken = ""
    $bestRaw = ""
    $bestSource = ""
    $bestVariant = ""
    $bestScore = -100000
    $candidateRows = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $regions) {
      $entryRect = Convert-ToRectangleSafe -Value $entry.rect
      if ($entryRect.Width -le 0 -or $entryRect.Height -le 0) {
        continue
      }
      $entryTag = [string](@($entry.tag)[0])
      $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
      $imgPath = Join-Path $TmpDir ("vision_{0}_{1}_{2}.png" -f $SlotTag, $entryTag, $stamp)
      Capture-RegionImage -Region $entryRect -Path $imgPath
      $imagePaths = New-Object System.Collections.Generic.List[string]
      [void]$imagePaths.Add([string]$imgPath)
      if (-not $FastMode) {
        $contrastPath = Join-Path $TmpDir ("vision_{0}_{1}_{2}.contrast.png" -f $SlotTag, $entryTag, $stamp)
        try {
          New-HighContrastVariant -SourcePath $imgPath -TargetPath $contrastPath
          [void]$imagePaths.Add([string]$contrastPath)
        }
        catch {
          Write-Log ("Vision preprocess warning ({0}): {1}" -f $SlotTag, $_.Exception.Message)
        }
      }

      foreach ($candidatePath in $imagePaths) {
        try {
          $raw = Invoke-OllamaVisionCard -ImagePath $candidatePath
        }
        catch {
          Write-Log ("Vision call warning ({0}): {1}" -f $SlotTag, $_.Exception.Message)
          continue
        }
      $rawText = ([string]$raw).Trim()
      $token = ""
      if ($rawText) {
        $token = Get-StrictCardTokenFromVisionText -Text $rawText
      }
      if (-not $FastMode -and $token -notmatch "^[AKQJT98765432][SHDC]$") {
        try {
          $rawRelaxed = Invoke-OllamaVisionCardRelaxed -ImagePath $candidatePath
          $rawRelaxedText = ([string]$rawRelaxed).Trim()
          if ($rawRelaxedText) {
            $candidateToken = Get-StrictCardTokenFromVisionText -Text $rawRelaxedText
            if ($candidateToken -match "^[AKQJT98765432][SHDC]$") {
              $rawText = $rawRelaxedText
              $token = $candidateToken
            }
          }
        }
        catch {
          # Best-effort relaxed pass.
        }
      }
      if ($token -notmatch "^[AKQJT98765432][SHDC]$") {
        # Ignore prose/malformed responses; only accept strict rank+suit.
        continue
      }
        $tokenScore = Get-CardTokenScore -Token $token
        $sourceBonus = Get-VisionSourceBonus -SourceTag $entryTag
        $rawPenalty = Get-VisionRawPenalty -RawText $rawText
        $suitScore = 0
        $hint = Get-CardSuitHintFromRegionColor -Region $entryRect
        if ($null -ne $hint -and $hint.suit) {
          $tokenSuit = ([string]$token).Substring(1, 1).ToUpperInvariant()
          if ($tokenSuit -eq ([string]$hint.suit).ToUpperInvariant()) {
            $suitScore += 8
          }
          else {
            $suitScore -= 10
          }
        }
        $candidateScore = [int]$tokenScore + [int]$sourceBonus + [int]$rawPenalty + [int]$suitScore
        [void]$candidateRows.Add([pscustomobject]@{
          token = [string]$token
          score = [int]$candidateScore
          source = [string]$entryTag
          variant = [System.IO.Path]::GetFileName($candidatePath)
          raw = [string]$rawText
        })
        if ($candidateScore -gt $bestScore) {
          $bestScore = $candidateScore
          $bestToken = $token
          $bestRaw = $rawText
          $bestSource = $entryTag
          $bestVariant = [System.IO.Path]::GetFileName($candidatePath)
        }
      }
    }

    if ($candidateRows.Count -eq 0) {
      return $null
    }

    # Weighted consensus across all valid candidates (rank first, then suit).
    $rankTotals = @{}
    foreach ($row in $candidateRows) {
      $token = ([string]$row.token).Trim().ToUpperInvariant()
      if ($token -notmatch "^[AKQJT98765432][SHDC]$") { continue }
      $rank = $token.Substring(0, 1)
      if (-not $rankTotals.ContainsKey($rank)) {
        $rankTotals[$rank] = 0
      }
      $rankTotals[$rank] = [int]$rankTotals[$rank] + [int]$row.score
    }

    $chosenRank = ""
    $rankBest = -100000
    foreach ($rank in $rankTotals.Keys) {
      $rs = [int]$rankTotals[$rank]
      if ($rs -gt $rankBest) {
        $rankBest = $rs
        $chosenRank = [string]$rank
      }
    }

    $chosenSuit = ""
    $suitBest = -100000
    if ($chosenRank) {
      $suitTotals = @{}
      foreach ($row in $candidateRows) {
        $token = ([string]$row.token).Trim().ToUpperInvariant()
        if ($token -notmatch "^[AKQJT98765432][SHDC]$") { continue }
        if ($token.Substring(0, 1) -ne $chosenRank) { continue }
        $suit = $token.Substring(1, 1)
        if (-not $suitTotals.ContainsKey($suit)) {
          $suitTotals[$suit] = 0
        }
        $suitTotals[$suit] = [int]$suitTotals[$suit] + [int]$row.score
      }
      foreach ($suit in $suitTotals.Keys) {
        $ss = [int]$suitTotals[$suit]
        if ($ss -gt $suitBest) {
          $suitBest = $ss
          $chosenSuit = [string]$suit
        }
      }
    }

    if ($chosenRank -and $chosenSuit) {
      $bestToken = ("{0}{1}" -f $chosenRank, $chosenSuit)
      $bestScore = [int]([Math]::Max($rankBest, $suitBest))
    }

    if (-not $bestRaw) {
      # fall back to top-scored candidate for preview/source context
      foreach ($row in $candidateRows | Sort-Object -Property score -Descending) {
        $bestRaw = [string]$row.raw
        $bestSource = [string]$row.source
        $bestVariant = [string]$row.variant
        break
      }
    }

    # Strong per-slot suit correction from ROI color (suits are mandatory for engine input).
    if ($bestToken -match "^[AKQJT98765432][SHDC]$") {
      $hint = Get-CardSuitHintFromRegionColor -Region $Region
      if ($null -ne $hint -and $hint.suit) {
        $hintSuit = ([string]$hint.suit).ToUpperInvariant()
        $tokenSuit = $bestToken.Substring(1, 1).ToUpperInvariant()
        if ($hint.score -ge 10.0 -and $hint.confidence -ge 1.12 -and $hintSuit -ne $tokenSuit) {
          $bestToken = ("{0}{1}" -f $bestToken.Substring(0, 1), $hintSuit)
        }
      }
    }

    if (-not $bestRaw) {
      return $null
    }

    return [pscustomobject]@{
      token = $bestToken
      raw_text = $bestRaw
      label = "vision_llava"
      variant = $bestVariant
      source = $bestSource
      score = $bestScore
    }
  }
  catch {
    Write-Log ("Card vision internal error ({0}): {1}" -f $SlotTag, $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("Card vision internal error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
    return $null
  }
}

function Get-BoardTokenScore {
  param([string]$Token)
  $t = ([string]$Token).Trim().ToUpperInvariant()
  if ($t -match "^[AKQJT98765432][SHDC]$") { return 100 }
  if ($t -match "^[AKQJT98765432]\?$") { return 60 }
  if ($t -eq "??") { return 0 }
  return -20
}

function Parse-BoardTokensFromText {
  param([string]$Text)
  $slots = @("flop1", "flop2", "flop3", "turn", "river")
  $cards = @{}
  foreach ($s in $slots) { $cards[$s] = "??" }
  $raw = ([string]$Text).Trim()
  if (-not $raw) {
    return $cards
  }

  # Prefer strict JSON contract if model follows prompt.
  try {
    $candidateJson = $raw
    if ($raw.Contains("{") -and $raw.Contains("}")) {
      $start = $raw.IndexOf("{")
      $end = $raw.LastIndexOf("}")
      if ($end -gt $start) {
        $candidateJson = $raw.Substring($start, $end - $start + 1)
      }
    }
    $obj = $candidateJson | ConvertFrom-Json -ErrorAction Stop
    foreach ($s in $slots) {
      if ($null -ne $obj.$s) {
        $token = Extract-CardTokenFromText -Text ([string]$obj.$s)
        if ($token) { $cards[$s] = $token }
      }
    }
    return $cards
  }
  catch {
    # fall through to regex extraction
  }

  # Fallback: extract up to 5 cards from free text.
  $pattern = "(?i)(10|[2-9TJQKA])\s*(?:OF\s*)?(SPADES?|HEARTS?|DIAMONDS?|CLUBS?|[SHDC♠♥♦♣])"
  $matches = [regex]::Matches($raw, $pattern)
  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($m in $matches) {
    $rank = [string]$m.Groups[1].Value
    $suit = [string]$m.Groups[2].Value
    $token = Extract-CardTokenFromText -Text ("{0} {1}" -f $rank, $suit)
    if ($token) { [void]$tokens.Add($token) }
  }
  if ($tokens.Count -eq 0) {
    # Try compact tokens like "As Kd 7h"
    $m2 = [regex]::Matches($raw, "(?i)\b(10|[2-9TJQKA])\s*([SHDC])\b")
    foreach ($m in $m2) {
      $token = Extract-CardTokenFromText -Text ("{0} {1}" -f [string]$m.Groups[1].Value, [string]$m.Groups[2].Value)
      if ($token) { [void]$tokens.Add($token) }
    }
  }
  for ($i = 0; $i -lt [Math]::Min(5, $tokens.Count); $i++) {
    $cards[$slots[$i]] = $tokens[$i]
  }
  return $cards
}

function Invoke-OllamaVisionBoard {
  param([Parameter(Mandatory = $true)][string]$ImagePath)
  $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
  $b64 = [Convert]::ToBase64String($bytes)
  $prompt = "Read only the community cards shown in this poker table image from left to right. Return JSON only with exact keys: {""flop1"":""??"",""flop2"":""??"",""flop3"":""??"",""turn"":""??"",""river"":""??""}. Use rank+suit with ranks AKQJT98765432 and suits s h d c (example As, Td, 7h). Use ?? for missing/hidden cards. No prose."
  $payload = @{
    model = $ollamaVisionModel
    prompt = $prompt
    images = @($b64)
    stream = $false
    keep_alive = $ollamaVisionKeepAlive
    options = @{
      temperature = 0
      top_p = 0.1
      num_predict = 200
    }
  }
  $jsonBody = ConvertTo-Json $payload -Depth 8 -Compress
  $resp = Invoke-RestMethod -Uri ("{0}/api/generate" -f $ollamaHost.TrimEnd("/")) -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec 120
  if ($null -eq $resp) { return "" }
  if ($resp.response -is [System.Array]) {
    return [string]::Join(" ", ($resp.response | ForEach-Object { [string]$_ }))
  }
  return [string]$resp.response
}

function Get-BoardTokensFromVisionRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$TmpDir
  )
  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    return $null
  }
  $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
  $imgPath = Join-Path $TmpDir ("board_{0}.png" -f $stamp)
  Capture-RegionImage -Region $Region -Path $imgPath
  $variants = New-Object System.Collections.Generic.List[string]
  [void]$variants.Add($imgPath)
  $contrast = Join-Path $TmpDir ("board_{0}.contrast.png" -f $stamp)
  try {
    New-HighContrastVariant -SourcePath $imgPath -TargetPath $contrast
    [void]$variants.Add($contrast)
  }
  catch {
    Write-Log ("Vision preprocess warning (board): {0}" -f $_.Exception.Message)
  }

  $bestCards = $null
  $bestRaw = ""
  $bestVariant = ""
  $bestScore = -100000
  foreach ($variant in $variants) {
    try {
      $raw = Invoke-OllamaVisionBoard -ImagePath $variant
    }
    catch {
      Write-Log ("Vision call warning (board): {0}" -f $_.Exception.Message)
      continue
    }
    $cards = Parse-BoardTokensFromText -Text $raw
    $score = 0
    foreach ($slot in $cardSlotOrder) {
      $score += Get-BoardTokenScore -Token $cards[$slot]
    }
    if ($score -gt $bestScore) {
      $bestScore = $score
      $bestCards = $cards
      $bestRaw = [string]$raw
      $bestVariant = [System.IO.Path]::GetFileName($variant)
    }
  }
  if ($null -eq $bestCards) { return $null }
  return [pscustomobject]@{
    cards = $bestCards
    raw_text = $bestRaw
    variant = $bestVariant
    score = $bestScore
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Poker Board Vision Tester"
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.KeyPreview = $true
$form.Size = New-Object System.Drawing.Size(980, 700)
$form.MinimumSize = New-Object System.Drawing.Size(980, 700)
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 30)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Poker Board Vision Tester"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$status = New-Object System.Windows.Forms.Label
$status.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$status.Location = New-Object System.Drawing.Point(20, 44)
$status.AutoSize = $true
$modeLabel = if ($rankOnlyMode) { "rank-only" } else { "rank+suit" }
$parallelLabel = if ($ocrParallelEnabled) { ("parallel({0})" -f [int]$ocrParallelMaxWorkers) } else { "sequential" }
$statusBaseText = ("Local Vision: {0} @ {1} (keep_alive={2}) | card mode: {3} | ocr: {4} | bridge: {5} | profile: {6}" -f $ollamaVisionModel, $ollamaHost, $ollamaVisionKeepAlive, $modeLabel, $parallelLabel, $bridgeSolveEndpoint, $engineRuntimeProfile.ToUpperInvariant())
$status.Text = ("{0} | Engine: idle" -f $statusBaseText)
$status.ForeColor = [System.Drawing.Color]::FromArgb(140, 220, 170)
$form.Controls.Add($status)

$engineStatusLine = New-Object System.Windows.Forms.Label
$engineStatusLine.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$engineStatusLine.Location = New-Object System.Drawing.Point(20, 58)
$engineStatusLine.AutoSize = $true
$engineStatusLine.Text = "Engine queue: idle"
$engineStatusLine.ForeColor = [System.Drawing.Color]::FromArgb(165, 190, 210)
$form.Controls.Add($engineStatusLine)

$regionLabel = New-Object System.Windows.Forms.Label
$regionLabel.Text = "Selected: none"
$regionLabel.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$regionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$regionLabel.Location = New-Object System.Drawing.Point(20, 74)
$regionLabel.AutoSize = $true
$form.Controls.Add($regionLabel)

$cardStatusLabel = New-Object System.Windows.Forms.Label
$cardStatusLabel.Text = "Set board (5), hero, and action targets."
$cardStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$cardStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cardStatusLabel.Location = New-Object System.Drawing.Point(20, 94)
$cardStatusLabel.AutoSize = $true
$form.Controls.Add($cardStatusLabel)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = "Pick ROI"
$btnPick.Location = New-Object System.Drawing.Point(20, 118)
$btnPick.Size = New-Object System.Drawing.Size(190, 34)
$btnPick.FlatStyle = "Flat"
$btnPick.ForeColor = [System.Drawing.Color]::White
$btnPick.BackColor = [System.Drawing.Color]::FromArgb(46, 56, 68)
$form.Controls.Add($btnPick)

$btnOnce = New-Object System.Windows.Forms.Button
$btnOnce.Text = "Run OCR Once"
$btnOnce.Location = New-Object System.Drawing.Point(220, 118)
$btnOnce.Size = New-Object System.Drawing.Size(140, 34)
$btnOnce.FlatStyle = "Flat"
$btnOnce.ForeColor = [System.Drawing.Color]::White
$btnOnce.BackColor = [System.Drawing.Color]::FromArgb(20, 95, 62)
$form.Controls.Add($btnOnce)

$lblAuto = New-Object System.Windows.Forms.Label
$lblAuto.Text = "Auto OCR interval (sec)"
$lblAuto.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblAuto.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblAuto.Location = New-Object System.Drawing.Point(380, 125)
$lblAuto.AutoSize = $true
$form.Controls.Add($lblAuto)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(520, 122)
$numInterval.Size = New-Object System.Drawing.Size(70, 30)
$numInterval.Minimum = 1
$numInterval.Maximum = 60
$numInterval.Value = 5
$numInterval.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($numInterval)

$btnAutoStart = New-Object System.Windows.Forms.Button
$btnAutoStart.Text = "Start Auto"
$btnAutoStart.Location = New-Object System.Drawing.Point(610, 118)
$btnAutoStart.Size = New-Object System.Drawing.Size(80, 34)
$btnAutoStart.FlatStyle = "Flat"
$btnAutoStart.ForeColor = [System.Drawing.Color]::White
$btnAutoStart.BackColor = [System.Drawing.Color]::FromArgb(30, 105, 68)
$form.Controls.Add($btnAutoStart)

$btnAutoStop = New-Object System.Windows.Forms.Button
$btnAutoStop.Text = "Stop Auto"
$btnAutoStop.Location = New-Object System.Drawing.Point(695, 118)
$btnAutoStop.Size = New-Object System.Drawing.Size(80, 34)
$btnAutoStop.FlatStyle = "Flat"
$btnAutoStop.ForeColor = [System.Drawing.Color]::White
$btnAutoStop.BackColor = [System.Drawing.Color]::FromArgb(110, 30, 30)
$btnAutoStop.Enabled = $false
$form.Controls.Add($btnAutoStop)

$btnRunEngine = New-Object System.Windows.Forms.Button
$btnRunEngine.Text = "Run Engine"
$btnRunEngine.Location = New-Object System.Drawing.Point(780, 118)
$btnRunEngine.Size = New-Object System.Drawing.Size(95, 34)
$btnRunEngine.FlatStyle = "Flat"
$btnRunEngine.ForeColor = [System.Drawing.Color]::White
$btnRunEngine.BackColor = [System.Drawing.Color]::FromArgb(46, 74, 118)
$form.Controls.Add($btnRunEngine)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "Restart"
$btnRestart.Location = New-Object System.Drawing.Point(880, 118)
$btnRestart.Size = New-Object System.Drawing.Size(80, 34)
$btnRestart.FlatStyle = "Flat"
$btnRestart.ForeColor = [System.Drawing.Color]::White
$btnRestart.BackColor = [System.Drawing.Color]::FromArgb(52, 64, 92)
$form.Controls.Add($btnRestart)

$btnTargets = New-Object System.Windows.Forms.Button
$btnTargets.Text = "Targets: On (F8)"
$btnTargets.Location = New-Object System.Drawing.Point(610, 156)
$btnTargets.Size = New-Object System.Drawing.Size(120, 26)
$btnTargets.FlatStyle = "Flat"
$btnTargets.ForeColor = [System.Drawing.Color]::White
$btnTargets.BackColor = [System.Drawing.Color]::FromArgb(44, 72, 96)
$form.Controls.Add($btnTargets)

$btnResetRois = New-Object System.Windows.Forms.Button
$btnResetRois.Text = "Reset ROIs"
$btnResetRois.Location = New-Object System.Drawing.Point(740, 156)
$btnResetRois.Size = New-Object System.Drawing.Size(120, 26)
$btnResetRois.FlatStyle = "Flat"
$btnResetRois.ForeColor = [System.Drawing.Color]::White
$btnResetRois.BackColor = [System.Drawing.Color]::FromArgb(92, 58, 44)
$form.Controls.Add($btnResetRois)

$btnSetHeroes = New-Object System.Windows.Forms.Button
$btnSetHeroes.Text = "Set Heroes ROI"
$btnSetHeroes.Location = New-Object System.Drawing.Point(870, 156)
$btnSetHeroes.Size = New-Object System.Drawing.Size(90, 26)
$btnSetHeroes.FlatStyle = "Flat"
$btnSetHeroes.ForeColor = [System.Drawing.Color]::White
$btnSetHeroes.BackColor = [System.Drawing.Color]::FromArgb(84, 64, 120)
$form.Controls.Add($btnSetHeroes)

$lblEngineProfile = New-Object System.Windows.Forms.Label
$lblEngineProfile.Text = "Engine Profile"
$lblEngineProfile.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblEngineProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblEngineProfile.Location = New-Object System.Drawing.Point(620, 214)
$lblEngineProfile.AutoSize = $true
$form.Controls.Add($lblEngineProfile)

$cmbEngineProfile = New-Object System.Windows.Forms.ComboBox
$cmbEngineProfile.DropDownStyle = "DropDownList"
$cmbEngineProfile.Location = New-Object System.Drawing.Point(710, 211)
$cmbEngineProfile.Size = New-Object System.Drawing.Size(100, 24)
$cmbEngineProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbEngineProfile.Items.Add("fast")
[void]$cmbEngineProfile.Items.Add("normal")
$profileIdx = $cmbEngineProfile.Items.IndexOf($engineRuntimeProfile)
if ($profileIdx -lt 0) { $profileIdx = 0 }
$cmbEngineProfile.SelectedIndex = $profileIdx
$form.Controls.Add($cmbEngineProfile)

$lblQuick = New-Object System.Windows.Forms.Label
$lblQuick.Text = "Quick Test (single slot)"
$lblQuick.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblQuick.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblQuick.Location = New-Object System.Drawing.Point(20, 186)
$lblQuick.AutoSize = $true
$form.Controls.Add($lblQuick)

$btnRunFlop1 = New-Object System.Windows.Forms.Button
$btnRunFlop1.Text = "Run flop1"
$btnRunFlop1.Location = New-Object System.Drawing.Point(170, 182)
$btnRunFlop1.Size = New-Object System.Drawing.Size(90, 28)
$btnRunFlop1.FlatStyle = "Flat"
$btnRunFlop1.ForeColor = [System.Drawing.Color]::White
$btnRunFlop1.BackColor = [System.Drawing.Color]::FromArgb(36, 86, 60)
$form.Controls.Add($btnRunFlop1)

$btnRunFlop2 = New-Object System.Windows.Forms.Button
$btnRunFlop2.Text = "Run flop2"
$btnRunFlop2.Location = New-Object System.Drawing.Point(266, 182)
$btnRunFlop2.Size = New-Object System.Drawing.Size(90, 28)
$btnRunFlop2.FlatStyle = "Flat"
$btnRunFlop2.ForeColor = [System.Drawing.Color]::White
$btnRunFlop2.BackColor = [System.Drawing.Color]::FromArgb(36, 86, 60)
$form.Controls.Add($btnRunFlop2)

$btnRunFlop3 = New-Object System.Windows.Forms.Button
$btnRunFlop3.Text = "Run flop3"
$btnRunFlop3.Location = New-Object System.Drawing.Point(362, 182)
$btnRunFlop3.Size = New-Object System.Drawing.Size(90, 28)
$btnRunFlop3.FlatStyle = "Flat"
$btnRunFlop3.ForeColor = [System.Drawing.Color]::White
$btnRunFlop3.BackColor = [System.Drawing.Color]::FromArgb(36, 86, 60)
$form.Controls.Add($btnRunFlop3)

$btnRunTurn = New-Object System.Windows.Forms.Button
$btnRunTurn.Text = "Run Turn+E"
$btnRunTurn.Location = New-Object System.Drawing.Point(458, 182)
$btnRunTurn.Size = New-Object System.Drawing.Size(90, 28)
$btnRunTurn.FlatStyle = "Flat"
$btnRunTurn.ForeColor = [System.Drawing.Color]::White
$btnRunTurn.BackColor = [System.Drawing.Color]::FromArgb(96, 78, 36)
$form.Controls.Add($btnRunTurn)

$btnRunRiver = New-Object System.Windows.Forms.Button
$btnRunRiver.Text = "Run River+E"
$btnRunRiver.Location = New-Object System.Drawing.Point(554, 182)
$btnRunRiver.Size = New-Object System.Drawing.Size(90, 28)
$btnRunRiver.FlatStyle = "Flat"
$btnRunRiver.ForeColor = [System.Drawing.Color]::White
$btnRunRiver.BackColor = [System.Drawing.Color]::FromArgb(96, 66, 36)
$form.Controls.Add($btnRunRiver)

$btnRunFlopSet = New-Object System.Windows.Forms.Button
$btnRunFlopSet.Text = "Run Flop (1-3)"
$btnRunFlopSet.Location = New-Object System.Drawing.Point(650, 182)
$btnRunFlopSet.Size = New-Object System.Drawing.Size(140, 28)
$btnRunFlopSet.FlatStyle = "Flat"
$btnRunFlopSet.ForeColor = [System.Drawing.Color]::White
$btnRunFlopSet.BackColor = [System.Drawing.Color]::FromArgb(24, 104, 78)
$form.Controls.Add($btnRunFlopSet)

$btnRunHero = New-Object System.Windows.Forms.Button
$btnRunHero.Text = "Run Hero"
$btnRunHero.Location = New-Object System.Drawing.Point(796, 182)
$btnRunHero.Size = New-Object System.Drawing.Size(160, 28)
$btnRunHero.FlatStyle = "Flat"
$btnRunHero.ForeColor = [System.Drawing.Color]::White
$btnRunHero.BackColor = [System.Drawing.Color]::FromArgb(88, 66, 120)
$form.Controls.Add($btnRunHero)

$btnFold = New-Object System.Windows.Forms.Button
$btnFold.Text = "Fold"
$btnFold.Location = New-Object System.Drawing.Point(610, 78)
$btnFold.Size = New-Object System.Drawing.Size(84, 28)
$btnFold.FlatStyle = "Flat"
$btnFold.ForeColor = [System.Drawing.Color]::White
$btnFold.BackColor = [System.Drawing.Color]::FromArgb(125, 36, 36)
$btnFold.Add_Click({ Write-Log "Placeholder action clicked: FOLD (no-op)." })
$form.Controls.Add($btnFold)

$btnCall = New-Object System.Windows.Forms.Button
$btnCall.Text = "Call"
$btnCall.Location = New-Object System.Drawing.Point(700, 78)
$btnCall.Size = New-Object System.Drawing.Size(84, 28)
$btnCall.FlatStyle = "Flat"
$btnCall.ForeColor = [System.Drawing.Color]::White
$btnCall.BackColor = [System.Drawing.Color]::FromArgb(35, 90, 140)
$btnCall.Add_Click({ Write-Log "Placeholder action clicked: CALL (no-op)." })
$form.Controls.Add($btnCall)

$btnBet = New-Object System.Windows.Forms.Button
$btnBet.Text = "Bet"
$btnBet.Location = New-Object System.Drawing.Point(790, 78)
$btnBet.Size = New-Object System.Drawing.Size(84, 28)
$btnBet.FlatStyle = "Flat"
$btnBet.ForeColor = [System.Drawing.Color]::White
$btnBet.BackColor = [System.Drawing.Color]::FromArgb(40, 110, 70)
$btnBet.Add_Click({ Write-Log "Placeholder action clicked: BET (no-op)." })
$form.Controls.Add($btnBet)

$btnRaise = New-Object System.Windows.Forms.Button
$btnRaise.Text = "Raise"
$btnRaise.Location = New-Object System.Drawing.Point(880, 78)
$btnRaise.Size = New-Object System.Drawing.Size(84, 28)
$btnRaise.FlatStyle = "Flat"
$btnRaise.ForeColor = [System.Drawing.Color]::White
$btnRaise.BackColor = [System.Drawing.Color]::FromArgb(150, 96, 30)
$btnRaise.Add_Click({ Write-Log "Placeholder action clicked: RAISE (no-op)." })
$form.Controls.Add($btnRaise)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Flow: select target -> pick ROI -> run OCR (flop/turn/river/hero)."
$hint.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hint.Location = New-Object System.Drawing.Point(20, 214)
$hint.AutoSize = $true
$form.Controls.Add($hint)

$lblCaptureMode = New-Object System.Windows.Forms.Label
$lblCaptureMode.Text = "Mode"
$lblCaptureMode.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblCaptureMode.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCaptureMode.Location = New-Object System.Drawing.Point(20, 160)
$lblCaptureMode.AutoSize = $true
$form.Controls.Add($lblCaptureMode)

$cmbCaptureMode = New-Object System.Windows.Forms.ComboBox
$cmbCaptureMode.DropDownStyle = "DropDownList"
$cmbCaptureMode.Location = New-Object System.Drawing.Point(110, 157)
$cmbCaptureMode.Size = New-Object System.Drawing.Size(190, 24)
$cmbCaptureMode.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbCaptureMode.Items.Add("Individual Card ROIs")
$cmbCaptureMode.SelectedIndex = 0
$cmbCaptureMode.Enabled = $false
$form.Controls.Add($cmbCaptureMode)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "ROI Target (Individual)"
$lblTarget.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblTarget.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblTarget.Location = New-Object System.Drawing.Point(320, 160)
$lblTarget.AutoSize = $true
$form.Controls.Add($lblTarget)

$cmbTarget = New-Object System.Windows.Forms.ComboBox
$cmbTarget.DropDownStyle = "DropDownList"
$cmbTarget.Location = New-Object System.Drawing.Point(455, 157)
$cmbTarget.Size = New-Object System.Drawing.Size(140, 24)
$cmbTarget.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbTarget.Items.Add("flop1")
[void]$cmbTarget.Items.Add("flop2")
[void]$cmbTarget.Items.Add("flop3")
[void]$cmbTarget.Items.Add("turn")
[void]$cmbTarget.Items.Add("river")
[void]$cmbTarget.Items.Add("hero")
[void]$cmbTarget.Items.Add("fold_btn")
[void]$cmbTarget.Items.Add("call_btn")
[void]$cmbTarget.Items.Add("bet_btn")
[void]$cmbTarget.Items.Add("raise_btn")
$cmbTarget.SelectedIndex = 0
$cmbTarget.Enabled = $true
$form.Controls.Add($cmbTarget)
$lblTarget.Enabled = $true

$latestLabel = New-Object System.Windows.Forms.Label
$latestLabel.Text = "Latest OCR Text"
$latestLabel.ForeColor = [System.Drawing.Color]::White
$latestLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$latestLabel.Location = New-Object System.Drawing.Point(20, 236)
$latestLabel.AutoSize = $true
$form.Controls.Add($latestLabel)

$txtLatest = New-Object System.Windows.Forms.TextBox
$txtLatest.Location = New-Object System.Drawing.Point(20, 260)
$txtLatest.Size = New-Object System.Drawing.Size(936, 160)
$txtLatest.Multiline = $true
$txtLatest.ScrollBars = "Vertical"
$txtLatest.ReadOnly = $true
$txtLatest.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtLatest.BackColor = [System.Drawing.Color]::FromArgb(14, 18, 23)
$txtLatest.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
$form.Controls.Add($txtLatest)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "Log"
$logLabel.ForeColor = [System.Drawing.Color]::White
$logLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$logLabel.Location = New-Object System.Drawing.Point(20, 428)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 452)
$logBox.Size = New-Object System.Drawing.Size(936, 222)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(14, 18, 23)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 245)
$form.Controls.Add($logBox)

function Write-Log {
  param(
    [string]$Message,
    [string]$Type = "log",
    [hashtable]$Data = $null
  )
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $line = "[$stamp] $Message"
  $logBox.AppendText("$line`r`n")
  try {
    Add-Content -Path $uiLogTextPath -Value $line -Encoding UTF8
  }
  catch {}

  try {
    $evt = [ordered]@{
      ts_utc = [DateTime]::UtcNow.ToString("o")
      session_id = $uiSessionId
      type = [string]$Type
      message = [string]$Message
    }
    if ($null -ne $Data) {
      $evt["data"] = $Data
    }
    $evtJson = ($evt | ConvertTo-Json -Depth 10 -Compress)
    Add-Content -Path $uiLogJsonlPath -Value $evtJson -Encoding UTF8
    $latest = [ordered]@{
      session_id = $uiSessionId
      log_text_path = $uiLogTextPath
      log_jsonl_path = $uiLogJsonlPath
      updated_utc = [DateTime]::UtcNow.ToString("o")
    }
    Set-Content -Path $uiLogLatestPath -Value ($latest | ConvertTo-Json -Depth 5) -Encoding UTF8
  }
  catch {}
}

function Initialize-SessionLogs {
  try {
    if (-not (Test-Path $uiLogRoot)) {
      New-Item -Path $uiLogRoot -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $uiLogTextPath -Value ("# Poker Vision UI Session {0} ({1})" -f $uiSessionId, [DateTime]::UtcNow.ToString("o")) -Encoding UTF8
    Set-Content -Path $uiLogJsonlPath -Value "" -Encoding UTF8
  }
  catch {}
}

function Resolve-BridgePythonCommand {
  $venvPy = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
  if (Test-Path $venvPy) {
    return [pscustomobject]@{
      file = $venvPy
      prefix = @()
      label = "venv-python"
    }
  }
  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py -and $py.Source) {
    return [pscustomobject]@{
      file = [string]$py.Source
      prefix = @()
      label = "python"
    }
  }
  $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
  if ($pyLauncher -and $pyLauncher.Source) {
    return [pscustomobject]@{
      file = [string]$pyLauncher.Source
      prefix = @("-3")
      label = "py-launcher"
    }
  }
  return $null
}

function Wait-Until {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Condition,
    [int]$TimeoutSec = 20,
    [int]$IntervalMs = 300
  )
  $start = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
    try {
      if (& $Condition) {
        return $true
      }
    }
    catch {
      # ignore transient probe errors
    }
    Start-Sleep -Milliseconds $IntervalMs
  }
  return $false
}

function Test-TcpPortOpen {
  param(
    [Parameter(Mandatory = $true)][string]$Host,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutMs = 800
  )
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($Host, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if (-not $ok) {
      return $false
    }
    $client.EndConnect($iar) | Out-Null
    return $client.Connected
  }
  catch {
    return $false
  }
  finally {
    try { $client.Close() } catch {}
  }
}

function Test-BridgeEndpoint {
  try {
    $null = Invoke-RestMethod -Uri $bridgeHealthEndpoint -Method Get -TimeoutSec 3
    return $true
  }
  catch {
    try {
      $uri = [System.Uri]$bridgeSolveEndpoint
      return (Test-TcpPortOpen -Host $uri.Host -Port $uri.Port -TimeoutMs 700)
    }
    catch {
      return $false
    }
  }
}

function Stop-ProcessTreeByPid {
  param(
    [int]$ProcessId
  )
  if ($ProcessId -le 0) {
    return $false
  }

  $stopped = $false
  try {
    & taskkill.exe /PID $ProcessId /T /F 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
      $stopped = $true
    }
  }
  catch {}

  if (-not $stopped) {
    try {
      Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
      $stopped = $true
    }
    catch {}
  }
  return $stopped
}

function Stop-ManagedBackends {
  if ($managedBridgeStartedByUi) {
    $bridgePid = 0
    if ($managedBridgeProcess) {
      try { $bridgePid = [int]$managedBridgeProcess.Id } catch { $bridgePid = 0 }
    }
    if ($bridgePid -gt 0) {
      if (Stop-ProcessTreeByPid -ProcessId $bridgePid) {
        Write-Log ("Stopped managed bridge process tree (pid={0})." -f $bridgePid)
      }
    }
  }
  if ($managedOllamaStartedByUi) {
    $ollamaPid = 0
    if ($managedOllamaProcess) {
      try { $ollamaPid = [int]$managedOllamaProcess.Id } catch { $ollamaPid = 0 }
    }
    if ($ollamaPid -gt 0) {
      if (Stop-ProcessTreeByPid -ProcessId $ollamaPid) {
        Write-Log ("Stopped managed Ollama process tree (pid={0})." -f $ollamaPid)
      }
    }
    # Final safety sweep for stray ollama.exe instances if this UI started the service.
    $leftover = @(Get-Process -Name "ollama" -ErrorAction SilentlyContinue)
    if ($leftover.Count -gt 0) {
      foreach ($proc in $leftover) {
        try {
          Stop-ProcessTreeByPid -ProcessId ([int]$proc.Id) | Out-Null
        }
        catch {}
      }
      Start-Sleep -Milliseconds 120
      if (-not (Test-OllamaEndpoint)) {
        Write-Log "Stopped leftover Ollama background processes started in this session."
      }
      else {
        Write-Log "Ollama endpoint still reachable after stop attempt. Another external service may still be running."
      }
    }
  }
  $script:managedBridgeProcess = $null
  $script:managedOllamaProcess = $null
  $script:managedBridgeStartedByUi = $false
  $script:managedOllamaStartedByUi = $false
}

function Ensure-BackendsRunning {
  if (-not $backendAutoStart) {
    Write-Log "Backend auto-start disabled (BACKEND_AUTOSTART=0)."
    return
  }

  if (-not (Test-OllamaEndpoint)) {
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollamaCmd -or -not $ollamaCmd.Source) {
      Write-Log ("Ollama unavailable: command not found. Vision host: {0}" -f $ollamaHost)
    }
    else {
      Write-Log ("Starting Ollama service for vision/model host at {0}..." -f $ollamaHost)
      try {
        $script:managedOllamaProcess = Start-Process -FilePath $ollamaCmd.Source -ArgumentList @("serve") -WindowStyle Minimized -PassThru
        $script:managedOllamaStartedByUi = $true
      }
      catch {
        Write-Log ("Failed to start Ollama service: {0}" -f $_.Exception.Message)
      }
    }
  }
  if (Wait-Until -TimeoutSec 30 -IntervalMs 400 -Condition { Test-OllamaEndpoint }) {
    Write-Log "Ollama endpoint ready."
  }
  else {
    Write-Log ("Ollama endpoint still unavailable at {0}. Vision/OCR will be blocked." -f $ollamaHost)
  }

  if (-not (Test-BridgeEndpoint)) {
    $bridgeScript = Join-Path $PSScriptRoot "4_LLM_Bridge\bridge_server.py"
    if (-not (Test-Path $bridgeScript)) {
      Write-Log ("Bridge server script not found: {0}" -f $bridgeScript)
    }
    else {
      $pyCmd = Resolve-BridgePythonCommand
      if ($null -eq $pyCmd) {
        Write-Log "Bridge auto-start unavailable: no Python runtime found."
      }
      else {
        Write-Log ("Starting bridge server at {0} using {1}..." -f $bridgeHealthEndpoint, $pyCmd.label)
        try {
          $args = @()
          $args += $pyCmd.prefix
          $args += @($bridgeScript)
          $script:managedBridgeProcess = Start-Process -FilePath $pyCmd.file -ArgumentList $args -WorkingDirectory $PSScriptRoot -WindowStyle Minimized -PassThru
          $script:managedBridgeStartedByUi = $true
        }
        catch {
          Write-Log ("Failed to start bridge server: {0}" -f $_.Exception.Message)
        }
      }
    }
  }
  if (Wait-Until -TimeoutSec 30 -IntervalMs 400 -Condition { Test-BridgeEndpoint }) {
    Write-Log ("Bridge endpoint ready: {0}" -f $bridgeHealthEndpoint)
  }
  else {
    Write-Log ("Bridge endpoint still unavailable: {0}" -f $bridgeHealthEndpoint)
  }
}

function Update-EngineButtonState {
  $hasJobs = ($enginePendingJobs.Count -gt 0)
  if ($hasJobs -and (-not $engineHandoffBusy)) {
    $script:engineHandoffBusy = $true
  }
  elseif ((-not $hasJobs) -and $engineHandoffBusy) {
    $script:engineHandoffBusy = $false
  }

  $oldestJobId = $null
  $oldestStage = ""
  $oldestElapsedSec = 0.0
  $oldestStateVersion = 0
  $oldestStateHashShort = ""
  if ($hasJobs) {
    $oldestTime = $null
    foreach ($jid in @($enginePendingJobs.Keys)) {
      $meta = $enginePendingJobs[$jid]
      if ($null -eq $meta) { continue }
      $queuedUtc = $null
      if ($meta.ContainsKey("queued_utc") -and $meta.queued_utc) {
        try { $queuedUtc = [datetime]$meta.queued_utc } catch { $queuedUtc = $null }
      }
      if ($null -eq $queuedUtc) {
        $queuedUtc = (Get-Date).ToUniversalTime()
      }
      if ($null -eq $oldestTime -or $queuedUtc -lt $oldestTime) {
        $oldestTime = $queuedUtc
        $oldestJobId = [int]$jid
        $oldestStage = [string]$meta.stage
        if ($meta.ContainsKey("state_version") -and $meta.state_version) {
          try { $oldestStateVersion = [int]$meta.state_version } catch { $oldestStateVersion = 0 }
        }
        if ($meta.ContainsKey("state_hash") -and $meta.state_hash) {
          $oldestStateHashShort = Get-ShortHash -HashValue ([string]$meta.state_hash)
        }
      }
    }
    if ($null -ne $oldestTime) {
      $oldestElapsedSec = ((Get-Date).ToUniversalTime() - $oldestTime).TotalSeconds
    }
  }

  $engineText = ""
  if ($engineHandoffBusy -or $hasJobs) {
    $engineText = ("Engine: BUSY ({0} job{1})" -f [int]$enginePendingJobs.Count, $(if ([int]$enginePendingJobs.Count -eq 1) { "" } else { "s" }))
    $btnRunFlopSet.BackColor = [System.Drawing.Color]::FromArgb(24, 104, 78)
    $btnRunTurn.BackColor = [System.Drawing.Color]::FromArgb(96, 78, 36)
    $btnRunRiver.BackColor = [System.Drawing.Color]::FromArgb(96, 66, 36)
    $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 120)
    if ($null -ne $engineStatusLine) {
      if ($null -ne $oldestJobId) {
        $engineStatusLine.Text = ("Engine queue: job={0} v={1} hash={2} stage={3} elapsed={4:N1}s (max={5}s) | repl={6} skip={7} done={8}" -f `
          $oldestJobId, [int]$oldestStateVersion, $oldestStateHashShort, $oldestStage, [double]$oldestElapsedSec, [int]$engineJobMaxAgeSec, [int]$engineQueueReplaceCount, [int]($engineQueueSkipNoChangeCount + $engineQueuePrioritySkipCount), [int]$engineQueueCompletedCount)
      }
      else {
        $engineStatusLine.Text = ("Engine queue: busy ({0} pending) | repl={1} skip={2} done={3}" -f [int]$enginePendingJobs.Count, [int]$engineQueueReplaceCount, [int]($engineQueueSkipNoChangeCount + $engineQueuePrioritySkipCount), [int]$engineQueueCompletedCount)
      }
      $engineStatusLine.ForeColor = [System.Drawing.Color]::FromArgb(255, 208, 135)
    }
  }
  else {
    $engineText = "Engine: idle"
    $btnRunFlopSet.BackColor = [System.Drawing.Color]::FromArgb(24, 104, 78)
    $btnRunTurn.BackColor = [System.Drawing.Color]::FromArgb(96, 78, 36)
    $btnRunRiver.BackColor = [System.Drawing.Color]::FromArgb(96, 66, 36)
    $status.ForeColor = [System.Drawing.Color]::FromArgb(140, 220, 170)
    if ($null -ne $engineStatusLine) {
      $engineStatusLine.Text = ("Engine queue: idle | last_v={0} last_hash={1} | repl={2} skip={3} done={4}" -f [int]$engineStateVersion, (Get-ShortHash -HashValue $engineLastCompletedStateHash), [int]$engineQueueReplaceCount, [int]($engineQueueSkipNoChangeCount + $engineQueuePrioritySkipCount), [int]$engineQueueCompletedCount)
      $engineStatusLine.ForeColor = [System.Drawing.Color]::FromArgb(165, 190, 210)
    }
  }
  $status.Text = ("{0} | {1}" -f $statusBaseText, $engineText)
}

function Format-RegionText {
  param([System.Drawing.Rectangle]$Rect)
  if ($Rect -eq [System.Drawing.Rectangle]::Empty) {
    return "Region: Not selected"
  }
  return ("Region: X={0}, Y={1}, W={2}, H={3}" -f $Rect.X, $Rect.Y, $Rect.Width, $Rect.Height)
}

function Get-CaptureModeSafe {
  return "Individual Card ROIs"
}

function Get-ActiveOverlayKeys {
  return $allSlotOrder
}

function Sync-OverlayToRoi {
  param(
    [string]$Key,
    [System.Windows.Forms.Form]$OverlayForm
  )
  if ($null -eq $OverlayForm) {
    return
  }
  $r = New-Object System.Drawing.Rectangle([int]$OverlayForm.Left, [int]$OverlayForm.Top, [int]$OverlayForm.Width, [int]$OverlayForm.Height)
  Set-RoiRectByKey -Key $Key -Rect $r
  $regionLabel.Text = ("Selected: {0} -> X={1}, Y={2}, W={3}, H={4}" -f $Key, $r.X, $r.Y, $r.Width, $r.Height)
  $cardStatusLabel.Text = Format-CardSlotStatus
  Save-RoiState
}

function Clear-RoiForSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Key
  )
  if (-not ($allSlotOrder -contains $Key)) {
    return
  }
  Set-RoiRectByKey -Key $Key -Rect ([System.Drawing.Rectangle]::Empty)
  if ($Key -in $playerSlotOrder) {
    $heroCards[$Key] = "??"
    $script:lastHeroAutoSendKey = ""
  }
  elseif ($Key -in $cardSlotOrder) {
    Update-LastBoardTokenFromSlot -Slot $Key -Token "??"
  }
  $regionLabel.Text = ("Selected: cleared {0}" -f $Key)
  $cardStatusLabel.Text = Format-CardSlotStatus
  Save-RoiState -ForceWriteEmpty
  Refresh-RoiOverlays
  Write-Log ("Cleared ROI for {0}." -f $Key) -Type "roi_clear" -Data @{ slot = $Key }
}

function Apply-ManualCardTokenToSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  if (-not ($allSlotOrder -contains $Slot)) {
    return
  }
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    Write-Log ("Manual card assign skipped for {0}: invalid token '{1}'." -f $Slot, $Token)
    return
  }

  if ($Slot -in $playerSlotOrder) {
    $heroCards[$Slot] = $normalized
    if (-not $suppressHeroAutoSend) {
      Try-AutoSendHeroCardsToEngine
    }
  }
  elseif ($Slot -in $cardSlotOrder) {
    Update-LastBoardTokenFromSlot -Slot $Slot -Token $normalized
    $manualBoardReady = Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)
    if ($manualBoardReady) {
      [void](Queue-EngineSolveForBoard -BoardTokens @($lastBoardTokens) -StageLabel "manual_single")
    }
  }
  else {
    return
  }

  $txtLatest.Text = @(
    "run:   manual_assign"
    ("slot:  {0}" -f $Slot)
    ("card:  {0}" -f $normalized)
    ("hero_cards: {0}" -f (Get-HeroCardsText))
    ("board: {0}" -f (Get-BoardTokensText))
    ("board_ready: {0}" -f (Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)))
    "source:manual_menu"
  ) -join "`r`n"
  Write-Log ("Manual card set [{0}] = {1}" -f $Slot, $normalized) -Type "manual_card_set" -Data @{
    slot = $Slot
    token = $normalized
    hero_cards = @([string]$heroCards["hero1"], [string]$heroCards["hero2"])
    board = @($lastBoardTokens)
  }
}

function Repick-RoiForSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Key
  )
  if (-not ($allSlotOrder -contains $Key)) {
    return
  }
  if ($isBusy) {
    Write-Log ("Repick skipped for {0}: OCR is currently busy." -f $Key)
    return
  }

  $restoreOverlaysAfter = $false
  try {
    if ($overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 40
    }
    Write-Log ("Selecting ROI for {0}..." -f $Key)
    $region = Select-ScreenRegion
    if (Test-RegionSelected -Rect $region) {
      Set-RoiRectByKey -Key $Key -Rect $region
      $regionLabel.Text = ("Selected: {0} -> X={1}, Y={2}, W={3}, H={4}" -f $Key, $region.X, $region.Y, $region.Width, $region.Height)
      $cardStatusLabel.Text = Format-CardSlotStatus
      Save-RoiState
      Write-Log ("Card ROI [{0}] set to X={1}, Y={2}, W={3}, H={4}" -f $Key, $region.X, $region.Y, $region.Width, $region.Height) -Type "roi_set" -Data @{
        slot = $Key
        x = [int]$region.X
        y = [int]$region.Y
        w = [int]$region.Width
        h = [int]$region.Height
      }
    }
    else {
      Write-Log ("Repick canceled for {0}." -f $Key)
    }
  }
  finally {
    if ($restoreOverlaysAfter) {
      Set-OverlayVisibilityForCapture -Enable $true
    }
    Refresh-RoiOverlays
  }
}

function Get-ManualSuitDisplay {
  param(
    [Parameter(Mandatory = $true)][string]$SuitToken
  )
  switch (([string]$SuitToken).ToUpperInvariant()) {
    "S" { return ("Spade " + [string][char]0x2660) }
    "H" { return ("Heart " + [string][char]0x2665) }
    "D" { return ("Diamond " + [string][char]0x2666) }
    "C" { return ("Club " + [string][char]0x2663) }
    default { return ([string]$SuitToken).ToUpperInvariant() }
  }
}

function New-ManualCardRankMenuItem {
  param(
    [Parameter(Mandatory = $true)][string]$SlotKey,
    [Parameter(Mandatory = $true)][string]$SuitToken,
    [Parameter(Mandatory = $true)][string]$RankToken
  )
  $capturedSlot = [string]$SlotKey
  $capturedSuit = ([string]$SuitToken).ToUpperInvariant()
  $capturedRank = [string]$RankToken
  $capturedToken = ("{0}{1}" -f $capturedRank, $capturedSuit).ToUpperInvariant()
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $capturedRank
  $item.Add_Click({
    Apply-ManualCardTokenToSlot -Slot $capturedSlot -Token $capturedToken
  }.GetNewClosure())
  return $item
}

function New-ManualCardSuitMenuItem {
  param(
    [Parameter(Mandatory = $true)][string]$SlotKey,
    [Parameter(Mandatory = $true)][string]$SuitToken
  )
  $capturedSlot = [string]$SlotKey
  $capturedSuit = ([string]$SuitToken).ToUpperInvariant()
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = Get-ManualSuitDisplay -SuitToken $capturedSuit
  $item.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 9)
  foreach ($rankToken in @("A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2")) {
    [void]$item.DropDownItems.Add((New-ManualCardRankMenuItem -SlotKey $capturedSlot -SuitToken $capturedSuit -RankToken $rankToken))
  }
  return $item
}

function New-ManualCardMenu {
  param(
    [Parameter(Mandatory = $true)][string]$SlotKey
  )
  $capturedSlot = [string]$SlotKey
  $menu = New-Object System.Windows.Forms.ToolStripMenuItem
  $menu.Text = "Set Card"
  foreach ($suitToken in @("S", "H", "D", "C")) {
    [void]$menu.DropDownItems.Add((New-ManualCardSuitMenuItem -SlotKey $capturedSlot -SuitToken $suitToken))
  }
  return $menu
}

function New-RoiSlotContextMenu {
  param(
    [Parameter(Mandatory = $true)][string]$Key
  )
  $slotKey = [string]$Key
  $menu = New-Object System.Windows.Forms.ContextMenuStrip

  $title = New-Object System.Windows.Forms.ToolStripMenuItem
  $title.Text = ("Slot: {0}" -f $slotKey)
  $title.Enabled = $false
  [void]$menu.Items.Add($title)

  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  [void]$menu.Items.Add((New-ManualCardMenu -SlotKey $slotKey))

  $runItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $runItem.Text = "Run OCR"
  $runItem.Add_Click({
    Run-OcrSingleSlot -Slot $slotKey
  }.GetNewClosure())
  [void]$menu.Items.Add($runItem)

  $repickItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $repickItem.Text = "Repick ROI"
  $repickItem.Add_Click({
    Repick-RoiForSlot -Key $slotKey
  }.GetNewClosure())
  [void]$menu.Items.Add($repickItem)

  $clearItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $clearItem.Text = "Clear ROI"
  $clearItem.Add_Click({
    Clear-RoiForSlot -Key $slotKey
  }.GetNewClosure())
  [void]$menu.Items.Add($clearItem)

  return $menu
}

function New-RoiOverlayForm {
  param(
    [string]$Key,
    [System.Drawing.Rectangle]$Rect,
    [System.Drawing.Color]$Color
  )
  $overlay = New-Object System.Windows.Forms.Form
  $overlay.FormBorderStyle = "None"
  $overlay.StartPosition = "Manual"
  $overlay.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $overlay.AutoSize = $false
  $overlay.MinimumSize = New-Object System.Drawing.Size(1, 1)
  $overlay.ShowInTaskbar = $false
  $overlay.TopMost = $true
  $overlay.BackColor = $Color
  $overlay.Opacity = 0.28
  $overlay.Padding = New-Object System.Windows.Forms.Padding(0)
  $overlay.Bounds = New-Object System.Drawing.Rectangle([int]$Rect.X, [int]$Rect.Y, [Math]::Max(1, [int]$Rect.Width), [Math]::Max(1, [int]$Rect.Height))
  $overlay.Tag = [pscustomobject]@{
    key = $Key
    down = $false
    offsetX = 0
    offsetY = 0
  }
  if (($Key -in $cardSlotOrder) -or ($Key -in $playerSlotOrder)) {
    $overlay.ContextMenuStrip = New-RoiSlotContextMenu -Key $Key
  }
  $overlay.Add_Paint({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state) { return }
    $text = [string]$state.key
    if (-not $text) { return }
    $fontSize = 9.0
    if ($sender.Width -lt 52 -or $sender.Height -lt 22) {
      $fontSize = 7.0
    }
    $font = New-Object System.Drawing.Font("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 245, 255))
    try {
      $e.Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
      $e.Graphics.DrawString($text, $font, $brush, 4, 2)
    }
    finally {
      $brush.Dispose()
      $font.Dispose()
    }
  })

  $overlay.Add_MouseDown({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state) { return }
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $state.down = $true
      $state.offsetX = [int]$e.X
      $state.offsetY = [int]$e.Y
    }
  })
  $overlay.Add_MouseMove({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state -or -not $state.down) {
      return
    }
    $pt = [System.Windows.Forms.Control]::MousePosition
    $sender.Left = [int]($pt.X - [int]$state.offsetX)
    $sender.Top = [int]($pt.Y - [int]$state.offsetY)
  })
  $overlay.Add_MouseUp({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state -or -not $state.down) {
      return
    }
    $state.down = $false
    Sync-OverlayToRoi -Key ([string]$state.key) -OverlayForm $sender
  })

  return $overlay
}

function Refresh-RoiOverlays {
  $active = Get-ActiveOverlayKeys
  foreach ($key in (Get-RoiTargets)) {
    $rect = Get-RoiRectByKey -Key $key
    $hasRect = Test-RegionSelected -Rect $rect
    $shouldShow = $overlayVisible -and $hasRect -and ($active -contains $key)
    if (-not $shouldShow) {
      if ($overlayForms.ContainsKey($key)) {
        try { $overlayForms[$key].Hide() } catch {}
      }
      continue
    }

    if (-not $overlayForms.ContainsKey($key) -or $null -eq $overlayForms[$key] -or $overlayForms[$key].IsDisposed) {
      $color = if ($overlayColors.ContainsKey($key)) { $overlayColors[$key] } else { [System.Drawing.Color]::FromArgb(120, 160, 255) }
      $overlayForms[$key] = New-RoiOverlayForm -Key $key -Rect $rect -Color $color
    }
    $overlay = $overlayForms[$key]
    $overlay.Bounds = $rect
    if (-not $overlay.Visible) {
      $overlay.Show()
    }
    if ($overlay.Width -ne $rect.Width -or $overlay.Height -ne $rect.Height) {
      $overlay.Bounds = $rect
    }
    $overlay.BringToFront()
  }
}

function Close-RoiOverlays {
  foreach ($key in @($overlayForms.Keys)) {
    try {
      if ($overlayForms[$key] -and -not $overlayForms[$key].IsDisposed) {
        $overlayForms[$key].Close()
        $overlayForms[$key].Dispose()
      }
    }
    catch {}
  }
  $overlayForms.Clear()
}

function Update-TargetsButtonText {
  if ($overlayVisible) {
    $btnTargets.Text = "Targets: On (F8)"
  }
  else {
    $btnTargets.Text = "Targets: Off (F8)"
  }
}

function Toggle-RoiOverlays {
  $script:overlayVisible = -not $overlayVisible
  Update-TargetsButtonText
  Refresh-RoiOverlays
  $stateText = "hidden"
  if ($overlayVisible) {
    $stateText = "enabled"
  }
  Write-Log ("Target overlays {0}." -f $stateText) -Type "overlay_toggle" -Data @{ enabled = [bool]$overlayVisible }
}

function Set-OverlayVisibilityForCapture {
  param([bool]$Enable)
  $script:overlayVisible = $Enable
  Update-TargetsButtonText
  Refresh-RoiOverlays
}

function Get-UnionCardRoiBounds {
  param(
    [int]$PadX = 0,
    [int]$PadY = 0
  )
  $selected = New-Object System.Collections.Generic.List[System.Drawing.Rectangle]
  foreach ($slot in $cardSlotOrder) {
    $r = Get-RoiRectByKey -Key $slot
    if (Test-RegionSelected -Rect $r) {
      [void]$selected.Add($r)
    }
  }
  if ($selected.Count -eq 0) {
    return [System.Drawing.Rectangle]::Empty
  }
  $minX = ($selected | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
  $minY = ($selected | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
  $maxR = ($selected | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
  $maxB = ($selected | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum

  $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $x = [Math]::Max($virtual.X, [int]$minX - [int]$PadX)
  $y = [Math]::Max($virtual.Y, [int]$minY - [int]$PadY)
  $r = [Math]::Min(($virtual.X + $virtual.Width), [int]$maxR + [int]$PadX)
  $b = [Math]::Min(($virtual.Y + $virtual.Height), [int]$maxB + [int]$PadY)
  $w = [Math]::Max(1, $r - $x)
  $h = [Math]::Max(1, $b - $y)
  return New-Object System.Drawing.Rectangle($x, $y, $w, $h)
}

function Get-RoiOverlapWarnings {
  $warnings = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $cardSlotOrder.Count; $i++) {
    $slotA = $cardSlotOrder[$i]
    $a = Get-RoiRectByKey -Key $slotA
    if (-not (Test-RegionSelected -Rect $a)) { continue }
    for ($j = $i + 1; $j -lt $cardSlotOrder.Count; $j++) {
      $slotB = $cardSlotOrder[$j]
      $b = Get-RoiRectByKey -Key $slotB
      if (-not (Test-RegionSelected -Rect $b)) { continue }
      $ix = [Math]::Max($a.X, $b.X)
      $iy = [Math]::Max($a.Y, $b.Y)
      $ir = [Math]::Min(($a.X + $a.Width), ($b.X + $b.Width))
      $ib = [Math]::Min(($a.Y + $a.Height), ($b.Y + $b.Height))
      $iw = $ir - $ix
      $ih = $ib - $iy
      if ($iw -le 0 -or $ih -le 0) { continue }
      $interArea = [double]($iw * $ih)
      $minArea = [double][Math]::Max(1, [Math]::Min(($a.Width * $a.Height), ($b.Width * $b.Height)))
      $ratio = $interArea / $minArea
      if ($ratio -ge 0.25) {
        [void]$warnings.Add(("{0}<->{1} overlap {2:P0}" -f $slotA, $slotB, $ratio))
      }
    }
  }
  return $warnings
}

function Resolve-CardTokenForSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$SlotTagPrefix,
    [switch]$FastMode,
    [switch]$SkipPresenceCheck
  )

  if (-not ($allSlotOrder -contains $Slot)) {
    return [pscustomobject]@{
      status = "error"
      token = "??"
      preview = ""
      variant = ""
      source = ""
      message = ("unknown slot: {0}" -f $Slot)
      no_card = $false
      white_ratio = 0.0
      green_ratio = 0.0
    }
  }

  $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$Slot]
  if (-not (Test-RegionSelected -Rect $slotRect)) {
    return [pscustomobject]@{
      status = "error"
      token = "??"
      preview = ""
      variant = ""
      source = ""
      message = ("ROI not set for {0}" -f $Slot)
      no_card = $false
      white_ratio = 0.0
      green_ratio = 0.0
    }
  }

  $presence = [pscustomobject]@{
    likely_card = $true
    white_ratio = 0.0
    green_ratio = 0.0
  }
  if (-not $SkipPresenceCheck) {
    $presence = Get-CardPresenceSignalFromRegion -Region $slotRect
    if (-not $presence.likely_card) {
      return [pscustomobject]@{
        status = "ok"
        token = "NO_CARD"
        preview = ""
        variant = ""
        source = ""
        message = ""
        no_card = $true
        white_ratio = [double]$presence.white_ratio
        green_ratio = [double]$presence.green_ratio
      }
    }
  }

  $bestCard = Get-CardTokenFromVisionRegion -Region $slotRect -TmpDir $TmpDir -SlotTag ("{0}_{1}" -f $SlotTagPrefix, $Slot) -FastMode:$FastMode
  if (-not $bestCard -and $tesseractExe) {
    $fallbackCard = Get-CardTokenFromRegion -Region $slotRect -TmpDir $TmpDir -SlotTag ("{0}_{1}" -f $SlotTagPrefix, $Slot)
    if ($fallbackCard -and ([string]$fallbackCard.token).Trim().ToUpperInvariant() -match "^[AKQJT98765432][SHDC]$") {
      $bestCard = $fallbackCard
    }
  }
  if (-not $bestCard) {
    return [pscustomobject]@{
      status = "ok"
      token = "??"
      preview = ""
      variant = ""
      source = ""
      message = ""
      no_card = $false
      white_ratio = [double]$presence.white_ratio
      green_ratio = [double]$presence.green_ratio
    }
  }

  $token = ([string]$bestCard.token).Trim().ToUpperInvariant()
  if ($rankOnlyMode) {
    $token = Convert-ToRankOnlyToken -Token $token
  }
  else {
    $ovr = Apply-SuitHintOverride -Token $token -Region $slotRect
    if ($ovr.changed) {
      $token = [string]$ovr.token
    }
  }

  $preview = (($bestCard.raw_text -replace "\r?\n", " ") -as [string]).Trim()
  if ($preview.Length -gt 96) {
    $preview = $preview.Substring(0, 96) + "..."
  }
  return [pscustomobject]@{
    status = "ok"
    token = $token
    preview = $preview
    variant = [string]$bestCard.variant
    source = [string]$bestCard.source
    message = ""
    no_card = $false
    white_ratio = [double]$presence.white_ratio
    green_ratio = [double]$presence.green_ratio
  }
}

function Resolve-CardTokensBatch {
  param(
    [Parameter(Mandatory = $true)][string[]]$Slots,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$SlotTagPrefix,
    [switch]$FastMode,
    [switch]$SkipPresenceCheck
  )

  $results = @{}
  foreach ($slot in $Slots) {
    $results[$slot] = $null
  }
  if ($Slots.Count -eq 0) {
    return $results
  }

  $canParallel = $ocrParallelEnabled -and ($Slots.Count -gt 1) -and ($null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue))
  if (-not $canParallel) {
    foreach ($slot in $Slots) {
      $results[$slot] = Resolve-CardTokenForSlot -Slot $slot -TmpDir $TmpDir -SlotTagPrefix $SlotTagPrefix -FastMode:$FastMode -SkipPresenceCheck:$SkipPresenceCheck
    }
    return $results
  }

  $queue = New-Object System.Collections.Generic.Queue[string]
  foreach ($slot in $Slots) { $queue.Enqueue([string]$slot) }
  while ($queue.Count -gt 0) {
    $batch = New-Object System.Collections.Generic.List[string]
    while ($queue.Count -gt 0 -and $batch.Count -lt [int]$ocrParallelMaxWorkers) {
      [void]$batch.Add($queue.Dequeue())
    }
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($slot in $batch) {
      $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
      if (-not (Test-RegionSelected -Rect $slotRect)) {
        $results[$slot] = [pscustomobject]@{
          status = "error"
          token = "??"
          preview = ""
          variant = ""
          source = ""
          message = ("ROI not set for {0}" -f $slot)
          no_card = $false
          white_ratio = 0.0
          green_ratio = 0.0
        }
        continue
      }
      $job = Start-ThreadJob -ArgumentList @(
        [string]$slot,
        [int]$slotRect.X, [int]$slotRect.Y, [int]$slotRect.Width, [int]$slotRect.Height,
        [string]$TmpDir,
        [string]$SlotTagPrefix,
        [bool]$FastMode,
        [bool]$SkipPresenceCheck,
        [string]$ollamaHost,
        [string]$ollamaVisionModel,
        [string]$ollamaVisionKeepAlive
      ) -ScriptBlock {
        param(
          $slotName, $x, $y, $w, $h, $tmpDirPath, $slotPrefix,
          $fastModeFlag, $skipPresenceFlag, $hostUrl, $visionModel, $keepAliveValue
        )
        Add-Type -AssemblyName System.Drawing
        function Get-Presence {
          param([int]$rx,[int]$ry,[int]$rw,[int]$rh)
          $bmp = $null
          $gfx = $null
          try {
            $bmp = New-Object System.Drawing.Bitmap($rw, $rh)
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            $gfx.CopyFromScreen($rx, $ry, 0, 0, $bmp.Size)
            [int]$white = 0
            [int]$green = 0
            [int]$total = 0
            for ($py = 0; $py -lt $bmp.Height; $py += 2) {
              for ($px = 0; $px -lt $bmp.Width; $px += 2) {
                $c = $bmp.GetPixel($px, $py)
                $total += 1
                if ($c.R -ge 175 -and $c.G -ge 175 -and $c.B -ge 175) { $white += 1 }
                if ($c.G -ge 70 -and $c.G -ge ($c.R + 20) -and $c.G -ge ($c.B + 10)) { $green += 1 }
              }
            }
            if ($total -le 0) {
              return [pscustomobject]@{ likely_card = $true; white_ratio = 0.0; green_ratio = 0.0 }
            }
            $wr = [double]$white / [double]$total
            $gr = [double]$green / [double]$total
            $likely = -not ($wr -lt 0.10 -and $gr -gt 0.60)
            return [pscustomobject]@{ likely_card = $likely; white_ratio = $wr; green_ratio = $gr }
          }
          catch {
            return [pscustomobject]@{ likely_card = $true; white_ratio = 0.0; green_ratio = 0.0 }
          }
          finally {
            if ($null -ne $gfx) { $gfx.Dispose() }
            if ($null -ne $bmp) { $bmp.Dispose() }
          }
        }
        function Get-TokenFromText {
          param([string]$text)
          $raw = ([string]$text).Trim()
          if (-not $raw) { return "??" }
          if ($raw -match "(?i)\b([AKQJT98765432])\s*([shdc])\b") { return ($matches[1] + $matches[2]).ToUpperInvariant() }
          if ($raw -match "(?i)\b(10)\s*([shdc])\b") { return ("T" + $matches[2]).ToUpperInvariant() }
          $rankMap = @{
            "ace"="A"; "king"="K"; "queen"="Q"; "jack"="J"; "ten"="T"; "nine"="9"; "eight"="8"; "seven"="7"; "six"="6"; "five"="5"; "four"="4"; "three"="3"; "two"="2"
          }
          $suitMap = @{
            "spade"="S"; "spades"="S"; "heart"="H"; "hearts"="H"; "diamond"="D"; "diamonds"="D"; "club"="C"; "clubs"="C"
          }
          $rank = ""
          $suit = ""
          foreach ($k in $rankMap.Keys) { if ($raw -match ("(?i)\b{0}\b" -f [regex]::Escape($k))) { $rank = [string]$rankMap[$k]; break } }
          foreach ($k in $suitMap.Keys) { if ($raw -match ("(?i)\b{0}\b" -f [regex]::Escape($k))) { $suit = [string]$suitMap[$k]; break } }
          if ($rank -and $suit) { return ($rank + $suit).ToUpperInvariant() }
          return "??"
        }
        function Capture-And-Call {
          param([int]$cx,[int]$cy,[int]$cw,[int]$ch,[string]$imgPath,[string]$host,[string]$model,[string]$keepAlive)
          $bmp = $null
          $gfx = $null
          try {
            $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            $gfx.CopyFromScreen($cx, $cy, 0, 0, $bmp.Size)
            $bmp.Save($imgPath, [System.Drawing.Imaging.ImageFormat]::Png)
          }
          finally {
            if ($null -ne $gfx) { $gfx.Dispose() }
            if ($null -ne $bmp) { $bmp.Dispose() }
          }
          $bytes = [System.IO.File]::ReadAllBytes($imgPath)
          $b64 = [Convert]::ToBase64String($bytes)
          $prompt = 'Read exactly one poker community card from this image crop. Return JSON only with key: {"card":"??"}. Replace ?? with a valid rank+suit token only when clearly visible, using ranks AKQJT98765432 and suits shdc. If uncertain keep ??.'
          $payload = @{
            model = $model
            prompt = $prompt
            images = @($b64)
            stream = $false
            keep_alive = $keepAlive
            format = "json"
            options = @{ temperature = 0; top_p = 0.1; num_predict = 32 }
          }
          $jsonBody = ConvertTo-Json $payload -Depth 8 -Compress
          $resp = Invoke-RestMethod -Uri ("{0}/api/generate" -f ([string]$host).TrimEnd("/")) -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec 90
          $respText = if ($resp.response -is [System.Array]) { [string]::Join(" ", ($resp.response | ForEach-Object { [string]$_ })) } else { [string]$resp.response }
          return $respText
        }
        try {
          if ($w -le 0 -or $h -le 0) {
            return [pscustomobject]@{ slot=$slotName; status="error"; token="??"; preview=""; variant=""; source=""; message="invalid_region"; no_card=$false; white_ratio=0.0; green_ratio=0.0 }
          }
          $presence = Get-Presence -rx $x -ry $y -rw $w -rh $h
          if ((-not $skipPresenceFlag) -and (-not $presence.likely_card)) {
            return [pscustomobject]@{ slot=$slotName; status="ok"; token="NO_CARD"; preview=""; variant=""; source=""; message=""; no_card=$true; white_ratio=[double]$presence.white_ratio; green_ratio=[double]$presence.green_ratio }
          }

          $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
          $cropW = [Math]::Max(8, [int]($w * 0.45))
          $cropH = [Math]::Max(8, [int]($h * 0.52))
          $imgPath = Join-Path $tmpDirPath ("vision_{0}_{1}_{2}.png" -f $slotPrefix, $slotName, $stamp)
          $raw = Capture-And-Call -cx $x -cy $y -cw $cropW -ch $cropH -imgPath $imgPath -host $hostUrl -model $visionModel -keepAlive $keepAliveValue
          $token = Get-TokenFromText -text $raw
          if ($token -eq "??" -and (-not $fastModeFlag)) {
            $imgPath2 = Join-Path $tmpDirPath ("vision_{0}_{1}_{2}_full.png" -f $slotPrefix, $slotName, $stamp)
            $raw2 = Capture-And-Call -cx $x -cy $y -cw $w -ch $h -imgPath $imgPath2 -host $hostUrl -model $visionModel -keepAlive $keepAliveValue
            $token2 = Get-TokenFromText -text $raw2
            if ($token2 -ne "??") {
              $token = $token2
              $raw = $raw2
              return [pscustomobject]@{ slot=$slotName; status="ok"; token=$token; preview=[string]$raw; variant=[System.IO.Path]::GetFileName($imgPath2); source="full"; message=""; no_card=$false; white_ratio=[double]$presence.white_ratio; green_ratio=[double]$presence.green_ratio }
            }
          }
          $src = if ($fastModeFlag) { "rankcrop2_fast" } else { "rankcrop2" }
          return [pscustomobject]@{ slot=$slotName; status="ok"; token=$token; preview=[string]$raw; variant=[System.IO.Path]::GetFileName($imgPath); source=$src; message=""; no_card=$false; white_ratio=[double]$presence.white_ratio; green_ratio=[double]$presence.green_ratio }
        }
        catch {
          return [pscustomobject]@{ slot=$slotName; status="error"; token="??"; preview=""; variant=""; source=""; message=$_.Exception.Message; no_card=$false; white_ratio=0.0; green_ratio=0.0 }
        }
      }
      [void]$jobs.Add($job)
    }
    foreach ($job in $jobs) {
      try {
        Wait-Job -Id $job.Id -Timeout 120 | Out-Null
      } catch {}
      $row = $null
      try {
        $rows = Receive-Job -Id $job.Id -ErrorAction SilentlyContinue
        if ($rows -is [System.Array] -and $rows.Count -gt 0) {
          $row = $rows[$rows.Count - 1]
        } else {
          $row = $rows
        }
      } catch {}
      try { Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue } catch {}
      if ($null -eq $row) { continue }
      $slotName = [string]$row.slot
      if (-not $slotName) { continue }
      $results[$slotName] = [pscustomobject]@{
        status = [string]$row.status
        token = [string]$row.token
        preview = [string]$row.preview
        variant = [string]$row.variant
        source = [string]$row.source
        message = [string]$row.message
        no_card = [bool]$row.no_card
        white_ratio = [double]$row.white_ratio
        green_ratio = [double]$row.green_ratio
      }
    }
  }

  foreach ($slot in $Slots) {
    if ($null -eq $results[$slot]) {
      $results[$slot] = Resolve-CardTokenForSlot -Slot $slot -TmpDir $TmpDir -SlotTagPrefix $SlotTagPrefix -FastMode:$FastMode -SkipPresenceCheck:$SkipPresenceCheck
    }
  }
  return $results
}

function Run-OcrSingleSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [switch]$FastMode
  )

  if ($isBusy) {
    return
  }
  if (-not ($allSlotOrder -contains $Slot)) {
    Write-Log ("Single-slot OCR skipped: unknown slot '{0}'." -f $Slot)
    return
  }
  if (-not (Test-OllamaEndpoint)) {
    Write-Log ("Vision skipped: Ollama endpoint unavailable at {0}." -f $ollamaHost)
    return
  }

  $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$Slot]
  if (-not (Test-RegionSelected -Rect $slotRect)) {
    Write-Log ("Single-slot OCR skipped: ROI not set for {0}." -f $Slot)
    return
  }

  $script:isBusy = $true
  $restoreOverlaysAfter = $false
  try {
    if ($overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 50
    }

    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $resolved = Resolve-CardTokenForSlot -Slot $Slot -TmpDir $tmpDir -SlotTagPrefix "single" -FastMode:$FastMode -SkipPresenceCheck:($Slot -in $playerSlotOrder)
    if ($resolved.status -ne "ok") {
      Write-Log ("OCR ERROR [{0}]: {1}" -f $Slot, $resolved.message)
      return
    }
    if ($resolved.no_card) {
      if ($Slot -in $playerSlotOrder) {
        $heroCards[$Slot] = "NO_CARD"
      }
      elseif ($Slot -in $cardSlotOrder) {
        Update-LastBoardTokenFromSlot -Slot $Slot -Token "??"
      }
      Write-Log ("OCR NO_CARD [{0}] white={1:P1}, green={2:P1}" -f $Slot, [double]$resolved.white_ratio, [double]$resolved.green_ratio)
      $txtLatest.Text = @(
        "run:   single_slot"
        ("slot:  {0}" -f $Slot)
        "card:  NO_CARD"
        ("hero_cards: {0}" -f (Get-HeroCardsText))
        ("board: {0}" -f (Get-BoardTokensText))
      ) -join "`r`n"
      if (($Slot -in $playerSlotOrder) -and (-not $suppressHeroAutoSend)) {
        Try-AutoSendHeroCardsToEngine
      }
      return
    }
    if ($resolved.token -eq "??") {
      if ($Slot -in $playerSlotOrder) {
        $heroCards[$Slot] = "??"
      }
      elseif ($Slot -in $cardSlotOrder) {
        Update-LastBoardTokenFromSlot -Slot $Slot -Token "??"
      }
      Write-Log ("OCR warning [Cards (local vision llava)] {0}: no readable output." -f $Slot)
      $txtLatest.Text = @(
        "run:   single_slot"
        ("slot:  {0}" -f $Slot)
        "card:  ??"
        ("hero_cards: {0}" -f (Get-HeroCardsText))
        ("board: {0}" -f (Get-BoardTokensText))
      ) -join "`r`n"
      if (($Slot -in $playerSlotOrder) -and (-not $suppressHeroAutoSend)) {
        Try-AutoSendHeroCardsToEngine
      }
      return
    }

    $token = [string]$resolved.token
    Write-Log ("OCR OK [Cards (local vision llava)] {0} via {1}/{2}: parsed={3} (raw={4})" -f $Slot, $resolved.variant, $resolved.source, $token, $resolved.preview) -Type "ocr_slot" -Data @{
      slot = $Slot
      parsed = $token
      raw = [string]$resolved.preview
      source = [string]$resolved.source
      variant = [string]$resolved.variant
    }
    if ($Slot -in $playerSlotOrder) {
      $heroCards[$Slot] = $token
      if (-not $suppressHeroAutoSend) {
        Try-AutoSendHeroCardsToEngine
      }
    }
    elseif ($Slot -in $cardSlotOrder) {
      Update-LastBoardTokenFromSlot -Slot $Slot -Token $token
      $manualBoardReady = Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)
      if ($manualBoardReady) {
        [void](Queue-EngineSolveForBoard -BoardTokens @($lastBoardTokens) -StageLabel "manual_single")
      }
    }
    $txtLatest.Text = @(
      "run:   single_slot"
      ("slot:  {0}" -f $Slot)
      ("card:  {0}" -f $token)
      ("hero_cards: {0}" -f (Get-HeroCardsText))
      ("board: {0}" -f (Get-BoardTokensText))
      ("board_ready: {0}" -f (Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)))
      ("source:{0}/{1}" -f [string]$resolved.variant, [string]$resolved.source)
    ) -join "`r`n"
  }
  catch {
    Write-Log ("OCR ERROR: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("OCR ERROR at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
  }
  finally {
    if ($restoreOverlaysAfter) {
      Set-OverlayVisibilityForCapture -Enable $true
    }
    $script:isBusy = $false
  }
}

function Queue-EngineSolveForBoard {
  param(
    [Parameter(Mandatory = $true)][string[]]$BoardTokens,
    [Parameter(Mandatory = $true)][string]$StageLabel
  )

  $heroReady = Get-HeroCardsReady
  $heroTokens = @()
  if ($heroReady) {
    $heroTokens = @([string]$heroCards["hero1"], [string]$heroCards["hero2"])
  }
  $logicalStateKey = Get-EngineLogicalStateKey -BoardTokens $BoardTokens -HeroTokens $heroTokens -StageLabel $StageLabel
  if ($logicalStateKey -and (($logicalStateKey -eq $engineLastQueuedLogicalKey) -or ($logicalStateKey -eq $engineLastCompletedLogicalKey))) {
    $script:engineQueueSkipNoChangeCount = [int]$engineQueueSkipNoChangeCount + 1
    Write-Log ("Engine handoff skipped ({0}): no logical state change." -f $StageLabel) -Type "engine_skip_nochange_logical" -Data @{
      stage = $StageLabel
      logical_state = $logicalStateKey
      skip_count = [int]$engineQueueSkipNoChangeCount
    }
    Update-EngineButtonState
    return $false
  }

  $boardText = ($BoardTokens -join " ")
  Write-Log ("Engine handoff queued ({0}): board {1} -> {2}" -f $StageLabel, $boardText, $bridgeSolveEndpoint) -Type "engine_queue" -Data @{
    stage = $StageLabel
    board = $BoardTokens
    hero_cards = if ($heroReady) { $heroTokens } else { @() }
    endpoint = $bridgeSolveEndpoint
    runtime_profile = $engineRuntimeProfile
    llm_preset = $engineLlmPreset
    solver_timeout_sec = [int]$engineSolverTimeoutSec
  }

  try {
    $spot = Build-EngineSpotPayload -BoardCards $BoardTokens -Label $StageLabel -HeroCards $heroTokens
    $requestPayload = [ordered]@{
      spot = $spot
      timeout_sec = [int]$engineSolverTimeoutSec
      quiet = $true
      llm = [ordered]@{
        preset = [string]$engineLlmPreset
      }
      runtime_profile = [string]$engineRuntimeProfile
    }
    if ($engineEnableMultiNode) {
      $requestPayload.enable_multi_node_locks = $true
    }

    if (-not (Test-Path $engineOutputDir)) {
      New-Item -Path $engineOutputDir -ItemType Directory -Force | Out-Null
    }
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
    $payloadPath = Join-Path $engineOutputDir ("{0}_payload_{1}.json" -f $StageLabel, $stamp)
    $responsePath = Join-Path $engineOutputDir ("{0}_response_{1}.json" -f $StageLabel, $stamp)
    $requestJson = $requestPayload | ConvertTo-Json -Depth 16
    $stateHash = Get-EngineStateFingerprintFromJson -JsonText $requestJson
    if ($stateHash -and (($stateHash -eq $engineLastQueuedStateHash) -or ($stateHash -eq $engineLastCompletedStateHash))) {
      $script:engineQueueSkipNoChangeCount = [int]$engineQueueSkipNoChangeCount + 1
      Write-Log ("Engine handoff skipped ({0}): no state change (hash={1})." -f $StageLabel, $stateHash.Substring(0, 10)) -Type "engine_skip_nochange" -Data @{
        stage = $StageLabel
        state_hash = $stateHash
        skip_count = [int]$engineQueueSkipNoChangeCount
      }
      Update-EngineButtonState
      return $false
    }
    if ($engineHandoffBusy -and $enginePendingJobs.Count -gt 0) {
      $newPriority = Get-EngineStagePriority -StageLabel $StageLabel
      $oldestPending = Get-OldestPendingEngineMeta
      if ($enginePriorityRoutingEnabled -and $null -ne $oldestPending) {
        $oldPriority = [int]$oldestPending.priority
        $oldAge = [double]$oldestPending.age_sec
        if (($newPriority -lt $oldPriority) -and ($oldAge -lt [double]$enginePriorityHoldSec)) {
          $script:engineQueuePrioritySkipCount = [int]$engineQueuePrioritySkipCount + 1
          Write-Log ("Engine handoff skipped ({0}): lower priority than active job (new={1}, active={2}, active_stage={3}, active_age={4:N2}s)." -f `
            $StageLabel, [int]$newPriority, [int]$oldPriority, [string]$oldestPending.stage, [double]$oldAge) -Type "engine_skip_priority" -Data @{
            stage = $StageLabel
            stage_priority = [int]$newPriority
            active_job_id = [int]$oldestPending.job_id
            active_stage = [string]$oldestPending.stage
            active_priority = [int]$oldPriority
            active_age_sec = [double]$oldAge
            hold_sec = [double]$enginePriorityHoldSec
            skip_priority_count = [int]$engineQueuePrioritySkipCount
          }
          Update-EngineButtonState
          return $false
        }
      }
      Stop-AllEngineJobs -Reason "newer_state_arrived"
      Write-Log ("Engine handoff replacing obsolete in-flight state ({0})." -f $StageLabel) -Type "engine_queue_replace" -Data @{
        stage = $StageLabel
        new_state_hash = $stateHash
      }
    }
    Set-Content -Path $payloadPath -Value $requestJson -Encoding UTF8

    $script:engineStateVersion = [int]$engineStateVersion + 1
    $stateVersion = [int]$engineStateVersion
    $job = Start-Job -Name ("engine_{0}_{1}" -f $StageLabel, $stamp) -ArgumentList @(
      $bridgeSolveEndpoint,
      $requestJson,
      $responsePath,
      [int]([Math]::Max(60, $engineSolverTimeoutSec + 30))
    ) -ScriptBlock {
      param($endpoint, $requestJsonText, $responsePathValue, $timeoutSecValue)
      $started = Get-Date
      try {
        $resp = Invoke-RestMethod -Uri ([string]$endpoint) -Method Post -ContentType "application/json" -Body ([string]$requestJsonText) -TimeoutSec ([int]$timeoutSecValue)
        $respJson = $resp | ConvertTo-Json -Depth 20
        Set-Content -Path ([string]$responsePathValue) -Value $respJson -Encoding UTF8
        $elapsedSec = ((Get-Date) - $started).TotalSeconds
        $selected = ""
        if ($resp.PSObject.Properties.Name -contains "selected_strategy") {
          $selected = [string]$resp.selected_strategy
        }
        $exploitability = $null
        if ($resp.PSObject.Properties.Name -contains "result" -and $resp.result -and ($resp.result.PSObject.Properties.Name -contains "exploitability")) {
          $exploitability = $resp.result.exploitability
        }
        $kept = $null
        if ($resp.PSObject.Properties.Name -contains "node_lock_kept") {
          $kept = [bool]$resp.node_lock_kept
        }
        $llmErr = ""
        if ($resp.PSObject.Properties.Name -contains "llm_error" -and $resp.llm_error) {
          $llmErr = [string]$resp.llm_error
        }
        [pscustomobject]@{
          ok = $true
          elapsed_sec = [double]$elapsedSec
          selected_strategy = $selected
          exploitability = $exploitability
          node_lock_kept = $kept
          llm_error = $llmErr
          response_path = [string]$responsePathValue
        }
      }
      catch {
        [pscustomobject]@{
          ok = $false
          error = $_.Exception.Message
          response_path = [string]$responsePathValue
        }
      }
    }

    $enginePendingJobs[$job.Id] = @{
      payload_path = $payloadPath
      response_path = $responsePath
      stage = $StageLabel
      board = $BoardTokens
      state_hash = $stateHash
      logical_key = $logicalStateKey
      state_version = [int]$stateVersion
      queued_utc = (Get-Date).ToUniversalTime()
      max_age_sec = [int]$engineJobMaxAgeSec
    }
    if ($stateHash) {
      $script:engineLastQueuedStateHash = $stateHash
    }
    if ($logicalStateKey) {
      $script:engineLastQueuedLogicalKey = $logicalStateKey
    }
    $script:engineHandoffBusy = $true
    Update-EngineButtonState
    Write-Log ("Engine job started (id={0}, v={1}). UI remains responsive." -f $job.Id, [int]$stateVersion) -Type "engine_job_started" -Data @{
      job_id = [int]$job.Id
      state_version = [int]$stateVersion
      state_hash = $stateHash
      stage = $StageLabel
      board = $BoardTokens
      max_age_sec = [int]$engineJobMaxAgeSec
      payload_path = $payloadPath
      response_path = $responsePath
    }
    Write-Log ("Engine artifacts (pending): payload={0}, response={1}" -f $payloadPath, $responsePath)
    return $true
  }
  catch {
    Write-Log ("Engine handoff error ({0}): {1}" -f $StageLabel, $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("Engine handoff error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
    return $false
  }
}

function Try-AutoSendHeroCardsToEngine {
  if (-not (Get-HeroCardsReady)) {
    return
  }
  if (-not (Get-BoardReadyFromTokens -Tokens $lastBoardTokens)) {
    Write-Log ("Hero cards ready ({0}) but board not ready; auto-send waiting for flop/turn/river capture." -f (Get-HeroCardsText)) -Type "hero_waiting_board"
    return
  }
  $key = ("{0}|{1}|{2}" -f [string]$heroCards["hero1"], [string]$heroCards["hero2"], ($lastBoardTokens -join ","))
  if ($key -eq $lastHeroAutoSendKey) {
    return
  }
  if (Queue-EngineSolveForBoard -BoardTokens $lastBoardTokens -StageLabel "hero_auto") {
    $script:lastHeroAutoSendKey = $key
  }
}

function Run-OcrBoardSetAndQueueEngine {
  param(
    [Parameter(Mandatory = $true)][string]$StageLabel,
    [Parameter(Mandatory = $true)][string[]]$Slots
  )
  if ($isBusy) {
    return
  }
  if (-not (Test-OllamaEndpoint)) {
    Write-Log ("Vision skipped: Ollama endpoint unavailable at {0}." -f $ollamaHost)
    return
  }

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $Slots) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missing.Add([string]$slot)
    }
  }
  if ($missing.Count -gt 0) {
    Write-Log ("{0} OCR skipped: set ROIs first ({1})." -f $StageLabel, ($missing -join ", "))
    return
  }

  $script:isBusy = $true
  $restoreOverlaysAfter = $false
  $previousKeepAlive = [string]$ollamaVisionKeepAlive
    $useFastPrimary = $true
  try {
    if ($overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 50
    }
    # Keep model warm for the current staged pass (flop/turn/river),
    # then release it in finally to preserve VRAM for solver tasks.
    $script:ollamaVisionKeepAlive = "20s"

    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $cards = @{}
    $previewBySlot = @{}
    $resolvedBatch = Resolve-CardTokensBatch -Slots $Slots -TmpDir $tmpDir -SlotTagPrefix ("{0}set" -f $StageLabel.ToLowerInvariant()) -FastMode:$useFastPrimary
    foreach ($slot in $Slots) {
      $resolved = $resolvedBatch[$slot]
      if ($null -eq $resolved) {
        $resolved = Resolve-CardTokenForSlot -Slot $slot -TmpDir $tmpDir -SlotTagPrefix ("{0}set" -f $StageLabel.ToLowerInvariant()) -FastMode:$useFastPrimary
      }
      if ($resolved.status -ne "ok") {
        $cards[$slot] = "??"
        Write-Log ("OCR ERROR [{0}]: {1}" -f $slot, $resolved.message)
        continue
      }
      if ($resolved.no_card) {
        $cards[$slot] = "NO_CARD"
        Write-Log ("OCR NO_CARD [{0}] white={1:P1}, green={2:P1}" -f $slot, [double]$resolved.white_ratio, [double]$resolved.green_ratio)
        continue
      }
      $token = ([string]$resolved.token).Trim().ToUpperInvariant()
      if ($rankOnlyMode) {
        $token = Convert-ToRankOnlyToken -Token $token
      }
      elseif (Test-CardTokenStrict -Token $token) {
        $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
        $ovr = Apply-SuitHintOverride -Token $token -Region $slotRect
        if ($ovr.changed) {
          $token = [string]$ovr.token
        }
      }
      $cards[$slot] = $token
      $previewBySlot[$slot] = [string]$resolved.preview
      if ($cards[$slot] -eq "??") {
        continue
      }
      Write-Log ("OCR OK [Cards (local vision llava)] {0} via {1}/{2}: parsed={3} (raw={4})" -f $slot, $resolved.variant, $resolved.source, $cards[$slot], $resolved.preview) -Type "ocr_slot" -Data @{
        slot = $slot
        parsed = $cards[$slot]
        raw = [string]$resolved.preview
        source = [string]$resolved.source
        variant = [string]$resolved.variant
      }
    }

    $retrySlots = New-Object System.Collections.Generic.List[string]
    foreach ($slot in $Slots) {
      $tk = if ($cards.ContainsKey($slot)) { ([string]$cards[$slot]).Trim().ToUpperInvariant() } else { "??" }
      if (-not (Test-CardTokenStrict -Token $tk)) {
        [void]$retrySlots.Add([string]$slot)
      }
    }
    if ($retrySlots.Count -gt 0) {
      Write-Log ("{0} batch retry: unresolved slots -> {1}" -f $StageLabel, ($retrySlots -join ", "))
      Start-Sleep -Milliseconds 120
      foreach ($slot in $retrySlots) {
        $retryResolved = Resolve-CardTokenForSlot -Slot $slot -TmpDir $tmpDir -SlotTagPrefix ("{0}retry" -f $StageLabel.ToLowerInvariant())
        if ($retryResolved.status -ne "ok") {
          continue
        }
        if ($retryResolved.no_card) {
          continue
        }
        $retryToken = ([string]$retryResolved.token).Trim().ToUpperInvariant()
        if ($retryToken -eq "??") {
          continue
        }
        $cards[$slot] = $retryToken
        $previewBySlot[$slot] = [string]$retryResolved.preview
        Write-Log ("OCR RETRY OK [Cards (local vision llava)] {0} via {1}/{2}: parsed={3} (raw={4})" -f $slot, $retryResolved.variant, $retryResolved.source, $retryToken, [string]$retryResolved.preview) -Type "ocr_slot_retry" -Data @{
          slot = $slot
          parsed = $retryToken
          raw = [string]$retryResolved.preview
          source = [string]$retryResolved.source
          variant = [string]$retryResolved.variant
        }
      }
    }

    $boardTokens = @()
    foreach ($slot in $Slots) {
      if ($cards.ContainsKey($slot)) {
        $boardTokens += [string]$cards[$slot]
      }
      else {
        $boardTokens += "??"
      }
    }
    $boardReady = Get-BoardReadyFromTokens -Tokens $boardTokens
    $script:lastBoardTokens = @($boardTokens)

    $outLines = @(
      ("run:   {0}_only" -f $StageLabel.ToLowerInvariant())
      ("board: {0}" -f ($boardTokens -join " "))
      ("board_ready: {0}" -f $boardReady)
      ("hero_cards: {0}" -f (Get-HeroCardsText))
    )
    if ($Slots.Count -ge 3) {
      $outLines += ("flop:  {0} {1} {2}" -f $boardTokens[0], $boardTokens[1], $boardTokens[2])
    }
    $out = ($outLines -join "`r`n")
    $txtLatest.Text = $out
    Write-Log ("{0} OCR summary: {1}" -f $StageLabel, ($out -replace "\r?\n", " | ")) -Type "board_summary" -Data @{
      stage = $StageLabel
      board = $boardTokens
      ready = [bool]$boardReady
      hero_cards = @([string]$heroCards["hero1"], [string]$heroCards["hero2"])
    }
    if (-not $boardReady) {
      Write-Log ("Engine handoff skipped: {0} board not ready (requires valid rank+suit cards)." -f $StageLabel)
      return
    }
    [void](Queue-EngineSolveForBoard -BoardTokens $boardTokens -StageLabel $StageLabel.ToLowerInvariant())
  }
  catch {
    Write-Log ("OCR ERROR: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("OCR ERROR at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
  }
  finally {
    $script:ollamaVisionKeepAlive = $previousKeepAlive
    Release-OllamaVisionModel
    if ($restoreOverlaysAfter) {
      Set-OverlayVisibilityForCapture -Enable $true
    }
    $script:isBusy = $false
  }
}

function Run-OcrFlopSet {
  Run-OcrBoardSetAndQueueEngine -StageLabel "Flop" -Slots @("flop1", "flop2", "flop3")
}

function Reset-NewHandState {
  # Reset solver/engine-relevant hand state only. Keep ROI overlays and UI layout untouched.
  $script:lastBoardTokens = @()
  $script:lastHeroAutoSendKey = ""
  $script:engineLastQueuedStateHash = ""
  $script:engineLastCompletedStateHash = ""
  $script:engineLastQueuedLogicalKey = ""
  $script:engineLastCompletedLogicalKey = ""
  $heroCards["hero1"] = "??"
  $heroCards["hero2"] = "??"
  Write-Log "New hand reset: cleared solver state; waiting for fresh hero cards."
}

function Run-OcrHeroSet {
  if ($isBusy) {
    return
  }
  if (-not (Test-OllamaEndpoint)) {
    Write-Log ("Vision skipped: Ollama endpoint unavailable at {0}." -f $ollamaHost)
    return
  }

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $playerSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missing.Add([string]$slot)
    }
  }
  if ($missing.Count -gt 0) {
    Write-Log ("Run Hero skipped: set hero ROIs first ({0})." -f ($missing -join ", "))
    return
  }

  $started = Get-Date
  $restoreOverlaysAfter = $false
  $previousKeepAlive = [string]$ollamaVisionKeepAlive
  $script:isBusy = $true
  $script:suppressHeroAutoSend = $true
  try {
    if ($overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 40
    }

    # Keep model warm only for hero1->hero2 sequence, then unload.
    $script:ollamaVisionKeepAlive = "20s"
    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $resolvedBatch = Resolve-CardTokensBatch -Slots $playerSlotOrder -TmpDir $tmpDir -SlotTagPrefix "hero" -FastMode -SkipPresenceCheck
    foreach ($slot in $playerSlotOrder) {
      $resolved = $resolvedBatch[$slot]
      if ($null -eq $resolved) {
        $resolved = Resolve-CardTokenForSlot -Slot $slot -TmpDir $tmpDir -SlotTagPrefix "hero" -FastMode -SkipPresenceCheck
      }
      $needsRetry = $false
      if ($resolved.status -ne "ok" -or $resolved.no_card) {
        $needsRetry = $true
      }
      else {
        $initialToken = ([string]$resolved.token).Trim().ToUpperInvariant()
        if (-not (Test-CardTokenStrict -Token $initialToken)) {
          $needsRetry = $true
        }
      }

      if ($needsRetry) {
        $resolvedRetry = Resolve-CardTokenForSlot -Slot $slot -TmpDir $tmpDir -SlotTagPrefix "hero_retry" -SkipPresenceCheck
        if ($resolvedRetry.status -eq "ok" -and (-not $resolvedRetry.no_card)) {
          $retryToken = ([string]$resolvedRetry.token).Trim().ToUpperInvariant()
          if (Test-CardTokenStrict -Token $retryToken) {
            $resolved = $resolvedRetry
            Write-Log ("Hero OCR RETRY OK [{0}] via {1}/{2}: parsed={3} (raw={4})" -f $slot, $resolved.variant, $resolved.source, $retryToken, $resolved.preview) -Type "ocr_slot_retry" -Data @{
              slot = $slot
              parsed = $retryToken
              raw = [string]$resolved.preview
              source = [string]$resolved.source
              variant = [string]$resolved.variant
            }
          }
        }
      }

      if ($resolved.status -ne "ok") {
        $heroCards[$slot] = "??"
        Write-Log ("Hero OCR ERROR [{0}]: {1}" -f $slot, $resolved.message)
        continue
      }
      if ($resolved.no_card) {
        $heroCards[$slot] = "NO_CARD"
        Write-Log ("Hero OCR NO_CARD [{0}] white={1:P1}, green={2:P1}" -f $slot, [double]$resolved.white_ratio, [double]$resolved.green_ratio)
        continue
      }
      $token = ([string]$resolved.token).Trim().ToUpperInvariant()
      if (-not $token) {
        $token = "??"
      }
      $heroCards[$slot] = $token
      if (-not (Test-CardTokenStrict -Token $token)) {
        Write-Log ("Hero OCR warning [{0}]: no readable output." -f $slot)
        continue
      }
      Write-Log ("Hero OCR OK [{0}] via {1}/{2}: parsed={3} (raw={4})" -f $slot, $resolved.variant, $resolved.source, $token, $resolved.preview) -Type "ocr_slot" -Data @{
        slot = $slot
        parsed = $token
        raw = [string]$resolved.preview
        source = [string]$resolved.source
        variant = [string]$resolved.variant
      }
    }

    $heroReady = Get-HeroCardsReady
    $elapsed = ((Get-Date) - $started).TotalSeconds
    $txtLatest.Text = @(
      "run:   hero_only"
      ("hero1: {0}" -f [string]$heroCards["hero1"])
      ("hero2: {0}" -f [string]$heroCards["hero2"])
      ("hero_ready: {0}" -f $heroReady)
      ("elapsed_sec: {0:N2}" -f [double]$elapsed)
    ) -join "`r`n"
    Write-Log ("Hero OCR summary: hero1={0}, hero2={1}, hero_ready={2}, elapsed={3:N2}s" -f
      [string]$heroCards["hero1"],
      [string]$heroCards["hero2"],
      [bool]$heroReady,
      [double]$elapsed) -Type "hero_summary" -Data @{
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
        hero_ready = [bool]$heroReady
        elapsed_sec = [double]$elapsed
      }
  }
  catch {
    Write-Log ("Hero OCR ERROR: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("Hero OCR ERROR at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
  }
  finally {
    $script:ollamaVisionKeepAlive = $previousKeepAlive
    Release-OllamaVisionModel
    if ($restoreOverlaysAfter) {
      Set-OverlayVisibilityForCapture -Enable $true
    }
    $script:suppressHeroAutoSend = $false
    $script:isBusy = $false
  }
}

function Run-OcrTurnSet {
  Run-OcrBoardSetAndQueueEngine -StageLabel "Turn" -Slots @("flop1", "flop2", "flop3", "turn")
}

function Run-OcrRiverSet {
  Run-OcrBoardSetAndQueueEngine -StageLabel "River" -Slots @("flop1", "flop2", "flop3", "turn", "river")
}

function Poll-EngineJobs {
  if ($enginePendingJobs.Count -eq 0) {
    if ($engineHandoffBusy) {
      $script:engineHandoffBusy = $false
      Update-EngineButtonState
    }
    return
  }

  $completedIds = New-Object System.Collections.Generic.List[int]
  foreach ($jobId in @($enginePendingJobs.Keys)) {
    $meta = $enginePendingJobs[$jobId]
    if ($null -eq $meta) {
      [void]$completedIds.Add([int]$jobId)
      continue
    }
    $job = Get-Job -Id ([int]$jobId) -ErrorAction SilentlyContinue
    if ($null -eq $job) {
      [void]$completedIds.Add([int]$jobId)
      continue
    }
    $jobElapsedSec = 0.0
    $maxAgeSec = [int]$engineJobMaxAgeSec
    if ($meta.ContainsKey("max_age_sec") -and $meta.max_age_sec) {
      try { $maxAgeSec = [int]$meta.max_age_sec } catch { $maxAgeSec = [int]$engineJobMaxAgeSec }
    }
    if ($meta.ContainsKey("queued_utc") -and $meta.queued_utc) {
      try {
        $queuedUtc = [datetime]$meta.queued_utc
        $jobElapsedSec = ((Get-Date).ToUniversalTime() - $queuedUtc).TotalSeconds
      }
      catch {
        $jobElapsedSec = 0.0
      }
    }
    if ($job.State -notin @("Completed", "Failed", "Stopped")) {
      if ($jobElapsedSec -ge [double]$maxAgeSec) {
        Write-Log ("Engine job {0} timed out after {1:N1}s (stage={2}, max={3}s). Cleaning up stale job." -f $jobId, [double]$jobElapsedSec, [string]$meta.stage, [int]$maxAgeSec) -Type "engine_job_timeout" -Data @{
          job_id = [int]$jobId
          stage = [string]$meta.stage
          elapsed_sec = [double]$jobElapsedSec
          max_age_sec = [int]$maxAgeSec
        }
        try { Stop-Job -Id ([int]$jobId) -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Id ([int]$jobId) -Force -ErrorAction SilentlyContinue } catch {}
        [void]$completedIds.Add([int]$jobId)
      }
      continue
    }
    try {
      $resultRows = Receive-Job -Id ([int]$jobId) -ErrorAction Stop
    }
    catch {
      Write-Log ("Engine job {0} receive error: {1}" -f $jobId, $_.Exception.Message)
      $resultRows = $null
    }

    $result = $null
    if ($resultRows -is [System.Array] -and $resultRows.Count -gt 0) {
      $result = $resultRows[$resultRows.Count - 1]
    }
    elseif ($null -ne $resultRows) {
      $result = $resultRows
    }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "ok") -and [bool]$result.ok) {
      $script:engineQueueCompletedCount = [int]$engineQueueCompletedCount + 1
      if ($meta.ContainsKey("state_hash") -and $meta.state_hash) {
        $script:engineLastCompletedStateHash = [string]$meta.state_hash
      }
      if ($meta.ContainsKey("logical_key") -and $meta.logical_key) {
        $script:engineLastCompletedLogicalKey = [string]$meta.logical_key
      }
      Write-Log ("Engine response: strategy={0}, exploitability={1}, kept={2}, time={3:N2}s" -f
        $result.selected_strategy,
        $result.exploitability,
        $result.node_lock_kept,
        [double]$result.elapsed_sec) -Type "engine_job_completed" -Data @{
        job_id = [int]$jobId
        state_version = if ($meta.ContainsKey("state_version")) { [int]$meta.state_version } else { 0 }
        state_hash = if ($meta.ContainsKey("state_hash")) { [string]$meta.state_hash } else { "" }
        strategy = [string]$result.selected_strategy
        exploitability = $result.exploitability
        kept = $result.node_lock_kept
        elapsed_sec = [double]$result.elapsed_sec
      }
      if ($result.llm_error) {
        Write-Log ("Engine llm_error: {0}" -f $result.llm_error)
      }
      Write-Log ("Engine artifacts: payload={0}, response={1}" -f $meta.payload_path, $meta.response_path)
    }
    else {
      $errMsg = "unknown error"
      if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "error") -and $result.error) {
        $errMsg = [string]$result.error
      }
      Write-Log ("Engine job {0} failed: {1}" -f $jobId, $errMsg) -Type "engine_job_failed" -Data @{
        job_id = [int]$jobId
        error = $errMsg
      }
      Write-Log ("Engine artifacts: payload={0}, response={1}" -f $meta.payload_path, $meta.response_path)
    }

    try {
      Remove-Job -Id ([int]$jobId) -Force -ErrorAction SilentlyContinue
    }
    catch {}
    [void]$completedIds.Add([int]$jobId)
  }

  foreach ($id in $completedIds) {
    [void]$enginePendingJobs.Remove($id)
  }
  if ($enginePendingJobs.Count -eq 0 -and $engineHandoffBusy) {
    $script:engineHandoffBusy = $false
    Update-EngineButtonState
  }
}

function Run-Ocr {
  if ($isBusy) {
    return
  }
  if (-not (Test-OllamaEndpoint)) {
    Write-Log ("Vision skipped: Ollama endpoint unavailable at {0}." -f $ollamaHost)
    return
  }
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $cardSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missing.Add([string]$slot)
    }
  }
  if ($missing.Count -gt 0) {
    Write-Log ("OCR skipped: set all individual card ROIs first ({0})." -f ($missing -join ", "))
    return
  }
  $overlapWarnings = Get-RoiOverlapWarnings
  foreach ($ow in $overlapWarnings) {
    Write-Log ("ROI warning: {0}. Move boxes apart to avoid duplicate reads." -f $ow)
  }

  $script:isBusy = $true
  $restoreOverlaysAfter = $false
  try {
    if ($overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 50
    }

    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $cards = @{}
    $cardScores = @{}
    foreach ($slot in $cardSlotOrder) {
      $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
      $presence = Get-CardPresenceSignalFromRegion -Region $slotRect
      if (-not $presence.likely_card) {
        $cards[$slot] = "NO_CARD"
        $cardScores[$slot] = -100000
        Write-Log ("OCR NO_CARD [{0}] white={1:P1}, green={2:P1}" -f $slot, [double]$presence.white_ratio, [double]$presence.green_ratio)
        continue
      }
      $bestCard = Get-CardTokenFromVisionRegion -Region $slotRect -TmpDir $tmpDir -SlotTag $slot
      if (-not $bestCard -and $tesseractExe) {
        $fallbackCard = Get-CardTokenFromRegion -Region $slotRect -TmpDir $tmpDir -SlotTag $slot
        if ($fallbackCard -and ([string]$fallbackCard.token).Trim().ToUpperInvariant() -match "^[AKQJT98765432][SHDC]$") {
          $bestCard = $fallbackCard
          Write-Log ("OCR info [{0}] vision miss; recovered with tesseract fallback." -f $slot)
        }
      }
      if (-not $bestCard) {
        $cards[$slot] = "??"
        $cardScores[$slot] = -100000
        Write-Log ("OCR warning [Cards (local vision llava)] {0}: no readable output." -f $slot)
        continue
      }
      $cards[$slot] = $bestCard.token
      if ($rankOnlyMode) {
        $cards[$slot] = Convert-ToRankOnlyToken -Token ([string]$cards[$slot])
      }
      $cardScores[$slot] = if ($null -ne $bestCard.score) { [int]$bestCard.score } else { -100000 }
      $preview = (($bestCard.raw_text -replace "\r?\n", " ") -as [string]).Trim()
      if ($preview.Length -gt 96) {
        $preview = $preview.Substring(0, 96) + "..."
      }
      if (-not $rankOnlyMode) {
        $ovr = Apply-SuitHintOverride -Token ([string]$cards[$slot]) -Region $slotRect
        if ($ovr.changed) {
          $cards[$slot] = [string]$ovr.token
          Write-Log ("OCR info [{0}] suit override applied: {1}" -f $slot, [string]$ovr.reason)
        }
      }
      Write-Log ("OCR OK [Cards (local vision llava)] {0} via {1}/{2}: parsed={3} (raw={4})" -f $slot, $bestCard.variant, $bestCard.source, $cards[$slot], $preview)
    }

    # Sanity pass: if vision returned the exact same card for most/all slots, try tesseract rescue.
    $validSlots = New-Object System.Collections.Generic.List[string]
    $validTokens = New-Object System.Collections.Generic.List[string]
    foreach ($slot in $cardSlotOrder) {
      $tk = ([string]$cards[$slot]).Trim().ToUpperInvariant()
      if ($tk -match "^[AKQJT98765432][SHDC]$") {
        [void]$validSlots.Add($slot)
        [void]$validTokens.Add($tk)
      }
    }
    if ($validTokens.Count -ge 4) {
      $uniq = New-Object System.Collections.Generic.HashSet[string]
      foreach ($t in $validTokens) { [void]$uniq.Add($t) }
      if ($uniq.Count -eq 1 -and $tesseractExe) {
        Write-Log ("OCR warning: identical card token across {0} slots ({1}). Running tesseract rescue pass." -f $validTokens.Count, $validTokens[0])
        foreach ($slot in $cardSlotOrder) {
          $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
          $fallbackCard = Get-CardTokenFromRegion -Region $slotRect -TmpDir $tmpDir -SlotTag ("rescue_{0}" -f $slot)
          if ($fallbackCard -and ([string]$fallbackCard.token).Trim().ToUpperInvariant() -match "^[AKQJT98765432][SHDC]$") {
            $rescueToken = ([string]$fallbackCard.token).Trim().ToUpperInvariant()
            if ($rankOnlyMode) {
              $rescueToken = Convert-ToRankOnlyToken -Token $rescueToken
            }
            $cards[$slot] = $rescueToken
            $cardScores[$slot] = if ($null -ne $fallbackCard.score) { [int]$fallbackCard.score } else { -100000 }
          }
        }
      }
    }

    # If everything is unreadable, attempt one union-board rescue pass.
    $anyValid = $false
    foreach ($slot in $cardSlotOrder) {
      if (([string]$cards[$slot]).Trim().ToUpperInvariant() -match "^[AKQJT98765432][SHDC]$") {
        $anyValid = $true
        break
      }
    }
    if (-not $anyValid) {
      $unionRect = Get-UnionCardRoiBounds -PadX 8 -PadY 8
      if (Test-RegionSelected -Rect $unionRect) {
        $boardGuess = Get-BoardTokensFromVisionRegion -Region $unionRect -TmpDir $tmpDir
        if ($boardGuess -and $boardGuess.cards) {
          $rescued = 0
          foreach ($slot in $cardSlotOrder) {
            $tk = ([string]$boardGuess.cards[$slot]).Trim().ToUpperInvariant()
            if ($tk -match "^[AKQJT98765432][SHDC]$") {
              if ($rankOnlyMode) {
                $tk = Convert-ToRankOnlyToken -Token $tk
              }
              $cards[$slot] = $tk
              $cardScores[$slot] = 80
              $rescued += 1
            }
          }
          if ($rescued -gt 0) {
            Write-Log ("OCR info: union-board rescue recovered {0} card(s)." -f $rescued)
          }
        }
      }
    }

    if (-not $rankOnlyMode) {
      $collisionResult = Resolve-BoardCardCollisions -Cards $cards -CardScores $cardScores
      $cards = $collisionResult.cards
      foreach ($warn in $collisionResult.warnings) {
        Write-Log ("OCR warning [Cards (local vision llava)] {0}" -f $warn)
      }
    }

    $out = @(
      "run:   individual_rois"
      ("flop1: {0}" -f $cards["flop1"])
      ("flop2: {0}" -f $cards["flop2"])
      ("flop3: {0}" -f $cards["flop3"])
      ("turn:  {0}" -f $cards["turn"])
      ("river: {0}" -f $cards["river"])
      ("flop:  {0} {1} {2}" -f $cards["flop1"], $cards["flop2"], $cards["flop3"])
    ) -join "`r`n"
    $txtLatest.Text = $out
    Write-Log ("Board OCR summary: {0}" -f ($out -replace "\r?\n", " | "))
  }
  catch {
    Write-Log ("OCR ERROR: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("OCR ERROR at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
  }
  finally {
    if ($restoreOverlaysAfter) {
      Set-OverlayVisibilityForCapture -Enable $true
    }
    $script:isBusy = $false
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]($numInterval.Value * 1000)
$timer.Add_Tick({
  if ($autoEnabled) {
    Run-Ocr
  }
})

$engineJobTimer = New-Object System.Windows.Forms.Timer
$engineJobTimer.Interval = 500
$engineJobTimer.Add_Tick({
  try {
    Poll-EngineJobs
  }
  catch {
    Write-Log ("Engine poll error: {0}" -f $_.Exception.Message)
    if ($enginePendingJobs.Count -eq 0) {
      $script:engineHandoffBusy = $false
    }
  }
  finally {
    Update-EngineButtonState
  }
})

$btnPick.Add_Click({
  Write-Log "Selecting OCR rectangle..."
  $didClone = $false
  foreach ($key in @($overlayForms.Keys)) {
    try {
      if ($overlayForms[$key] -and -not $overlayForms[$key].IsDisposed) {
        $overlayForms[$key].Hide()
      }
    }
    catch {}
  }
  $form.Hide()
  Start-Sleep -Milliseconds 150
  $rect = Select-ScreenRegion
  $form.Show()
  $form.Activate()
  if ($rect -ne [System.Drawing.Rectangle]::Empty) {
    $target = [string]$cmbTarget.SelectedItem
    if (-not $target) {
      $target = "flop1"
    }
    if ($target -eq "hero") {
      Set-RoiRectByKey -Key "hero1" -Rect $rect
      $regionLabel.Text = ("Selected: hero1 -> X={0}, Y={1}, W={2}, H={3}" -f $rect.X, $rect.Y, $rect.Width, $rect.Height)
      Write-Log ("Card ROI [hero1] set to X={0}, Y={1}, W={2}, H={3}" -f $rect.X, $rect.Y, $rect.Width, $rect.Height)
      $didClone = Clone-Hero1ToHero2Roi
      if ($didClone) {
        Write-Log "Auto-cloned hero ROI: hero1 -> hero2. Drag either overlay to final seat cards."
      }
      else {
        Write-Log "Hero clone skipped: hero1 ROI is empty."
      }
      $cardStatusLabel.Text = Format-CardSlotStatus
    } elseif ($cardRegions.ContainsKey($target)) {
      Set-RoiRectByKey -Key $target -Rect $rect
      $regionLabel.Text = ("Selected: {0} -> X={1}, Y={2}, W={3}, H={4}" -f $target, $rect.X, $rect.Y, $rect.Width, $rect.Height)
      Write-Log ("Card ROI [{0}] set to X={1}, Y={2}, W={3}, H={4}" -f $target, $rect.X, $rect.Y, $rect.Width, $rect.Height)
      if (Should-OfferFlopClonePrompt -Target $target) {
        $cloneChoice = [System.Windows.Forms.MessageBox]::Show(
          "Clone flop1 ROI into flop2, flop3, turn, and river so you can drag each box into place?",
          "Clone ROI?",
          [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($cloneChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
          $didClone = Clone-Flop1ToAllCardRois
          if ($didClone) {
            Write-Log "Cloned flop1 ROI to flop2/flop3/turn/river. Drag each overlay into final position."
          }
          else {
            Write-Log "Clone skipped: flop1 ROI is empty."
          }
        }
      }
      $cardStatusLabel.Text = Format-CardSlotStatus
    } else {
      Write-Log ("Unknown ROI target: {0}" -f $target)
    }
    if (-not $didClone) {
      Save-RoiState
    }
    Refresh-RoiOverlays
  }
  else {
    Write-Log "Rectangle selection canceled."
    Refresh-RoiOverlays
  }
})

$btnOnce.Add_Click({
  Run-Ocr
})

$btnRunFlop1.Add_Click({
  Run-OcrSingleSlot -Slot "flop1"
})
$btnRunFlop2.Add_Click({
  Run-OcrSingleSlot -Slot "flop2"
})
$btnRunFlop3.Add_Click({
  Run-OcrSingleSlot -Slot "flop3"
})
$btnRunTurn.Add_Click({
  Run-OcrTurnSet
})
$btnRunRiver.Add_Click({
  Run-OcrRiverSet
})
$btnRunFlopSet.Add_Click({
  Run-OcrFlopSet
})
$btnRunHero.Add_Click({
  Run-OcrHeroSet
})

$btnAutoStart.Add_Click({
  if (-not (Test-OllamaEndpoint)) {
    [void][System.Windows.Forms.MessageBox]::Show(
      ("Ollama endpoint not reachable at {0}. Start ollama serve first." -f $ollamaHost),
      "Missing Ollama",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $cardSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missing.Add([string]$slot)
    }
  }
  if ($missing.Count -gt 0) {
    [void][System.Windows.Forms.MessageBox]::Show(
      ("Set all five individual card ROIs before auto mode. Missing: {0}" -f ($missing -join ", ")),
      "Missing Card ROIs",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  $timer.Interval = [int]([int]$numInterval.Value * 1000)
  $script:autoEnabled = $true
  $btnAutoStart.Enabled = $false
  $btnAutoStop.Enabled = $true
  Write-Log ("Auto OCR started (every {0}s, individual card mode)." -f [int]$numInterval.Value)
})

$btnAutoStop.Add_Click({
  $script:autoEnabled = $false
  $btnAutoStart.Enabled = $true
  $btnAutoStop.Enabled = $false
  Write-Log "Auto OCR stopped."
})

$btnRunEngine.Add_Click({
  Ensure-BackendsRunning
})

$btnRestart.Add_Click({
  if (-not $PSCommandPath) {
    Write-Log "Restart unavailable: script path not found."
    return
  }
  $script:autoEnabled = $false
  $timer.Stop()
  Save-RoiState
  Close-RoiOverlays
  $hostExe = "powershell.exe"
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $hostExe = "pwsh"
  }
  Start-Process -FilePath $hostExe -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-STA",
    "-File", "`"$PSCommandPath`""
  ) | Out-Null
  try {
    foreach ($jobId in @($enginePendingJobs.Keys)) {
      Remove-Job -Id ([int]$jobId) -Force -ErrorAction SilentlyContinue
    }
  }
  catch {}
  Release-OllamaVisionModel
  try {
    Stop-ManagedBackends
  }
  catch {
    Write-Log ("Shutdown warning during restart: {0}" -f $_.Exception.Message)
  }
  $form.Close()
})

$btnTargets.Add_Click({
  Toggle-RoiOverlays
})

$btnSetHeroes.Add_Click({
  $cmbTarget.SelectedItem = "hero"
  Write-Log "Set Heroes ROI: picking one hero box then auto-cloning to hero2."
  $btnPick.PerformClick()
})

$btnResetRois.Add_Click({
  foreach ($slot in $allSlotOrder) {
    $cardRegions[$slot] = [System.Drawing.Rectangle]::Empty
  }
  $heroCards["hero1"] = "??"
  $heroCards["hero2"] = "??"
  $script:lastHeroAutoSendKey = ""
  $script:lastBoardTokens = @()
  $script:selectedRegion = [System.Drawing.Rectangle]::Empty
  $regionLabel.Text = "Selected: none"
  $cardStatusLabel.Text = Format-CardSlotStatus
  Save-RoiState -ForceWriteEmpty
  Refresh-RoiOverlays
  Write-Log "ROIs reset. Re-pick flop1, flop2, flop3, turn, river, hero, and action button ROIs."
})

$cmbCaptureMode.Add_SelectedIndexChanged({
  $hint.Text = "Individual mode: select target -> Pick ROI -> repeat for board, hero, and action ROIs."
  $cardStatusLabel.Text = Format-CardSlotStatus
  Refresh-RoiOverlays
})

$cmbEngineProfile.Add_SelectedIndexChanged({
  $selected = [string]$cmbEngineProfile.SelectedItem
  if (-not [string]::IsNullOrWhiteSpace($selected)) {
    $script:engineRuntimeProfile = $selected.ToLowerInvariant()
    $script:statusBaseText = ("Local Vision: {0} @ {1} (keep_alive={2}) | card mode: {3} | ocr: {4} | bridge: {5} | profile: {6}" -f `
      $ollamaVisionModel, $ollamaHost, $ollamaVisionKeepAlive, $modeLabel, $parallelLabel, $bridgeSolveEndpoint, $engineRuntimeProfile.ToUpperInvariant())
    Write-Log ("Engine runtime profile set to: {0}" -f $engineRuntimeProfile.ToUpperInvariant()) -Type "engine_runtime_profile" -Data @{
      runtime_profile = $engineRuntimeProfile
    }
    Update-EngineButtonState
  }
})

$form.Add_Shown({
  Initialize-SessionLogs
  Write-Log ("Session logs: text={0}, jsonl={1}" -f $uiLogTextPath, $uiLogJsonlPath) -Type "session_start" -Data @{
    log_text_path = $uiLogTextPath
    log_jsonl_path = $uiLogJsonlPath
    bridge_endpoint = $bridgeSolveEndpoint
    ollama_host = $ollamaHost
    model = $ollamaVisionModel
    keep_alive = $ollamaVisionKeepAlive
    runtime_profile = $engineRuntimeProfile
  }
  Load-RoiState
  $regionLabel.Text = "Selected: none"
  $hint.Text = "Individual mode: select target -> Pick ROI -> repeat for board, hero, and action ROIs."
  $cardStatusLabel.Text = Format-CardSlotStatus
  Update-TargetsButtonText
  Refresh-RoiOverlays
  Ensure-BackendsRunning
  Write-Log "Ready. Select target, pick each ROI, then run OCR."
  $timer.Start()
  $engineJobTimer.Start()
})

$form.Add_KeyDown({
  param($sender, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F8) {
    Toggle-RoiOverlays
    $e.Handled = $true
    $e.SuppressKeyPress = $true
  }
})

$form.Add_FormClosing({
  $script:autoEnabled = $false
  $timer.Stop()
  $engineJobTimer.Stop()
  try {
    foreach ($jobId in @($enginePendingJobs.Keys)) {
      Remove-Job -Id ([int]$jobId) -Force -ErrorAction SilentlyContinue
    }
  }
  catch {}
  $enginePendingJobs.Clear()
  $script:engineHandoffBusy = $false
  Update-EngineButtonState
  Release-OllamaVisionModel
  try {
    Stop-ManagedBackends
  }
  catch {
    Write-Log ("Shutdown warning during close: {0}" -f $_.Exception.Message)
  }
  Save-RoiState
  Close-RoiOverlays
})

[void]$form.ShowDialog()
