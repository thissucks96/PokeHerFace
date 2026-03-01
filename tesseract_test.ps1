[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:startupCrashLogDir = Join-Path $PSScriptRoot "5_Vision_Extraction\out\ui_session_logs"
try {
  if (-not (Test-Path $script:startupCrashLogDir)) {
    $null = New-Item -ItemType Directory -Force -Path $script:startupCrashLogDir
  }
}
catch {}

function Write-StartupCrashLog {
  param(
    [Parameter(Mandatory = $true)]
    [object]$ErrorRecord
  )

  try {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $crashPath = Join-Path $script:startupCrashLogDir ("startup_error_{0}.json" -f $timestamp)
    $payload = [ordered]@{
      timestamp = (Get-Date).ToString("o")
      script = $PSCommandPath
      message = $ErrorRecord.Exception.Message
      type = $ErrorRecord.Exception.GetType().FullName
      category = [string]$ErrorRecord.CategoryInfo
      line = $ErrorRecord.InvocationInfo.ScriptLineNumber
      offset = $ErrorRecord.InvocationInfo.OffsetInLine
      extent = [string]$ErrorRecord.InvocationInfo.Line
      position = [string]$ErrorRecord.InvocationInfo.PositionMessage
      stack = [string]$ErrorRecord.ScriptStackTrace
    }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $crashPath -Encoding UTF8
    Write-Host ("Startup/runtime error logged to: {0}" -f $crashPath) -ForegroundColor Red
  }
  catch {
    Write-Host ("Failed to write startup crash log: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }
}
function Write-UiThreadExceptionLog {
  param(
    [Parameter(Mandatory = $true)]
    [System.Exception]$Exception
  )

  try {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $crashPath = Join-Path $script:startupCrashLogDir ("thread_exception_{0}.json" -f $timestamp)
    $payload = [ordered]@{
      timestamp = (Get-Date).ToString("o")
      script = $PSCommandPath
      message = $Exception.Message
      type = $Exception.GetType().FullName
      source = [string]$Exception.Source
      stack = [string]$Exception.StackTrace
      exception_text = [string]$Exception
    }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $crashPath -Encoding UTF8
    Write-Host ("WinForms thread exception logged to: {0}" -f $crashPath) -ForegroundColor Red
  }
  catch {
    Write-Host ("Failed to write UI thread exception log: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }
}

trap {
  Write-StartupCrashLog -ErrorRecord $_
  Write-Host $_ -ForegroundColor Red
  try {
    Read-Host "Press Enter to exit" | Out-Null
  }
  catch {}
  break
}

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
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
  param($sender, $e)
  if ($null -ne $e -and $null -ne $e.Exception) {
    Write-UiThreadExceptionLog -Exception $e.Exception
  }
})
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
  if ($parsedRuntimeProfile -eq "live_fast") {
    $parsedRuntimeProfile = "fast_live"
  }
  if ($parsedRuntimeProfile -in @("fast", "fast_live", "normal")) {
    $engineRuntimeProfile = $parsedRuntimeProfile
  }
}
$engineFacingPostflopAutoOverrideEnabled = $true
if ($env:ENGINE_FACING_POSTFLOP_AUTOCAP -and ([string]$env:ENGINE_FACING_POSTFLOP_AUTOCAP).Trim().ToLowerInvariant() -in @("0", "false", "no", "off")) {
  $engineFacingPostflopAutoOverrideEnabled = $false
}
$engineFacingPostflopDeadlineSec = 13
if ($env:ENGINE_FACING_POSTFLOP_DEADLINE_SEC) {
  $parsedFacingDeadline = 0
  if ([int]::TryParse([string]$env:ENGINE_FACING_POSTFLOP_DEADLINE_SEC, [ref]$parsedFacingDeadline)) {
    if ($parsedFacingDeadline -ge 3 -and $parsedFacingDeadline -le 120) {
      $engineFacingPostflopDeadlineSec = [int]$parsedFacingDeadline
    }
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
$engineNeuralEnabled = $false
if ($env:ENGINE_NEURAL_ENABLED -and ([string]$env:ENGINE_NEURAL_ENABLED).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) {
  $engineNeuralEnabled = $true
}
$engineNeuralMode = if ($env:ENGINE_NEURAL_MODE) { ([string]$env:ENGINE_NEURAL_MODE).Trim().ToLowerInvariant() } else { "prefer_on_fast_failover" }
if ($engineNeuralMode -notin @("shadow", "prefer", "prefer_on_fast_failover")) {
  $engineNeuralMode = "prefer_on_fast_failover"
}
$engineNeuralTimeoutSec = 2
if ($env:ENGINE_NEURAL_TIMEOUT_SEC) {
  $parsedNeuralTimeout = 0
  if ([int]::TryParse([string]$env:ENGINE_NEURAL_TIMEOUT_SEC, [ref]$parsedNeuralTimeout) -and $parsedNeuralTimeout -ge 1 -and $parsedNeuralTimeout -le 15) {
    $engineNeuralTimeoutSec = [int]$parsedNeuralTimeout
  }
}
$engineNeuralCfrIters = 120
if ($env:ENGINE_NEURAL_CFR_ITERS) {
  $parsedNeuralIters = 0
  if ([int]::TryParse([string]$env:ENGINE_NEURAL_CFR_ITERS, [ref]$parsedNeuralIters) -and $parsedNeuralIters -ge 1) {
    $engineNeuralCfrIters = [int]$parsedNeuralIters
  }
}
$engineNeuralCfrSkipIters = 60
if ($env:ENGINE_NEURAL_CFR_SKIP_ITERS) {
  $parsedNeuralSkip = 0
  if ([int]::TryParse([string]$env:ENGINE_NEURAL_CFR_SKIP_ITERS, [ref]$parsedNeuralSkip) -and $parsedNeuralSkip -ge 0) {
    $engineNeuralCfrSkipIters = [int]$parsedNeuralSkip
  }
}
if ($engineNeuralCfrSkipIters -ge $engineNeuralCfrIters) {
  $engineNeuralCfrSkipIters = [int]([Math]::Max(0, $engineNeuralCfrIters - 1))
}
$engineNeuralPython = if ($env:ENGINE_NEURAL_PYTHON) { ([string]$env:ENGINE_NEURAL_PYTHON).Trim() } else { "" }
if ([string]::IsNullOrWhiteSpace($engineNeuralPython)) {
  $preferredNeuralPython = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
  if (Test-Path $preferredNeuralPython) {
    $engineNeuralPython = $preferredNeuralPython
  }
}
$neuralStatusLabel = if ($engineNeuralEnabled) { "ON/{0}" -f $engineNeuralMode } else { "OFF" }
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
# Temporary operating mode: disable all screen capture/OCR paths by default.
# Set POKERBOT_ENABLE_SCREEN_CAPTURE=1 to re-enable full OCR capture behavior.
$script:screenCaptureEnabled = $false
if ($env:POKERBOT_ENABLE_SCREEN_CAPTURE -and ([string]$env:POKERBOT_ENABLE_SCREEN_CAPTURE).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) {
  $script:screenCaptureEnabled = $true
}
$screenCaptureStatusLabel = if ($script:screenCaptureEnabled) { "enabled" } else { "disabled/manual-only" }
$uiSessionId = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
$uiLogRoot = Join-Path $PSScriptRoot "5_Vision_Extraction\out\ui_session_logs"
$uiLogTextPath = Join-Path $uiLogRoot ("session_{0}.log" -f $uiSessionId)
$uiLogJsonlPath = Join-Path $uiLogRoot ("session_{0}.jsonl" -f $uiSessionId)
$uiLogLatestPath = Join-Path $uiLogRoot "latest_session.json"
$pauseOnNormalExit = $false
if ($env:UI_PAUSE_ON_EXIT -and ([string]$env:UI_PAUSE_ON_EXIT).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) {
  $pauseOnNormalExit = $true
}
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
$engineLastResultSummary = "none"
$advicePrimary = "WAIT"
$adviceSecondary = "No actionable advice yet."
$checkCallButtonToken = "CHECK"
$autoHeroSendInProgress = $false
$raiseAllInButtonToken = "RAISE"
$lastRecommendedCallAmount = 0
$lastRecommendedRaiseAmount = 0
$numSmallBlind = $null
$numBigBlind = $null
$numBuyIn = $null
$numRaiseAmount = $null
$trkRaiseAmount = $null
$lblRaiseAmountTitle = $null
$lblRaiseAmountValue = $null
$btnToggleVillainCards = $null
$cmbVillainMode = $null
$cmbVillainStyle = $null
$lblCurrentPotValue = $null
$lblCurrentChipsValue = $null
$lblCurrentVillainChipsValue = $null
$lblHeroPositionValue = $null
$lblTableStatusValue = $null
$lblVillainCardsValue = $null
$stateOverlay = $null
$stateOverlayPotLabel = $null
$stateOverlayChipsLabel = $null
$stateOverlayPositionLabel = $null
$stateOverlayStatusLabel = $null
$stateOverlayVillainChipsLabel = $null
$stateOverlayVillainLabel = $null
$btnVillainActionMenu = $null
$btnHeroWinsPot = $null
$btnVillainWinsPot = $null
$btnRaise25 = $null
$btnRaise50 = $null
$btnRaise100 = $null
$villainActionMenu = $null
$currentPotAmount = 0
$currentHeroChips = 0
$currentVillainChips = 0
$lastVillainAction = "WAIT"
$lastHeroAction = "WAIT"
$currentFacingBetAmount = 0
$currentHeroStreetCommit = 0
$currentVillainStreetCommit = 0
$heroActedThisRound = $false
$villainActedThisRound = $false
$configuredVillainCount = 0
$activeVillainCount = 0
$heroFolded = $false
$villainFolded = $false
$currentDeckShoe = @()
$preparedNextDeckShoe = @()
$currentBurnPile = @()
$preparedNextBurnPile = @()
$handResolved = $false
$completedHandPrepared = $false
$handCounter = 0
$heroIsSmallBlind = $true
$lastHandSummaryText = ""
$showVillainCards = $false
$villainMode = "Scripted"
$villainStyle = "Tight"
$autoVillainBusy = $false
$streetRaiseCount = 0
$maxRaisesPerStreet = 4
$parsedMaxRaisesPerStreet = 0
if ($env:MAX_RAISES_PER_STREET -and [int]::TryParse([string]$env:MAX_RAISES_PER_STREET, [ref]$parsedMaxRaisesPerStreet)) {
  if ($parsedMaxRaisesPerStreet -ge 1 -and $parsedMaxRaisesPerStreet -le 12) {
    $maxRaisesPerStreet = [int]$parsedMaxRaisesPerStreet
  }
}
$adviceActionPrimary = ""
$adviceActionSecondary = ""
$adviceHasAction = $false
$lastAdviceWeightedRows = @()
$suppressHeroAutoSend = $false
$stateRefreshBusy = $false
$raiseAmountSyncBusy = $false
$heroCards = @{
  hero1 = "??"
  hero2 = "??"
}
$villainCards = @{
  villain1 = "??"
  villain2 = "??"
}
$lastBoardTokens = @()
$lastHeroAutoSendKey = ""
$lastHeroStageKey = ""
$managedOllamaProcess = $null
$managedBridgeProcess = $null
$managedOllamaStartedByUi = $false
$managedBridgeStartedByUi = $false
$autoEnabled = $false
$overlayVisible = $true
$quickSingleSlotHidden = $false
$adviceOverlay = $null
$savedAdviceOverlayLocation = $null
$savedStateOverlayLocation = $null
$adviceOverlayTitleLabel = $null
$adviceOverlayValueLabel = $null
$lblAdviceValue = $null
$txtAdviceDetail = $null
$cardSlotOrder = @("flop1", "flop2", "flop3", "turn", "river")
$playerSlotOrder = @("hero1", "hero2")
$infoSlotOrder = @("pot_txt")
$stateSlotOrder = @("villain_txt")
$actionSlotOrder = @("check_btn", "fold_btn", "call_btn", "bet_btn", "raise_btn", "allin_btn")
$allSlotOrder = @("flop1", "flop2", "flop3", "turn", "river", "hero1", "hero2", "pot_txt", "villain_txt", "check_btn", "fold_btn", "call_btn", "bet_btn", "raise_btn", "allin_btn")
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
  pot_txt = [System.Drawing.Color]::FromArgb(72, 180, 200)
  villain_txt = [System.Drawing.Color]::FromArgb(224, 92, 156)
  check_btn = [System.Drawing.Color]::FromArgb(64, 132, 112)
  fold_btn = [System.Drawing.Color]::FromArgb(255, 86, 86)
  call_btn = [System.Drawing.Color]::FromArgb(70, 180, 255)
  bet_btn = [System.Drawing.Color]::FromArgb(110, 220, 130)
  raise_btn = [System.Drawing.Color]::FromArgb(255, 180, 70)
  allin_btn = [System.Drawing.Color]::FromArgb(180, 58, 58)
}
foreach ($slot in $allSlotOrder) {
  $cardRegions[$slot] = [System.Drawing.Rectangle]::Empty
}
$slotValueSource = @{}
foreach ($slot in $allSlotOrder) {
  $slotValueSource[$slot] = "none"
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

function Get-SlotValueSource {
  param([string]$Slot)
  if ($slotValueSource.ContainsKey($Slot)) {
    return [string]$slotValueSource[$Slot]
  }
  return "none"
}

function Set-SlotValueSource {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$Source
  )
  if ($slotValueSource.ContainsKey($Slot)) {
    $slotValueSource[$Slot] = ([string]$Source).Trim().ToLowerInvariant()
  }
}

function Test-SlotManualAuthority {
  param([string]$Slot)
  return ((Get-SlotValueSource -Slot $Slot) -eq "manual")
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
  $state = Get-CurrentGameStateSnapshot
  $boardCount = $boardNorm.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).Count
  $streetNorm = "flop"
  if ($boardCount -eq 0) {
    $streetNorm = "preflop"
  }
  elseif ($boardCount -ge 5) {
    $streetNorm = "river"
  }
  elseif ($boardCount -eq 4) {
    $streetNorm = "turn"
  }
  return ("street={0}|board={1}|hero={2}|stage={3}|pot={4}|chips={5}|facing={6}|hero_commit={7}|villain_commit={8}|villains={9}/{10}" -f $streetNorm, $boardNorm, $heroNorm, $stageNorm, [int]$state.current_pot, [int]$state.current_hero_chips, [int]$state.facing_bet, [int]$state.hero_street_commit, [int]$state.villain_street_commit, [int]$state.active_villains, [int]$state.configured_villains)
}

function Get-EngineStagePriority {
  param([string]$StageLabel)
  $stage = ([string]$StageLabel).Trim().ToLowerInvariant()
  switch ($stage) {
    "preflop" { return 140 }
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
      quick_tests_hidden = [bool]$script:quickSingleSlotHidden
    }
    $adviceLocation = $script:savedAdviceOverlayLocation
    if ($null -eq $adviceLocation -and $null -ne $script:adviceOverlay -and -not $script:adviceOverlay.IsDisposed) {
      $adviceLocation = $script:adviceOverlay.Location
    }
    if ($null -ne $adviceLocation) {
      $payload["_meta"]["advice_overlay_x"] = [int]$adviceLocation.X
      $payload["_meta"]["advice_overlay_y"] = [int]$adviceLocation.Y
    }
    $stateLocation = $script:savedStateOverlayLocation
    if ($null -eq $stateLocation -and $null -ne $script:stateOverlay -and -not $script:stateOverlay.IsDisposed) {
      $stateLocation = $script:stateOverlay.Location
    }
    if ($null -ne $stateLocation) {
      $payload["_meta"]["state_overlay_x"] = [int]$stateLocation.X
      $payload["_meta"]["state_overlay_y"] = [int]$stateLocation.Y
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
    $meta = $obj._meta
    if ($null -ne $meta) {
      if ($meta.PSObject.Properties.Name -contains "quick_tests_hidden") {
        try {
          $script:quickSingleSlotHidden = [bool]$meta.quick_tests_hidden
        }
        catch {}
      }
      if (($meta.PSObject.Properties.Name -contains "advice_overlay_x") -and ($meta.PSObject.Properties.Name -contains "advice_overlay_y")) {
        try {
          $script:savedAdviceOverlayLocation = New-Object System.Drawing.Point([int]$meta.advice_overlay_x, [int]$meta.advice_overlay_y)
        }
        catch {}
      }
      if (($meta.PSObject.Properties.Name -contains "state_overlay_x") -and ($meta.PSObject.Properties.Name -contains "state_overlay_y")) {
        try {
          $script:savedStateOverlayLocation = New-Object System.Drawing.Point([int]$meta.state_overlay_x, [int]$meta.state_overlay_y)
        }
        catch {}
      }
    }
    $scaleX = 1.0
    $scaleY = 1.0
    if ($roiAutoScale) {
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
  $checkRect = Convert-ToRectangleSafe -Value $cardRegions["check_btn"]
  $callRect = Convert-ToRectangleSafe -Value $cardRegions["call_btn"]
  if ((-not (Test-RegionSelected -Rect $checkRect)) -and (-not (Test-RegionSelected -Rect $callRect))) {
    [void]$missingActions.Add("check_call_btn")
  }
  $foldRect = Convert-ToRectangleSafe -Value $cardRegions["fold_btn"]
  if (-not (Test-RegionSelected -Rect $foldRect)) {
    [void]$missingActions.Add("fold_btn")
  }
  $betRect = Convert-ToRectangleSafe -Value $cardRegions["bet_btn"]
  $raiseRect = Convert-ToRectangleSafe -Value $cardRegions["raise_btn"]
  $allinRect = Convert-ToRectangleSafe -Value $cardRegions["allin_btn"]
  if ((-not (Test-RegionSelected -Rect $betRect)) -and (-not (Test-RegionSelected -Rect $raiseRect)) -and (-not (Test-RegionSelected -Rect $allinRect))) {
    [void]$missingActions.Add("raise_allin_btn")
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

function Get-BoardSlotIndex {
  param([string]$Slot)
  switch (([string]$Slot).Trim().ToLowerInvariant()) {
    "flop1" { return 0 }
    "flop2" { return 1 }
    "flop3" { return 2 }
    "turn" { return 3 }
    "river" { return 4 }
    default { return -1 }
  }
}

function Get-AssignedCardTokenForSlot {
  param([string]$Slot)
  $slotKey = ([string]$Slot).Trim()
  if (-not $slotKey) {
    return ""
  }
  if ($slotKey -in $playerSlotOrder) {
    $token = Normalize-CardToken -Text ([string]$heroCards[$slotKey])
    if (Test-CardTokenStrict -Token $token) {
      return $token
    }
    return ""
  }
  if ($slotKey -in $cardSlotOrder) {
    $idx = Get-BoardSlotIndex -Slot $slotKey
    if ($idx -lt 0) {
      return ""
    }
    if (($lastBoardTokens -is [System.Array]) -and ($idx -lt $lastBoardTokens.Count)) {
      $token = Normalize-CardToken -Text ([string]$lastBoardTokens[$idx])
      if (Test-CardTokenStrict -Token $token) {
        return $token
      }
    }
  }
  return ""
}

function Find-AssignedSlotForToken {
  param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$ExcludeSlot = ""
  )
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    return ""
  }
  $exclude = ([string]$ExcludeSlot).Trim().ToLowerInvariant()
  foreach ($slot in @($playerSlotOrder + $cardSlotOrder)) {
    $slotKey = [string]$slot
    if ($slotKey.Trim().ToLowerInvariant() -eq $exclude) {
      continue
    }
    $assigned = Get-AssignedCardTokenForSlot -Slot $slotKey
    if ($assigned -and $assigned -eq $normalized) {
      return $slotKey
    }
  }
  return ""
}

function Reset-BoardAssignmentState {
  Set-LastBoardTokensWithStreetTransition -Tokens @()
  foreach ($slot in $cardSlotOrder) {
    Set-SlotValueSource -Slot $slot -Source "none"
  }
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

function Get-ValidBoardCardCount {
  param([string[]]$Tokens)
  $count = 0
  foreach ($tk in @($Tokens)) {
    if (Test-CardTokenStrict -Token $tk) {
      $count++
    }
  }
  return [int]$count
}

function Get-AllDeckCardTokens {
  $cards = New-Object System.Collections.Generic.List[string]
  foreach ($rank in @("A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2")) {
    foreach ($suit in @("S", "H", "D", "C")) {
      [void]$cards.Add(("{0}{1}" -f $rank, $suit))
    }
  }
  return @($cards)
}

function Get-BurnPileText {
  if (-not ($script:currentBurnPile -is [System.Array]) -or $script:currentBurnPile.Count -eq 0) {
    return "(none)"
  }
  return (@($script:currentBurnPile) -join " ")
}

function Get-ShuffledDeckTokens {
  $pool = New-Object System.Collections.Generic.List[string]
  foreach ($token in @(Get-AllDeckCardTokens)) {
    [void]$pool.Add([string]$token)
  }
  $shuffled = New-Object System.Collections.Generic.List[string]
  while ($pool.Count -gt 0) {
    $idx = Get-Random -Minimum 0 -Maximum $pool.Count
    [void]$shuffled.Add([string]$pool[$idx])
    $pool.RemoveAt($idx)
  }
  return @($shuffled)
}

function Prepare-NextHandBackendState {
  $script:preparedNextDeckShoe = @(Get-ShuffledDeckTokens)
  $script:preparedNextBurnPile = @()
  $script:completedHandPrepared = $true
}

function Start-ActiveDeckFromPreparedOrFresh {
  if (($script:preparedNextDeckShoe -is [System.Array]) -and $script:preparedNextDeckShoe.Count -gt 0) {
    $script:currentDeckShoe = @($script:preparedNextDeckShoe)
  }
  else {
    $script:currentDeckShoe = @(Get-ShuffledDeckTokens)
  }
  if (($script:preparedNextBurnPile -is [System.Array]) -and $script:preparedNextBurnPile.Count -gt 0) {
    $script:currentBurnPile = @($script:preparedNextBurnPile)
  }
  else {
    $script:currentBurnPile = @()
  }
  $script:preparedNextDeckShoe = @()
  $script:preparedNextBurnPile = @()
  $script:completedHandPrepared = $false
}

function Draw-NextDeckCard {
  if (-not ($script:currentDeckShoe -is [System.Array]) -or $script:currentDeckShoe.Count -le 0) {
    return ""
  }
  $card = [string]$script:currentDeckShoe[0]
  if ($script:currentDeckShoe.Count -gt 1) {
    $script:currentDeckShoe = @($script:currentDeckShoe[1..($script:currentDeckShoe.Count - 1)])
  }
  else {
    $script:currentDeckShoe = @()
  }
  return $card
}

function Burn-NextDeckCard {
  $burned = Draw-NextDeckCard
  if (Test-CardTokenStrict -Token $burned) {
    $script:currentBurnPile = @(@($script:currentBurnPile) + @($burned))
    return $burned
  }
  return ""
}

function Get-VisibleAssignedCardTokens {
  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($slot in @($playerSlotOrder + $cardSlotOrder)) {
    $token = Get-AssignedCardTokenForSlot -Slot ([string]$slot)
    if (Test-CardTokenStrict -Token $token) {
      [void]$tokens.Add(([string]$token).Trim().ToUpperInvariant())
    }
  }
  foreach ($slot in @("villain1", "villain2")) {
    $token = Normalize-CardToken -Text ([string]$script:villainCards[$slot])
    if (Test-CardTokenStrict -Token $token) {
      [void]$tokens.Add(([string]$token).Trim().ToUpperInvariant())
    }
  }
  foreach ($token in @($script:currentBurnPile)) {
    $normalized = Normalize-CardToken -Text ([string]$token)
    if (Test-CardTokenStrict -Token $normalized) {
      [void]$tokens.Add(([string]$normalized).Trim().ToUpperInvariant())
    }
  }
  return @($tokens)
}

function Rebuild-DeckShoeState {
  $blocked = @{}
  foreach ($token in @(Get-VisibleAssignedCardTokens)) {
    $key = ([string]$token).Trim().ToUpperInvariant()
    if ($key) {
      $blocked[$key] = $true
    }
  }
  $orderedPool = New-Object System.Collections.Generic.List[string]
  foreach ($token in @($script:currentDeckShoe + $script:preparedNextDeckShoe + (Get-AllDeckCardTokens))) {
    $key = ([string]$token).Trim().ToUpperInvariant()
    if ($key -and (-not $orderedPool.Contains($key))) {
      [void]$orderedPool.Add($key)
    }
  }
  $available = New-Object System.Collections.Generic.List[string]
  foreach ($key in @($orderedPool)) {
    if (-not $blocked.ContainsKey($key)) {
      [void]$available.Add([string]$key)
    }
  }
  $script:currentDeckShoe = @($available)
}

function Reset-HiddenVillainState {
  param(
    [int]$StartingChips = 0
  )
  $defaults = Get-DefaultTableStateFromStakes
  $useExplicitValue = $PSBoundParameters.ContainsKey("StartingChips")
  $baseChips = if ($useExplicitValue) { [int]$StartingChips } else { [int]$defaults.hero_chips }
  $script:currentVillainChips = [int]$baseChips
  $script:villainCards["villain1"] = "??"
  $script:villainCards["villain2"] = "??"
  $script:lastVillainAction = "WAIT"
  $script:heroFolded = $false
  $script:villainFolded = $false
}

function Set-LastBoardTokensWithStreetTransition {
  param([string[]]$Tokens)

  $oldCount = Get-ValidBoardCardCount -Tokens @($script:lastBoardTokens)
  $newTokens = @($Tokens)
  $newCount = Get-ValidBoardCardCount -Tokens $newTokens
  if (($newCount -in @(3, 4, 5)) -and ($newCount -gt $oldCount)) {
    Reset-StreetActionState
  }
  $script:lastBoardTokens = @($newTokens)
  Rebuild-DeckShoeState
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
  Set-LastBoardTokensWithStreetTransition -Tokens @($arr)
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
  if (-not [bool]$script:screenCaptureEnabled) {
    throw "Capture-RegionImage blocked: screen capture/OCR is disabled (manual mode)."
  }
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

function Get-StakeSettings {
  $smallBlind = 1
  $bigBlind = 2
  $buyIn = 100

  if ($null -ne $script:numSmallBlind) {
    $smallBlind = [int][decimal]$script:numSmallBlind.Value
  }
  if ($null -ne $script:numBigBlind) {
    $bigBlind = [int][decimal]$script:numBigBlind.Value
  }
  if ($null -ne $script:numBuyIn) {
    $buyIn = [int][decimal]$script:numBuyIn.Value
  }

  if ($smallBlind -lt 1) { $smallBlind = 1 }
  if ($bigBlind -lt $smallBlind) { $bigBlind = $smallBlind }
  if ($buyIn -lt $bigBlind) { $buyIn = $bigBlind }

  return [pscustomobject]@{
    small_blind = [int]$smallBlind
    big_blind = [int]$bigBlind
    buy_in = [int]$buyIn
  }
}

function Get-DefaultTableStateFromStakes {
  $stakes = Get-StakeSettings
  $defaultPot = [int]($stakes.small_blind + $stakes.big_blind)
  $buyIn = [int]$stakes.buy_in

  return [pscustomobject]@{
    starting_pot = [int]$defaultPot
    hero_chips = [int]$buyIn
  }
}

function Get-CurrentGameStateSnapshot {
  return [pscustomobject]@{
    current_pot = [int]$script:currentPotAmount
    current_hero_chips = [int]$script:currentHeroChips
    current_villain_chips = [int]$script:currentVillainChips
    facing_bet = [int]$script:currentFacingBetAmount
    hero_street_commit = [int]$script:currentHeroStreetCommit
    villain_street_commit = [int]$script:currentVillainStreetCommit
    configured_villains = [int]$script:configuredVillainCount
    active_villains = [int]$script:activeVillainCount
    hero_folded = [bool]$script:heroFolded
    villain_folded = [bool]$script:villainFolded
    street_raise_count = [int]$script:streetRaiseCount
  }
}

function Get-VillainCardsText {
  return ("{0} {1}" -f [string]$script:villainCards["villain1"], [string]$script:villainCards["villain2"])
}

function Get-VisibleVillainCardsText {
  if (-not $script:showVillainCards) {
    return "Villain Cards: Hidden"
  }
  return ("Villain Cards: {0}" -f (Get-VillainCardsText))
}

function Get-VillainRoiOverlayText {
  $stackValue = [int]([Math]::Max(0, $script:currentVillainChips))
  $streetInvest = [int]([Math]::Max(0, $script:currentVillainStreetCommit))
  $actionText = ([string]$script:lastVillainAction).Trim().ToUpperInvariant()
  if (-not $actionText) {
    $actionText = "WAIT"
  }
  return @(
    ("V {0}" -f $stackValue)
    ("IN {0}" -f $streetInvest)
    $actionText
  ) -join "`n"
}

function Get-VillainFacingBetAmount {
  return [int]([Math]::Max(0, ([int]$script:currentHeroStreetCommit - [int]$script:currentVillainStreetCommit)))
}

function Get-CurrentStreetName {
  $boardCount = Get-ValidBoardCardCount -Tokens @($lastBoardTokens)
  switch ($boardCount) {
    0 { return "preflop" }
    3 { return "flop" }
    4 { return "turn" }
    5 { return "river" }
    default { return "incomplete" }
  }
}

function Test-IsVillainTurn {
  if ($script:handResolved -or $script:heroFolded -or $script:villainFolded) {
    return $false
  }
  if ([int]$script:currentVillainChips -le 0) {
    return $false
  }
  if ([int]$script:activeVillainCount -le 0) {
    return $false
  }

  $villainFacingGap = Get-VillainFacingBetAmount
  if ($villainFacingGap -gt 0) {
    return (-not $script:villainActedThisRound)
  }
  if ([int]$script:currentFacingBetAmount -gt 0) {
    return $false
  }

  $street = Get-CurrentStreetName
  $villainActsFirst = $false
  if ($street -eq "preflop") {
    $villainActsFirst = (-not [bool]$script:heroIsSmallBlind)
  }
  elseif ($street -in @("flop", "turn", "river")) {
    $villainActsFirst = [bool]$script:heroIsSmallBlind
  }

  if (-not $script:heroActedThisRound -and -not $script:villainActedThisRound) {
    return $villainActsFirst
  }
  if ($script:heroActedThisRound -and (-not $script:villainActedThisRound)) {
    return $true
  }
  return $false
}

function Test-IsHeroTurn {
  if ($script:handResolved -or $script:heroFolded -or $script:villainFolded) {
    return $false
  }
  if ([int]$script:currentHeroChips -le 0) {
    return $false
  }
  if ([int]$script:activeVillainCount -le 0) {
    return $true
  }
  return (-not (Test-IsVillainTurn))
}

function Set-VillainMode {
  param([string]$Mode)
  $normalized = ([string]$Mode).Trim()
  if ($normalized -notin @("Manual", "Scripted", "Engine Random")) {
    $normalized = "Manual"
  }
  $script:villainMode = $normalized
  if ($null -ne $script:cmbVillainMode -and ([string]$script:cmbVillainMode.SelectedItem -ne $normalized)) {
    $script:cmbVillainMode.SelectedItem = $normalized
  }
  if ($null -ne $script:btnVillainActionMenu) {
    $script:btnVillainActionMenu.Enabled = ($normalized -eq "Manual")
    $script:btnVillainActionMenu.Text = $(if ($normalized -eq "Manual") { "Villain Action" } else { ("Villain: {0} ({1})" -f $normalized, [string]$script:villainStyle) })
  }
}

function Set-VillainStyle {
  param([string]$Style)
  $normalized = ([string]$Style).Trim()
  if ($normalized -notin @("Tight", "Aggressive")) {
    $normalized = "Tight"
  }
  $script:villainStyle = $normalized
  if ($null -ne $script:cmbVillainStyle -and ([string]$script:cmbVillainStyle.SelectedItem -ne $normalized)) {
    $script:cmbVillainStyle.SelectedItem = $normalized
  }
  if ($null -ne $script:btnVillainActionMenu -and [string]$script:villainMode -ne "Manual") {
    $script:btnVillainActionMenu.Text = ("Villain: {0} ({1})" -f [string]$script:villainMode, [string]$script:villainStyle)
  }
}

function Get-RecommendedVillainRaiseAmount {
  $stakes = Get-StakeSettings
  $facingGap = Get-VillainFacingBetAmount
  if ($facingGap -gt 0) {
    return [int]([Math]::Max(($facingGap + $stakes.big_blind), $stakes.big_blind))
  }
  return [int]([Math]::Max(($stakes.big_blind * 3), $stakes.big_blind))
}

function Get-VillainStyleWeightMultiplier {
  param([Parameter(Mandatory = $true)][string]$NormalizedToken)
  $token = ([string]$NormalizedToken).Trim().ToUpperInvariant()
  $style = ([string]$script:villainStyle).Trim().ToLowerInvariant()
  if ($style -eq "aggressive") {
    switch ($token) {
      "FOLD" { return 0.35 }
      "CHECK" { return 0.60 }
      "CALL" { return 0.95 }
      "RAISE" { return 1.80 }
      "ALL IN" { return 1.50 }
      default { return 1.0 }
    }
  }
  switch ($token) {
    "FOLD" { return 1.60 }
    "CHECK" { return 1.35 }
    "CALL" { return 1.10 }
    "RAISE" { return 0.55 }
    "ALL IN" { return 0.45 }
    default { return 1.0 }
  }
}

function Get-VillainLegalActionTokens {
  $tokens = New-Object System.Collections.Generic.List[string]
  $villainChips = [int]([Math]::Max(0, $script:currentVillainChips))
  $heroChips = [int]([Math]::Max(0, $script:currentHeroChips))
  $raiseCapReached = Get-IsStreetRaiseCapReached
  if ($script:handResolved -or $script:heroFolded -or $script:villainFolded -or $villainChips -le 0) {
    return @()
  }

  $facingGap = Get-VillainFacingBetAmount
  $heroAllIn = ($heroChips -le 0)
  if ($facingGap -gt 0) {
    [void]$tokens.Add("FOLD")
    if ($facingGap -ge $villainChips) {
      [void]$tokens.Add("ALL IN")
    }
    else {
      [void]$tokens.Add("CALL")
      if ((-not $heroAllIn) -and (-not $raiseCapReached)) {
        $raiseBase = [int](Get-RecommendedVillainRaiseAmount)
        if ($raiseBase -ge $villainChips) {
          [void]$tokens.Add("ALL IN")
        }
        else {
          [void]$tokens.Add("RAISE")
        }
      }
    }
    return @($tokens | Select-Object -Unique)
  }

  if ($heroAllIn) {
    return @()
  }

  [void]$tokens.Add("CHECK")
  if (-not $raiseCapReached) {
    $raiseBase = [int](Get-RecommendedVillainRaiseAmount)
    if ($raiseBase -ge $villainChips) {
      [void]$tokens.Add("ALL IN")
    }
    elseif ($villainChips -gt 0) {
      [void]$tokens.Add("RAISE")
    }
  }
  return @($tokens | Select-Object -Unique)
}

function Get-WeightedRandomActionToken {
  param(
    [Parameter(Mandatory = $true)]$WeightedRows,
    [Parameter(Mandatory = $true)][string[]]$LegalTokens
  )

  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($row in @($WeightedRows)) {
    if ($null -eq $row) { continue }
    $rowToken = ([string]$row.token).Trim().ToLowerInvariant()
    if (-not $rowToken) { continue }
    $weight = 0.0
    try { $weight = [double]$row.weight } catch { $weight = 0.0 }
    if ($weight -le 0.0) { continue }

    $normalizedToken = ""
    if ($rowToken -eq "fold") {
      $normalizedToken = "FOLD"
    }
    elseif ($rowToken -eq "check") {
      $normalizedToken = "CHECK"
    }
    elseif ($rowToken -eq "call" -or $rowToken -like "call:*") {
      $normalizedToken = $(if ($LegalTokens -contains "CALL") { "CALL" } elseif ($LegalTokens -contains "ALL IN") { "ALL IN" } else { "" })
    }
    elseif ($rowToken -eq "bet" -or $rowToken -eq "raise" -or $rowToken -like "bet:*" -or $rowToken -like "raise:*") {
      $amount = [int](Get-AmountFromActionToken -Token $rowToken)
      if ($amount -gt 0 -and $amount -ge [int]$script:currentVillainChips -and ($LegalTokens -contains "ALL IN")) {
        $normalizedToken = "ALL IN"
      }
      elseif ($LegalTokens -contains "RAISE") {
        $normalizedToken = "RAISE"
      }
      elseif ($LegalTokens -contains "ALL IN") {
        $normalizedToken = "ALL IN"
      }
    }
    if (-not $normalizedToken) { continue }
    if (-not ($LegalTokens -contains $normalizedToken)) { continue }
    $weight = [double]$weight * [double](Get-VillainStyleWeightMultiplier -NormalizedToken $normalizedToken)
    if ($weight -le 0.0) { continue }
    [void]$candidates.Add([pscustomobject]@{
      token = $normalizedToken
      weight = [double]$weight
    })
  }
  if ($candidates.Count -eq 0) {
    return ""
  }

  $totalWeight = 0.0
  foreach ($candidate in $candidates) {
    $totalWeight += [double]$candidate.weight
  }
  if ($totalWeight -le 0.0) {
    return [string]$candidates[0].token
  }

  $roll = Get-Random -Minimum 0.0 -Maximum $totalWeight
  $cursor = 0.0
  foreach ($candidate in $candidates) {
    $cursor += [double]$candidate.weight
    if ($roll -le $cursor) {
      return [string]$candidate.token
    }
  }
  return [string]$candidates[$candidates.Count - 1].token
}

function Get-ScriptedVillainActionToken {
  $legal = @(Get-VillainLegalActionTokens)
  if ($legal.Count -eq 0) {
    return ""
  }

  $style = ([string]$script:villainStyle).Trim().ToLowerInvariant()
  $facingGap = Get-VillainFacingBetAmount
  if ($facingGap -le 0) {
    if ($style -eq "aggressive") {
      if ($legal -contains "RAISE") { return "RAISE" }
      if ($legal -contains "ALL IN") { return "ALL IN" }
      if ($legal -contains "CHECK") { return "CHECK" }
    }
    else {
      if ($legal -contains "CHECK") { return "CHECK" }
      if ($legal -contains "RAISE") { return "RAISE" }
      if ($legal -contains "ALL IN") { return "ALL IN" }
    }
    return [string]$legal[0]
  }

  $stakes = Get-StakeSettings
  $villainCardsNow = @()
  foreach ($slot in @("villain1", "villain2")) {
    $token = Normalize-CardToken -Text ([string]$script:villainCards[$slot])
    if (Test-CardTokenStrict -Token $token) {
      $villainCardsNow += $token
    }
  }
  $preflopRows = if ($villainCardsNow.Count -eq 2) { @(Build-PreflopHeuristicRootActions -HeroCards $villainCardsNow) } else { @() }
  $topPreflopToken = ""
  if ($preflopRows.Count -gt 0) {
    $topRow = @($preflopRows | Sort-Object -Property avg_frequency -Descending)[0]
    if ($null -ne $topRow) {
      $topPreflopToken = [string](Convert-ActionSummaryRowToToken -Row $topRow)
    }
  }

  if ($style -eq "aggressive") {
    $jamThreshold = [int]([Math]::Ceiling([double][Math]::Max(1, $script:currentVillainChips) * 0.60))
    if (($legal -contains "ALL IN") -and ($facingGap -ge $jamThreshold)) {
      return "ALL IN"
    }
    if (($legal -contains "RAISE") -and (-not (Get-IsStreetRaiseCapReached))) {
      $potNow = [int]([Math]::Max(1, $script:currentPotAmount))
      $gapRatio = [double]$facingGap / [double]$potNow
      $raiseThreshold = 65
      if ($gapRatio -ge 0.50) { $raiseThreshold = 45 }
      if ($gapRatio -ge 1.00) { $raiseThreshold = 25 }
      $roll = [int](Get-Random -Minimum 0 -Maximum 100)
      if (($topPreflopToken -like "raise*") -and ($roll -lt [int]([Math]::Min(92, ($raiseThreshold + 15))))) {
        return "RAISE"
      }
      if ($roll -lt $raiseThreshold) {
        return "RAISE"
      }
    }
    if ($legal -contains "CALL") { return "CALL" }
    if ($legal -contains "ALL IN") { return "ALL IN" }
    if ($legal -contains "FOLD") { return "FOLD" }
  }
  else {
    if (($topPreflopToken -eq "fold") -and ($facingGap -gt [int]$stakes.big_blind) -and ($legal -contains "FOLD")) {
      return "FOLD"
    }
    if (($topPreflopToken -like "raise*") -and ($legal -contains "RAISE") -and ($facingGap -le ([int]$stakes.big_blind * 4))) {
      return "RAISE"
    }
    if (($facingGap -ge [int]([Math]::Max([Math]::Ceiling([double]$script:currentPotAmount * 0.60), $stakes.big_blind * 3))) -and ($legal -contains "FOLD")) {
      return "FOLD"
    }
    if ($legal -contains "CALL") { return "CALL" }
    if ($legal -contains "ALL IN") { return "ALL IN" }
    if ($legal -contains "FOLD") { return "FOLD" }
  }
  return [string]$legal[0]
}

function Get-AutomaticVillainActionToken {
  $mode = [string]$script:villainMode
  if ($mode -eq "Engine Random" -and (Get-ValidBoardCardCount) -ge 3) {
    $legal = @(Get-VillainLegalActionTokens)
    $picked = Get-WeightedRandomActionToken -WeightedRows @($script:lastAdviceWeightedRows) -LegalTokens $legal
    if ($picked) {
      return $picked
    }
  }
  return (Get-ScriptedVillainActionToken)
}

function Try-RunAutomaticVillainTurn {
  if ($script:autoVillainBusy) {
    return $false
  }
  if ([string]$script:villainMode -eq "Manual") {
    return $false
  }
  if (-not (Test-IsVillainTurn)) {
    return $false
  }

  $token = [string](Get-AutomaticVillainActionToken)
  if (-not $token) {
    return $false
  }

  $script:autoVillainBusy = $true
  try {
    $amountOverride = -1
    if ($token -eq "RAISE") {
      $amountOverride = [int](Get-RecommendedVillainRaiseAmount)
    }
    Write-Log ("Auto villain ({0}/{1}) selected: {2}" -f [string]$script:villainMode, [string]$script:villainStyle, $token) -Type "auto_villain_action" -Data @{
      mode = [string]$script:villainMode
      style = [string]$script:villainStyle
      action = $token
      current_pot = [int]$script:currentPotAmount
      current_hero_chips = [int]$script:currentHeroChips
      current_villain_chips = [int]$script:currentVillainChips
      facing_bet = [int]$script:currentFacingBetAmount
      villain_facing_bet = [int](Get-VillainFacingBetAmount)
    }
    Invoke-VillainActionSelection -ActionToken $token -AmountOverride $amountOverride -AutoMode
    return $true
  }
  finally {
    $script:autoVillainBusy = $false
  }
}

function Set-VillainCardsVisibility {
  param([bool]$Visible)
  $script:showVillainCards = [bool]$Visible
  if ($null -ne $script:btnToggleVillainCards) {
    $script:btnToggleVillainCards.Text = $(if ($script:showVillainCards) { "Hide Villain Cards" } else { "Show Villain Cards" })
  }
  Update-TableStateDisplay
}

function Toggle-VillainCardsVisibility {
  Set-VillainCardsVisibility -Visible:(-not [bool]$script:showVillainCards)
}

function Reset-StreetActionState {
  $script:currentFacingBetAmount = 0
  $script:currentHeroStreetCommit = 0
  $script:currentVillainStreetCommit = 0
  $script:heroActedThisRound = $false
  $script:villainActedThisRound = $false
  $script:streetRaiseCount = 0
  Update-CheckCallButtonModeFromState
  Update-TableStateDisplay
}

function Get-IsStreetRaiseCapReached {
  $cap = [int]([Math]::Max(1, $script:maxRaisesPerStreet))
  return ([int]$script:streetRaiseCount -ge $cap)
}

function Register-StreetRaiseAction {
  param(
    [Parameter(Mandatory = $true)][string]$Actor,
    [Parameter(Mandatory = $true)][string]$Action,
    [int]$Amount = 0
  )

  $token = ([string]$Action).Trim().ToUpperInvariant()
  if ($token -notin @("RAISE", "ALL IN")) {
    return
  }
  if ([int]$Amount -le 0) {
    return
  }
  $script:streetRaiseCount = [int]$script:streetRaiseCount + 1
  if (Get-IsStreetRaiseCapReached) {
    Write-Log ("Street raise cap reached ({0}); further re-raises disabled until next street." -f [int]$script:maxRaisesPerStreet) -Type "street_raise_cap" -Data @{
      actor = [string]$Actor
      action = $token
      amount = [int]$Amount
      street = (Get-CurrentStreetName)
      street_raise_count = [int]$script:streetRaiseCount
      max_raises_per_street = [int]$script:maxRaisesPerStreet
    }
  }
}

function Clear-FacingBetAmount {
  $script:currentFacingBetAmount = 0
  Update-CheckCallButtonModeFromState
}

function Set-FacingBetAmount {
  param([int]$Amount)
  $script:currentFacingBetAmount = [int]([Math]::Max(0, $Amount))
  Update-CheckCallButtonModeFromState
}

function Apply-HeroCommitmentToPot {
  param(
    [Parameter(Mandatory = $true)][int]$Amount,
    [switch]$ClearFacingBet
  )

  $commit = [int]([Math]::Max(0, $Amount))
  if ($commit -le 0) {
    if ($ClearFacingBet) {
      Clear-FacingBetAmount
    }
    return 0
  }
  if ($commit -gt [int]$script:currentHeroChips) {
    $commit = [int]$script:currentHeroChips
  }
  $script:currentHeroChips = [Math]::Max(0, ([int]$script:currentHeroChips - $commit))
  $script:currentPotAmount = [Math]::Max(0, ([int]$script:currentPotAmount + $commit))
  $script:currentHeroStreetCommit = [int]$script:currentHeroStreetCommit + $commit
  if ([int]$script:currentHeroStreetCommit -gt [int]$script:currentVillainStreetCommit) {
    $script:villainActedThisRound = $false
  }
  if ($ClearFacingBet) {
    Clear-FacingBetAmount
  }
  Update-TableStateDisplay
  return [int]$commit
}

function Apply-VillainCommitmentToPot {
  param(
    [Parameter(Mandatory = $true)][int]$Amount,
    [switch]$SetAsFacingBet
  )

  $commit = [int]([Math]::Max(0, $Amount))
  if ($commit -le 0) {
    return 0
  }
  if ($commit -gt [int]$script:currentVillainChips) {
    $commit = [int]$script:currentVillainChips
  }
  $script:currentVillainChips = [Math]::Max(0, ([int]$script:currentVillainChips - $commit))
  $script:currentPotAmount = [Math]::Max(0, ([int]$script:currentPotAmount + $commit))
  $script:currentVillainStreetCommit = [int]$script:currentVillainStreetCommit + $commit
  if ([int]$script:currentVillainStreetCommit -gt [int]$script:currentHeroStreetCommit) {
    $script:heroActedThisRound = $false
  }
  if ($SetAsFacingBet) {
    $callGap = [int]([Math]::Max(0, ([int]$script:currentVillainStreetCommit - [int]$script:currentHeroStreetCommit)))
    Set-FacingBetAmount -Amount $callGap
  }
  Update-TableStateDisplay
  return [int]$commit
}

function Update-TableStateDisplay {
  $potText = ("Pot: {0}" -f [int]$script:currentPotAmount)
  $chipsText = ("Hero Chips: {0}" -f [int]$script:currentHeroChips)
  $villainChipsText = ("Villain Chips: {0}" -f [int]$script:currentVillainChips)
  $positionText = Get-HeroPositionStatusText
  $statusText = Get-TableStatusText
  $villainText = Get-VisibleVillainCardsText
  if ($null -ne $script:lblCurrentPotValue) {
    $script:lblCurrentPotValue.Text = $potText
  }
  if ($null -ne $script:lblCurrentChipsValue) {
    $script:lblCurrentChipsValue.Text = $chipsText
  }
  if ($null -ne $script:lblCurrentVillainChipsValue) {
    $script:lblCurrentVillainChipsValue.Text = $villainChipsText
  }
  if ($null -ne $script:lblHeroPositionValue) {
    $script:lblHeroPositionValue.Text = $positionText
  }
  if ($null -ne $script:lblTableStatusValue) {
    $script:lblTableStatusValue.Text = $statusText
  }
  if ($null -ne $script:lblVillainCardsValue) {
    $script:lblVillainCardsValue.Text = $villainText
  }
  if ($null -ne $script:stateOverlayPotLabel) {
    $script:stateOverlayPotLabel.Text = $potText
  }
  if ($null -ne $script:stateOverlayChipsLabel) {
    $script:stateOverlayChipsLabel.Text = $chipsText
  }
  if ($null -ne $script:stateOverlayPositionLabel) {
    $script:stateOverlayPositionLabel.Text = $positionText
  }
  if ($null -ne $script:stateOverlayStatusLabel) {
    $script:stateOverlayStatusLabel.Text = $statusText
  }
  if ($null -ne $script:stateOverlayVillainChipsLabel) {
    $script:stateOverlayVillainChipsLabel.Text = $villainChipsText
  }
  if ($null -ne $script:stateOverlayVillainLabel) {
    $script:stateOverlayVillainLabel.Text = $villainText
  }
  if ($overlayForms.ContainsKey("pot_txt")) {
    try {
      $overlay = $overlayForms["pot_txt"]
      if ($null -ne $overlay -and -not $overlay.IsDisposed) {
        $overlay.Invalidate()
      }
    }
    catch {}
  }
  if ($overlayForms.ContainsKey("villain_txt")) {
    try {
      $overlay = $overlayForms["villain_txt"]
      if ($null -ne $overlay -and -not $overlay.IsDisposed) {
        $overlay.Invalidate()
      }
    }
    catch {}
  }
  if (Get-Command Update-VillainActionControlState -ErrorAction SilentlyContinue) {
    Update-VillainActionControlState
  }
}

function Get-HeroPositionStatusText {
  if ([int]$script:activeVillainCount -le 1) {
    if ([bool]$script:heroIsSmallBlind) {
      return "SB / BTN"
    }
    return "BB"
  }
  if ([bool]$script:heroIsSmallBlind) {
    return "SB"
  }
  return "OFF BTN"
}

function Get-TableStatusText {
  if ($script:handResolved) {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:lastHandSummaryText)) {
      return ("STATUS: {0}" -f [string]$script:lastHandSummaryText)
    }
    return "STATUS: HAND COMPLETE"
  }
  if ($script:heroFolded) {
    return "STATUS: HERO FOLDED"
  }
  if ($script:villainFolded) {
    return "STATUS: VILLAIN FOLDED"
  }

  $heroFacing = [int]([Math]::Max(0, $script:currentFacingBetAmount))
  $villainFacing = [int](Get-VillainFacingBetAmount)
  $street = Get-CurrentStreetName
  $stakes = Get-StakeSettings
  $isBlindPostingState = ($street -eq "preflop") -and `
    (-not [bool]$script:heroActedThisRound) -and `
    (-not [bool]$script:villainActedThisRound) -and `
    ([int]$script:currentHeroStreetCommit -eq [int]$stakes.small_blind) -and `
    ([int]$script:currentVillainStreetCommit -eq [int]$stakes.big_blind)
  if (Test-IsHeroTurn) {
    if ($heroFacing -gt 0) {
      $villainTotalCommit = [int]([Math]::Max(0, $script:currentVillainStreetCommit))
      if ($isBlindPostingState) {
        return ("STATUS: PRE-FLOP (SB posted). TO CALL {0} (villain total {1})." -f $heroFacing, $villainTotalCommit)
      }
      return ("STATUS: TO CALL {0} (villain total {1})" -f $heroFacing, $villainTotalCommit)
    }
    return "STATUS: YOUR TURN"
  }
  if (Test-IsVillainTurn) {
    if ($villainFacing -gt 0) {
      return ("STATUS: VILLAIN TO CALL {0}" -f $villainFacing)
    }
    return "STATUS: VILLAIN TO ACT"
  }
  return "STATUS: WAIT"
}

function Reset-TableStateToCurrentStakes {
  $defaults = Get-DefaultTableStateFromStakes
  $script:currentPotAmount = [int]$defaults.starting_pot
  $script:currentHeroChips = [int]$defaults.hero_chips
  Reset-StreetActionState
  Reset-HiddenVillainState -StartingChips ([int]$script:currentHeroChips)
  Rebuild-DeckShoeState
  Update-TableStateDisplay
}

function Set-HeroCardSlotValue {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Source = "auto"
  )
  if (-not ($Slot -in $playerSlotOrder)) {
    return
  }
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    return
  }
  $heroCards[$Slot] = $normalized
  Set-SlotValueSource -Slot $Slot -Source $Source
}

function Set-VillainCardSlotValue {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  if (-not ($Slot -in @("villain1", "villain2"))) {
    return
  }
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    return
  }
  $script:villainCards[$Slot] = $normalized
}

function Set-BoardCardSlotValue {
  param(
    [Parameter(Mandatory = $true)][string]$Slot,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Source = "auto"
  )
  if (-not ($Slot -in $cardSlotOrder)) {
    return
  }
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    return
  }
  Update-LastBoardTokenFromSlot -Slot $Slot -Token $normalized
  Set-SlotValueSource -Slot $Slot -Source $Source
}

function Start-PostBlindRoundState {
  $stakes = Get-StakeSettings
  Reset-StreetActionState
  $script:currentPotAmount = 0
  $script:heroFolded = $false
  $script:villainFolded = $false
  $script:lastHeroAction = "WAIT"
  $script:lastVillainAction = "WAIT"
  if ($script:heroIsSmallBlind) {
    [void](Apply-HeroCommitmentToPot -Amount ([int]$stakes.small_blind))
    [void](Apply-VillainCommitmentToPot -Amount ([int]$stakes.big_blind))
    Set-FacingBetAmount -Amount ([int]([Math]::Max(0, $script:currentVillainStreetCommit - $script:currentHeroStreetCommit)))
  }
  else {
    [void](Apply-VillainCommitmentToPot -Amount ([int]$stakes.small_blind))
    [void](Apply-HeroCommitmentToPot -Amount ([int]$stakes.big_blind))
    Clear-FacingBetAmount
  }
  $script:heroActedThisRound = $false
  $script:villainActedThisRound = $false
  Update-CheckCallButtonModeFromState
}

function Deal-InitialHoleCardsForCurrentHand {
  $dealOrder = if ($script:heroIsSmallBlind) {
    @("hero1", "villain1", "hero2", "villain2")
  }
  else {
    @("villain1", "hero1", "villain2", "hero2")
  }
  foreach ($slot in @($dealOrder)) {
    $card = Draw-NextDeckCard
    if (-not (Test-CardTokenStrict -Token $card)) {
      throw "Deck exhausted while dealing hole cards."
    }
    if ($slot -in $playerSlotOrder) {
      Set-HeroCardSlotValue -Slot $slot -Token $card -Source "auto"
    }
    else {
      Set-VillainCardSlotValue -Slot $slot -Token $card
    }
    Write-Log ("Dealt {0} to {1}." -f $card, $slot) -Type "deal_card" -Data @{
      slot = $slot
      card = $card
    }
  }
  Rebuild-DeckShoeState
}

function Deal-NextStreetCards {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("flop", "turn", "river")][string]$Street
  )
  $burned = Burn-NextDeckCard
  if ($burned) {
    Write-Log ("Burned {0} before {1}." -f $burned, $Street) -Type "burn_card" -Data @{
      card = $burned
      street = $Street
    }
  }
  switch ($Street) {
    "flop" {
      foreach ($slot in @("flop1", "flop2", "flop3")) {
        $card = Draw-NextDeckCard
        if (-not (Test-CardTokenStrict -Token $card)) {
          throw "Deck exhausted while dealing flop."
        }
        Set-BoardCardSlotValue -Slot $slot -Token $card -Source "auto"
        Write-Log ("Dealt {0} to {1}." -f $card, $slot) -Type "deal_board" -Data @{
          slot = $slot
          card = $card
          street = "flop"
        }
      }
    }
    "turn" {
      $card = Draw-NextDeckCard
      if (-not (Test-CardTokenStrict -Token $card)) {
        throw "Deck exhausted while dealing turn."
      }
      Set-BoardCardSlotValue -Slot "turn" -Token $card -Source "auto"
      Write-Log ("Dealt {0} to turn." -f $card) -Type "deal_board" -Data @{
        slot = "turn"
        card = $card
        street = "turn"
      }
    }
    "river" {
      $card = Draw-NextDeckCard
      if (-not (Test-CardTokenStrict -Token $card)) {
        throw "Deck exhausted while dealing river."
      }
      Set-BoardCardSlotValue -Slot "river" -Token $card -Source "auto"
      Write-Log ("Dealt {0} to river." -f $card) -Type "deal_board" -Data @{
        slot = "river"
        card = $card
        street = "river"
      }
    }
  }
  Rebuild-DeckShoeState
  Refresh-RoiOverlays
}

function Get-CardRankInt {
  param([Parameter(Mandatory = $true)][string]$Token)
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    return -1
  }
  switch ($normalized.Substring(0,1)) {
    "2" { return 2 }
    "3" { return 3 }
    "4" { return 4 }
    "5" { return 5 }
    "6" { return 6 }
    "7" { return 7 }
    "8" { return 8 }
    "9" { return 9 }
    "T" { return 10 }
    "J" { return 11 }
    "Q" { return 12 }
    "K" { return 13 }
    "A" { return 14 }
    default { return -1 }
  }
}

function Compare-HandScore {
  param($Left, $Right)
  if ($null -eq $Left -and $null -eq $Right) { return 0 }
  if ($null -eq $Left) { return -1 }
  if ($null -eq $Right) { return 1 }
  $leftCategory = [int]$Left.category
  $rightCategory = [int]$Right.category
  if ($leftCategory -gt $rightCategory) { return 1 }
  if ($leftCategory -lt $rightCategory) { return -1 }
  $leftValues = @($Left.values)
  $rightValues = @($Right.values)
  $maxCount = [Math]::Max($leftValues.Count, $rightValues.Count)
  for ($i = 0; $i -lt $maxCount; $i++) {
    $lv = if ($i -lt $leftValues.Count) { [int]$leftValues[$i] } else { -1 }
    $rv = if ($i -lt $rightValues.Count) { [int]$rightValues[$i] } else { -1 }
    if ($lv -gt $rv) { return 1 }
    if ($lv -lt $rv) { return -1 }
  }
  return 0
}

function Get-HandCategoryName {
  param([int]$Category)
  switch ($Category) {
    8 { return "STRAIGHT_FLUSH" }
    7 { return "FOUR_OF_A_KIND" }
    6 { return "FULL_HOUSE" }
    5 { return "FLUSH" }
    4 { return "STRAIGHT" }
    3 { return "THREE_OF_A_KIND" }
    2 { return "TWO_PAIR" }
    1 { return "PAIR" }
    0 { return "HIGH_CARD" }
    default { return "UNKNOWN" }
  }
}

function Get-RankLabel {
  param([int]$Rank)
  switch ([int]$Rank) {
    14 { return "Ace" }
    13 { return "King" }
    12 { return "Queen" }
    11 { return "Jack" }
    10 { return "Ten" }
    9 { return "Nine" }
    8 { return "Eight" }
    7 { return "Seven" }
    6 { return "Six" }
    5 { return "Five" }
    4 { return "Four" }
    3 { return "Three" }
    2 { return "Two" }
    default { return "Unknown" }
  }
}

function Format-HandScoreNarrative {
  param($Score)
  if ($null -eq $Score) {
    return "No hand"
  }
  $category = 0
  $values = @()
  try { $category = [int]$Score.category } catch { $category = -1 }
  try { $values = @($Score.values) } catch { $values = @() }
  switch ($category) {
    8 {
      $hi = if ($values.Count -ge 1) { [int]$values[0] } else { 0 }
      if ($hi -eq 14) { return "Royal Flush" }
      return ("Straight Flush, {0}-high" -f (Get-RankLabel -Rank $hi))
    }
    7 {
      if ($values.Count -ge 2) {
        $quadLabel = Get-RankLabel -Rank ([int]$values[0])
        $kickerLabel = Get-RankLabel -Rank ([int]$values[1])
        return ("Four of a Kind, {0}s with {1} kicker" -f $quadLabel, $kickerLabel)
      }
      return "Four of a Kind"
    }
    6 {
      if ($values.Count -ge 2) {
        $tripLabel = Get-RankLabel -Rank ([int]$values[0])
        $pairLabel = Get-RankLabel -Rank ([int]$values[1])
        return ("Full House, {0}s full of {1}s" -f $tripLabel, $pairLabel)
      }
      return "Full House"
    }
    5 {
      $hi = if ($values.Count -ge 1) { [int]$values[0] } else { 0 }
      return ("Flush, {0}-high" -f (Get-RankLabel -Rank $hi))
    }
    4 {
      $hi = if ($values.Count -ge 1) { [int]$values[0] } else { 0 }
      return ("Straight, {0}-high" -f (Get-RankLabel -Rank $hi))
    }
    3 {
      if ($values.Count -ge 3) {
        $tripLabel = Get-RankLabel -Rank ([int]$values[0])
        $kickerOne = Get-RankLabel -Rank ([int]$values[1])
        $kickerTwo = Get-RankLabel -Rank ([int]$values[2])
        return ("Three of a Kind, {0}s with {1}/{2} kickers" -f $tripLabel, $kickerOne, $kickerTwo)
      }
      return "Three of a Kind"
    }
    2 {
      if ($values.Count -ge 3) {
        $topPair = Get-RankLabel -Rank ([int]$values[0])
        $bottomPair = Get-RankLabel -Rank ([int]$values[1])
        $kickerLabel = Get-RankLabel -Rank ([int]$values[2])
        return ("Two Pair, {0}s and {1}s with {2} kicker" -f $topPair, $bottomPair, $kickerLabel)
      }
      return "Two Pair"
    }
    1 {
      if ($values.Count -ge 4) {
        $pairLabel = Get-RankLabel -Rank ([int]$values[0])
        $kickerOne = Get-RankLabel -Rank ([int]$values[1])
        $kickerTwo = Get-RankLabel -Rank ([int]$values[2])
        $kickerThree = Get-RankLabel -Rank ([int]$values[3])
        return ("Pair of {0}s with {1}/{2}/{3} kickers" -f $pairLabel, $kickerOne, $kickerTwo, $kickerThree)
      }
      return "Pair"
    }
    0 {
      $hi = if ($values.Count -ge 1) { [int]$values[0] } else { 0 }
      return ("High Card {0}" -f (Get-RankLabel -Rank $hi))
    }
    default { return "Unknown hand" }
  }
}

function Format-HandScoreSummary {
  param($Score)
  if ($null -eq $Score) {
    return "NONE"
  }
  $category = 0
  try { $category = [int]$Score.category } catch { $category = -1 }
  $values = @()
  try { $values = @($Score.values) } catch { $values = @() }
  return ("{0} ({1})" -f (Get-HandCategoryName -Category $category), (@($values) -join ","))
}

function Get-5CardHandScore {
  param([Parameter(Mandatory = $true)][string[]]$Cards)
  $parsed = foreach ($card in @($Cards)) {
    [pscustomobject]@{
      rank = [int](Get-CardRankInt -Token $card)
      suit = [string](Normalize-CardToken -Text $card).Substring(1,1).ToLowerInvariant()
    }
  }
  $parsed = @($parsed | Sort-Object -Property rank -Descending)
  $ranks = @($parsed | ForEach-Object { [int]$_.rank })
  $suits = @($parsed | ForEach-Object { [string]$_.suit })
  $uniqueSuits = @($suits | Select-Object -Unique)
  $isFlush = ($uniqueSuits.Count -eq 1)
  $uniqueRanks = @($ranks | Select-Object -Unique)
  $straightHigh = 0
  $isStraight = $false
  if ($uniqueRanks.Count -eq 5) {
    $sortedUnique = @($uniqueRanks | Sort-Object -Descending)
    if (($sortedUnique[0] - $sortedUnique[4]) -eq 4) {
      $isStraight = $true
      $straightHigh = [int]$sortedUnique[0]
    }
    elseif (@($sortedUnique) -join "," -eq "14,5,4,3,2") {
      $isStraight = $true
      $straightHigh = 5
    }
  }
  $rankCounts = @{}
  foreach ($rank in @($ranks)) {
    if (-not $rankCounts.ContainsKey($rank)) {
      $rankCounts[$rank] = 0
    }
    $rankCounts[$rank] = [int]$rankCounts[$rank] + 1
  }
  $countRows = foreach ($key in @($rankCounts.Keys)) {
    [pscustomobject]@{
      count = [int]$rankCounts[$key]
      rank = [int]$key
    }
  }
  $countRows = @($countRows | Sort-Object -Property count, rank -Descending)
  if ($isStraight -and $isFlush) {
    return [pscustomobject]@{ category = 8; values = @([int]$straightHigh) }
  }
  if ($countRows[0].count -eq 4) {
    return [pscustomobject]@{ category = 7; values = @([int]$countRows[0].rank, [int]$countRows[1].rank) }
  }
  if ($countRows[0].count -eq 3 -and $countRows[1].count -eq 2) {
    return [pscustomobject]@{ category = 6; values = @([int]$countRows[0].rank, [int]$countRows[1].rank) }
  }
  if ($isFlush) {
    return [pscustomobject]@{ category = 5; values = @($ranks) }
  }
  if ($isStraight) {
    return [pscustomobject]@{ category = 4; values = @([int]$straightHigh) }
  }
  if ($countRows[0].count -eq 3) {
    $kickers = @($ranks | Where-Object { $_ -ne [int]$countRows[0].rank } | Sort-Object -Descending)
    return [pscustomobject]@{ category = 3; values = @([int]$countRows[0].rank) + @($kickers) }
  }
  if ($countRows[0].count -eq 2 -and $countRows[1].count -eq 2) {
    $pairRanks = @([int]$countRows[0].rank, [int]$countRows[1].rank) | Sort-Object -Descending
    $kicker = @($ranks | Where-Object { ($_ -ne [int]$pairRanks[0]) -and ($_ -ne [int]$pairRanks[1]) })[0]
    return [pscustomobject]@{ category = 2; values = @([int]$pairRanks[0], [int]$pairRanks[1], [int]$kicker) }
  }
  if ($countRows[0].count -eq 2) {
    $kickers = @($ranks | Where-Object { $_ -ne [int]$countRows[0].rank } | Sort-Object -Descending)
    return [pscustomobject]@{ category = 1; values = @([int]$countRows[0].rank) + @($kickers) }
  }
  return [pscustomobject]@{ category = 0; values = @($ranks) }
}

function Get-BestSevenCardHandResult {
  param([Parameter(Mandatory = $true)][string[]]$Cards)
  if ($Cards.Count -ne 7) {
    throw "Get-BestSevenCardHandResult requires exactly 7 cards."
  }
  $best = $null
  $bestCards = @()
  for ($a = 0; $a -lt 3; $a++) {
    for ($b = $a + 1; $b -lt 4; $b++) {
      for ($c = $b + 1; $c -lt 5; $c++) {
        for ($d = $c + 1; $d -lt 6; $d++) {
          for ($e = $d + 1; $e -lt 7; $e++) {
            $candidateCards = @($Cards[$a], $Cards[$b], $Cards[$c], $Cards[$d], $Cards[$e])
            $score = Get-5CardHandScore -Cards $candidateCards
            if ((Compare-HandScore -Left $score -Right $best) -gt 0) {
              $best = $score
              $bestCards = @($candidateCards)
            }
          }
        }
      }
    }
  }
  return [pscustomobject]@{
    score = $best
    cards = @($bestCards)
  }
}

function Get-BestSevenCardHandScore {
  param([Parameter(Mandatory = $true)][string[]]$Cards)
  $result = Get-BestSevenCardHandResult -Cards $Cards
  return $result.score
}

function Resolve-ShowdownAndAwardPot {
  $boardCards = @($lastBoardTokens | Where-Object { Test-CardTokenStrict -Token $_ })
  $heroCardsNow = @()
  foreach ($slot in @($playerSlotOrder)) {
    $token = Get-AssignedCardTokenForSlot -Slot $slot
    if (Test-CardTokenStrict -Token $token) {
      $heroCardsNow += $token
    }
  }
  $villainCardsNow = @()
  foreach ($slot in @("villain1", "villain2")) {
    $token = Normalize-CardToken -Text ([string]$script:villainCards[$slot])
    if (Test-CardTokenStrict -Token $token) {
      $villainCardsNow += $token
    }
  }
  if ($boardCards.Count -ne 5 -or $heroCardsNow.Count -ne 2 -or $villainCardsNow.Count -ne 2) {
    return $false
  }
  $heroResult = Get-BestSevenCardHandResult -Cards (@($heroCardsNow) + @($boardCards))
  $villainResult = Get-BestSevenCardHandResult -Cards (@($villainCardsNow) + @($boardCards))
  $heroScore = $heroResult.score
  $villainScore = $villainResult.score
  $cmp = Compare-HandScore -Left $heroScore -Right $villainScore
  $heroSummary = Format-HandScoreSummary -Score $heroScore
  $villainSummary = Format-HandScoreSummary -Score $villainScore
  $heroNarrative = Format-HandScoreNarrative -Score $heroScore
  $villainNarrative = Format-HandScoreNarrative -Score $villainScore
  Write-Log ("Showdown eval: hero={0} ({1}) vs villain={2} ({3}) on board={4} -> cmp={5}" -f `
    ($heroCardsNow -join " "), $heroSummary, ($villainCardsNow -join " "), $villainSummary, ($boardCards -join " "), $cmp) -Type "showdown_eval" -Data @{
      board = @($boardCards)
      hero_cards = @($heroCardsNow)
      villain_cards = @($villainCardsNow)
      hero_best_five = @($heroResult.cards)
      villain_best_five = @($villainResult.cards)
      hero_score = $heroSummary
      villain_score = $villainSummary
      hero_narrative = $heroNarrative
      villain_narrative = $villainNarrative
      compare_result = [int]$cmp
      current_pot = [int]$script:currentPotAmount
    }
  if ($cmp -gt 0) {
    Award-PotToWinner -Winner "hero" -Reason "showdown" -OutcomeSummary ("Showdown: {0} beats {1}. Pot {2} awarded." -f $heroNarrative, $villainNarrative, [int]$script:currentPotAmount)
  }
  elseif ($cmp -lt 0) {
    Award-PotToWinner -Winner "villain" -Reason "showdown" -OutcomeSummary ("Showdown: {0} beats {1}. Pot {2} awarded." -f $villainNarrative, $heroNarrative, [int]$script:currentPotAmount)
  }
  else {
    $award = [int]([Math]::Floor(([int]$script:currentPotAmount) / 2))
    $remainder = [int]([Math]::Max(0, ([int]$script:currentPotAmount - ($award * 2))))
    $script:currentHeroChips = [int]$script:currentHeroChips + $award + $remainder
    $script:currentVillainChips = [int]$script:currentVillainChips + $award
    $script:currentPotAmount = 0
    $script:handResolved = $true
    Reset-StreetActionState
    Update-TableStateDisplay
    Prepare-NextHandBackendState
    $script:adviceActionPrimary = "CHOP"
    $script:adviceActionSecondary = ("Showdown split pot. Both played: {0}" -f $heroNarrative)
    $script:adviceHasAction = $true
    Set-AdviceState -Primary $script:adviceActionPrimary -Secondary $script:adviceActionSecondary
    Write-Log "Showdown split pot." -Type "hand_settled" -Data @{
      winner = "split"
      hero_narrative = $heroNarrative
      villain_narrative = $villainNarrative
      current_hero_chips = [int]$script:currentHeroChips
      current_villain_chips = [int]$script:currentVillainChips
    }
  }
  return $true
}

function Test-BettingRoundResolved {
  if ($script:handResolved -or $script:heroFolded -or $script:villainFolded) {
    return $false
  }
  if ([int]$script:currentFacingBetAmount -gt 0) {
    return $false
  }
  if ([int]$script:currentHeroStreetCommit -ne [int]$script:currentVillainStreetCommit) {
    return $false
  }
  if ((-not $script:heroActedThisRound) -or (-not $script:villainActedThisRound)) {
    return $false
  }
  return $true
}

function Try-ResolveAllInRunoutIfNoActions {
  if ($script:handResolved -or $script:heroFolded -or $script:villainFolded) {
    return $false
  }

  $heroAllIn = ([int]$script:currentHeroChips -le 0)
  $villainAllIn = ([int]$script:currentVillainChips -le 0)
  if (-not ($heroAllIn -or $villainAllIn)) {
    return $false
  }

  $heroLegal = @(Get-HeroLegalActionTokens)
  $villainLegal = @(Get-VillainLegalActionTokens)
  if ($heroLegal.Count -gt 0 -or $villainLegal.Count -gt 0) {
    return $false
  }

  $boardCount = Get-ValidBoardCardCount -Tokens @($lastBoardTokens)
  if ($boardCount -lt 3) {
    Deal-NextStreetCards -Street "flop"
    Reset-StreetActionState
    $boardCount = 3
  }
  if ($boardCount -lt 4) {
    Deal-NextStreetCards -Street "turn"
    Reset-StreetActionState
    $boardCount = 4
  }
  if ($boardCount -lt 5) {
    Deal-NextStreetCards -Street "river"
    Reset-StreetActionState
  }

  [void](Resolve-ShowdownAndAwardPot)
  Write-Log "Forced all-in runout resolved to showdown." -Type "allin_runout"
  return $true
}

function Try-AdvanceStreetIfRoundResolved {
  if (-not (Test-BettingRoundResolved)) {
    return $false
  }
  $boardCount = Get-ValidBoardCardCount -Tokens @($lastBoardTokens)
  if ($boardCount -eq 0) {
    Deal-NextStreetCards -Street "flop"
    Reset-StreetActionState
    $script:lastHeroAction = "WAIT"
    $script:lastVillainAction = "WAIT"
    return $true
  }
  if ($boardCount -eq 3) {
    Deal-NextStreetCards -Street "turn"
    Reset-StreetActionState
    $script:lastHeroAction = "WAIT"
    $script:lastVillainAction = "WAIT"
    return $true
  }
  if ($boardCount -eq 4) {
    Deal-NextStreetCards -Street "river"
    Reset-StreetActionState
    $script:lastHeroAction = "WAIT"
    $script:lastVillainAction = "WAIT"
    return $true
  }
  if ($boardCount -eq 5) {
    [void](Resolve-ShowdownAndAwardPot)
    return $true
  }
  return $false
}

function Build-EngineSpotPayload {
  param(
    [Parameter(Mandatory = $true)][string[]]$BoardCards,
    [string]$Label = "board",
    [string[]]$HeroCards = @()
  )
  if ($BoardCards.Count -gt 5) {
    throw "Build-EngineSpotPayload requires 0 to 5 board cards."
  }
  if ($BoardCards.Count -gt 0 -and $BoardCards.Count -lt 3) {
    throw "Build-EngineSpotPayload requires either 0 board cards (preflop) or 3 to 5 board cards."
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
  $stakes = Get-StakeSettings
  $defaults = Get-DefaultTableStateFromStakes
  $state = Get-CurrentGameStateSnapshot
  $stackCandidates = New-Object System.Collections.Generic.List[int]
  if ([int]$script:currentHeroChips -gt 0) {
    [void]$stackCandidates.Add([int]$script:currentHeroChips)
  }
  if ([int]$script:currentVillainChips -gt 0) {
    [void]$stackCandidates.Add([int]$script:currentVillainChips)
  }
  if ($stackCandidates.Count -gt 0) {
    $effectiveStack = [int]($stackCandidates | Measure-Object -Minimum).Minimum
  }
  else {
    $effectiveStack = [int]$defaults.hero_chips
  }
  $effectivePot = if ([int]$script:currentPotAmount -gt 0) { [int]$script:currentPotAmount } else { [int]$defaults.starting_pot }
  $streetPostflop = ($BoardCards.Count -ge 3)
  $heroFacingBetNode = $streetPostflop -and ([int]$state.facing_bet -gt 0) -and (-not [bool]$state.hero_folded) -and (-not [bool]$state.villain_folded)
  $heroIpCheckedToNode = $streetPostflop -and `
    ([int]$state.facing_bet -le 0) -and `
    (Test-IsHeroTurn) -and `
    [bool]$script:heroIsSmallBlind -and `
    (-not [bool]$state.hero_folded) -and `
    (-not [bool]$state.villain_folded)
  $useActiveNode = $heroFacingBetNode -or $heroIpCheckedToNode
  if ($useActiveNode) {
    $effectivePot = [int]([Math]::Max(1, ([int]$effectivePot - [int]$state.facing_bet)))
  }

  $spot.starting_stack = [int]$effectiveStack
  $spot.minimum_bet = [int]$stakes.big_blind
  $spot.starting_pot = [int]$effectivePot
  $heroComboRange = Convert-HoleCardsToStructuralCombo -Cards @($HeroCards)
  if ($heroComboRange) {
    $spot.hero_range = [string]$heroComboRange
  }
  $spot.board = @()
  foreach ($card in $BoardCards) {
    $spot.board += ([string]$card).Trim()
  }
  if (-not ($spot.PSObject.Properties.Name -contains "meta") -or $null -eq $spot.meta) {
    $spot | Add-Member -NotePropertyName meta -NotePropertyValue @{} -Force
  }
  $spot.meta.small_blind = [int]$stakes.small_blind
  $spot.meta.big_blind = [int]$stakes.big_blind
  $spot.meta.buy_in = [int]$stakes.buy_in
  $spot.meta.capture_source = "vision_tester"
  $spot.meta.current_pot = [int]$state.current_pot
  $spot.meta.current_hero_chips = [int]$state.current_hero_chips
  $spot.meta.current_villain_chips = [int]$state.current_villain_chips
  $spot.meta.facing_bet = [int]$state.facing_bet
  $spot.meta.hero_street_commit = [int]$state.hero_street_commit
  $spot.meta.villain_street_commit = [int]$state.villain_street_commit
  $spot.meta.active_villains = [int]$state.active_villains
  $spot.meta.configured_villains = [int]$state.configured_villains
  $spot.meta.hero_folded = [bool]$state.hero_folded
  $spot.meta.villain_folded = [bool]$state.villain_folded
  $spot.meta.hero_is_small_blind = [bool]$script:heroIsSmallBlind
  $spot.meta.hero_is_big_blind = (-not [bool]$script:heroIsSmallBlind)
  if ($HeroCards.Count -eq 2) {
    $spot.meta.hero_cards = @(
      ([string]$HeroCards[0]).Trim()
      ([string]$HeroCards[1]).Trim()
    )
    if ($heroComboRange) {
      $spot.meta.hero_combo_range = [string]$heroComboRange
    }
  }
  if ($useActiveNode) {
    if (-not ($spot.PSObject.Properties.Name -contains "active_node_path")) {
      $spot | Add-Member -NotePropertyName active_node_path -NotePropertyValue "" -Force
    }
    $targetNodePath = ""
    if ($heroFacingBetNode) {
      $targetNodePath = ("root/p1:check/p2:bet:{0}" -f [int]$state.facing_bet)
    }
    elseif ($heroIpCheckedToNode) {
      $targetNodePath = "root/p1:check"
    }
    if ($spot -is [System.Collections.IDictionary]) {
      $spot["active_node_path"] = $targetNodePath
    }
    else {
      $spot.active_node_path = $targetNodePath
    }
    $spot.remove_donk_bets = $false
    $streetKey = switch ($BoardCards.Count) {
      3 { "flop" }
      4 { "turn" }
      5 { "river" }
      default { "" }
    }
    if ($streetKey -and ($spot.PSObject.Properties.Name -contains "bet_sizing") -and $null -ne $spot.bet_sizing) {
      $streetSizingProp = $spot.bet_sizing.PSObject.Properties[$streetKey]
      if ($null -ne $streetSizingProp) {
        $streetSizing = $streetSizingProp.Value
        if ($null -ne $streetSizing) {
          $betRatio = [Math]::Round(([double][int]$state.facing_bet / [double][Math]::Max(1, [int]$effectivePot)), 4)
          if ($betRatio -gt 0) {
            $streetSizing.bet_sizes = @([double]$betRatio)
          }
          if ($null -eq $streetSizing.raise_sizes -or @($streetSizing.raise_sizes).Count -eq 0) {
            $streetSizing.raise_sizes = @([double]([Math]::Max(0.75, ([double]$betRatio * 1.5))))
          }
        }
      }
    }
  }
  return $spot
}

function Get-CardPresenceSignalFromRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region
  )
  if (-not [bool]$script:screenCaptureEnabled) {
    return [pscustomobject]@{
      likely_card = $false
      white_ratio = 0.0
      green_ratio = 0.0
      sampled = 0
    }
  }

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
  if (-not [bool]$script:screenCaptureEnabled) {
    return $null
  }
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
  if (-not [bool]$script:screenCaptureEnabled) {
    return $null
  }

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
$form.Size = New-Object System.Drawing.Size(1240, 790)
$form.MinimumSize = New-Object System.Drawing.Size(1120, 760)
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
$status.Size = New-Object System.Drawing.Size(780, 18)
$status.AutoSize = $false
$status.AutoEllipsis = $true
$modeLabel = if ($rankOnlyMode) { "rank-only" } else { "rank+suit" }
$parallelLabel = if ($ocrParallelEnabled) { ("parallel({0})" -f [int]$ocrParallelMaxWorkers) } else { "sequential" }
$statusBaseText = ("Local Vision: {0} @ {1} (keep_alive={2}) | capture: {3} | card mode: {4} | ocr: {5} | bridge: {6} | profile: {7} | neural: {8}" -f $ollamaVisionModel, $ollamaHost, $ollamaVisionKeepAlive, $screenCaptureStatusLabel, $modeLabel, $parallelLabel, $bridgeSolveEndpoint, $engineRuntimeProfile.ToUpperInvariant(), $neuralStatusLabel)
$status.Text = ("{0} | Engine: idle" -f $statusBaseText)
$status.ForeColor = [System.Drawing.Color]::FromArgb(140, 220, 170)
$form.Controls.Add($status)

$engineStatusLine = New-Object System.Windows.Forms.Label
$engineStatusLine.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$engineStatusLine.Location = New-Object System.Drawing.Point(20, 64)
$engineStatusLine.Size = New-Object System.Drawing.Size(780, 18)
$engineStatusLine.AutoSize = $false
$engineStatusLine.AutoEllipsis = $true
$engineStatusLine.Text = "Engine queue: idle"
$engineStatusLine.ForeColor = [System.Drawing.Color]::FromArgb(165, 190, 210)
$form.Controls.Add($engineStatusLine)

$regionLabel = New-Object System.Windows.Forms.Label
$regionLabel.Text = "Selected: none"
$regionLabel.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$regionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$regionLabel.Location = New-Object System.Drawing.Point(20, 86)
$regionLabel.Size = New-Object System.Drawing.Size(780, 20)
$regionLabel.AutoSize = $false
$regionLabel.AutoEllipsis = $true
$form.Controls.Add($regionLabel)

$cardStatusLabel = New-Object System.Windows.Forms.Label
$cardStatusLabel.Text = "Set board (5), hero, and action targets."
$cardStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$cardStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cardStatusLabel.Location = New-Object System.Drawing.Point(20, 108)
$cardStatusLabel.Size = New-Object System.Drawing.Size(780, 18)
$cardStatusLabel.AutoSize = $false
$cardStatusLabel.AutoEllipsis = $true
$form.Controls.Add($cardStatusLabel)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = "Pick ROI"
$btnPick.Location = New-Object System.Drawing.Point(20, 136)
$btnPick.Size = New-Object System.Drawing.Size(190, 34)
$btnPick.FlatStyle = "Flat"
$btnPick.ForeColor = [System.Drawing.Color]::White
$btnPick.BackColor = [System.Drawing.Color]::FromArgb(46, 56, 68)
$form.Controls.Add($btnPick)

$btnOnce = New-Object System.Windows.Forms.Button
$btnOnce.Text = "Run OCR Once"
$btnOnce.Location = New-Object System.Drawing.Point(220, 136)
$btnOnce.Size = New-Object System.Drawing.Size(140, 34)
$btnOnce.FlatStyle = "Flat"
$btnOnce.ForeColor = [System.Drawing.Color]::White
$btnOnce.BackColor = [System.Drawing.Color]::FromArgb(20, 95, 62)
$form.Controls.Add($btnOnce)

$btnRandomCard = New-Object System.Windows.Forms.Button
$btnRandomCard.Text = "Random Card"
$btnRandomCard.Location = New-Object System.Drawing.Point(370, 136)
$btnRandomCard.Size = New-Object System.Drawing.Size(110, 34)
$btnRandomCard.FlatStyle = "Flat"
$btnRandomCard.ForeColor = [System.Drawing.Color]::White
$btnRandomCard.BackColor = [System.Drawing.Color]::FromArgb(82, 58, 112)
$form.Controls.Add($btnRandomCard)

$lblAuto = New-Object System.Windows.Forms.Label
$lblAuto.Text = "Auto OCR interval (sec)"
$lblAuto.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblAuto.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblAuto.Location = New-Object System.Drawing.Point(490, 143)
$lblAuto.AutoSize = $true
$form.Controls.Add($lblAuto)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(520, 140)
$numInterval.Size = New-Object System.Drawing.Size(70, 30)
$numInterval.Minimum = 1
$numInterval.Maximum = 60
$numInterval.Value = 5
$numInterval.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($numInterval)

$btnAutoStart = New-Object System.Windows.Forms.Button
$btnAutoStart.Text = "Start Auto"
$btnAutoStart.Location = New-Object System.Drawing.Point(610, 136)
$btnAutoStart.Size = New-Object System.Drawing.Size(80, 34)
$btnAutoStart.FlatStyle = "Flat"
$btnAutoStart.ForeColor = [System.Drawing.Color]::White
$btnAutoStart.BackColor = [System.Drawing.Color]::FromArgb(30, 105, 68)
$form.Controls.Add($btnAutoStart)

$btnAutoStop = New-Object System.Windows.Forms.Button
$btnAutoStop.Text = "Stop Auto"
$btnAutoStop.Location = New-Object System.Drawing.Point(695, 136)
$btnAutoStop.Size = New-Object System.Drawing.Size(80, 34)
$btnAutoStop.FlatStyle = "Flat"
$btnAutoStop.ForeColor = [System.Drawing.Color]::White
$btnAutoStop.BackColor = [System.Drawing.Color]::FromArgb(110, 30, 30)
$btnAutoStop.Enabled = $false
$form.Controls.Add($btnAutoStop)

$btnRunEngine = New-Object System.Windows.Forms.Button
$btnRunEngine.Text = "Run Engine"
$btnRunEngine.Location = New-Object System.Drawing.Point(780, 136)
$btnRunEngine.Size = New-Object System.Drawing.Size(95, 34)
$btnRunEngine.FlatStyle = "Flat"
$btnRunEngine.ForeColor = [System.Drawing.Color]::White
$btnRunEngine.BackColor = [System.Drawing.Color]::FromArgb(46, 74, 118)
$form.Controls.Add($btnRunEngine)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "Restart"
$btnRestart.Location = New-Object System.Drawing.Point(880, 136)
$btnRestart.Size = New-Object System.Drawing.Size(80, 34)
$btnRestart.FlatStyle = "Flat"
$btnRestart.ForeColor = [System.Drawing.Color]::White
$btnRestart.BackColor = [System.Drawing.Color]::FromArgb(52, 64, 92)
$form.Controls.Add($btnRestart)

$btnNewHand = New-Object System.Windows.Forms.Button
$btnNewHand.Text = "New Hand"
$btnNewHand.Location = New-Object System.Drawing.Point(785, 136)
$btnNewHand.Size = New-Object System.Drawing.Size(95, 34)
$btnNewHand.FlatStyle = "Flat"
$btnNewHand.ForeColor = [System.Drawing.Color]::White
$btnNewHand.BackColor = [System.Drawing.Color]::FromArgb(64, 84, 108)
$form.Controls.Add($btnNewHand)

$btnTargets = New-Object System.Windows.Forms.Button
$btnTargets.Text = "Targets: On (F8)"
$btnTargets.Location = New-Object System.Drawing.Point(610, 176)
$btnTargets.Size = New-Object System.Drawing.Size(120, 26)
$btnTargets.FlatStyle = "Flat"
$btnTargets.ForeColor = [System.Drawing.Color]::White
$btnTargets.BackColor = [System.Drawing.Color]::FromArgb(44, 72, 96)
$form.Controls.Add($btnTargets)

$btnResetRois = New-Object System.Windows.Forms.Button
$btnResetRois.Text = "Reset ROIs"
$btnResetRois.Location = New-Object System.Drawing.Point(740, 176)
$btnResetRois.Size = New-Object System.Drawing.Size(120, 26)
$btnResetRois.FlatStyle = "Flat"
$btnResetRois.ForeColor = [System.Drawing.Color]::White
$btnResetRois.BackColor = [System.Drawing.Color]::FromArgb(92, 58, 44)
$form.Controls.Add($btnResetRois)

$btnSetHeroes = New-Object System.Windows.Forms.Button
$btnSetHeroes.Text = "Set Heroes ROI"
$btnSetHeroes.Location = New-Object System.Drawing.Point(870, 176)
$btnSetHeroes.Size = New-Object System.Drawing.Size(90, 26)
$btnSetHeroes.FlatStyle = "Flat"
$btnSetHeroes.ForeColor = [System.Drawing.Color]::White
$btnSetHeroes.BackColor = [System.Drawing.Color]::FromArgb(84, 64, 120)
$form.Controls.Add($btnSetHeroes)

$lblEngineProfile = New-Object System.Windows.Forms.Label
$lblEngineProfile.Text = "Engine Profile"
$lblEngineProfile.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblEngineProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblEngineProfile.Location = New-Object System.Drawing.Point(610, 214)
$lblEngineProfile.AutoSize = $true
$form.Controls.Add($lblEngineProfile)

$cmbEngineProfile = New-Object System.Windows.Forms.ComboBox
$cmbEngineProfile.DropDownStyle = "DropDownList"
$cmbEngineProfile.Location = New-Object System.Drawing.Point(700, 211)
$cmbEngineProfile.Size = New-Object System.Drawing.Size(100, 24)
$cmbEngineProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbEngineProfile.Items.Add("fast")
[void]$cmbEngineProfile.Items.Add("fast_live")
[void]$cmbEngineProfile.Items.Add("normal")
$profileIdx = $cmbEngineProfile.Items.IndexOf($engineRuntimeProfile)
if ($profileIdx -lt 0) { $profileIdx = 0 }
$cmbEngineProfile.SelectedIndex = $profileIdx
$form.Controls.Add($cmbEngineProfile)

$lblQuick = New-Object System.Windows.Forms.Label
$lblQuick.Text = "Quick Test (single slot)"
$lblQuick.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblQuick.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblQuick.Location = New-Object System.Drawing.Point(20, 214)
$lblQuick.AutoSize = $true
$form.Controls.Add($lblQuick)

$btnQuickToggle = New-Object System.Windows.Forms.Button
$btnQuickToggle.Text = "Hide Quick Tests"
$btnQuickToggle.Location = New-Object System.Drawing.Point(150, 210)
$btnQuickToggle.Size = New-Object System.Drawing.Size(120, 28)
$btnQuickToggle.FlatStyle = "Flat"
$btnQuickToggle.ForeColor = [System.Drawing.Color]::White
$btnQuickToggle.BackColor = [System.Drawing.Color]::FromArgb(52, 64, 92)
$form.Controls.Add($btnQuickToggle)

$btnRunFlop1 = New-Object System.Windows.Forms.Button
$btnRunFlop1.Text = "Run flop1"
$btnRunFlop1.Location = New-Object System.Drawing.Point(170, 210)
$btnRunFlop1.Size = New-Object System.Drawing.Size(90, 28)
$btnRunFlop1.FlatStyle = "Flat"
$btnRunFlop1.ForeColor = [System.Drawing.Color]::White
$btnRunFlop1.BackColor = [System.Drawing.Color]::FromArgb(36, 86, 60)
$form.Controls.Add($btnRunFlop1)

$btnRunFlop2 = New-Object System.Windows.Forms.Button
$btnRunFlop2.Text = "Run flop2"
$btnRunFlop2.Location = New-Object System.Drawing.Point(266, 210)
$btnRunFlop2.Size = New-Object System.Drawing.Size(90, 28)
$btnRunFlop2.FlatStyle = "Flat"
$btnRunFlop2.ForeColor = [System.Drawing.Color]::White
$btnRunFlop2.BackColor = [System.Drawing.Color]::FromArgb(36, 86, 60)
$form.Controls.Add($btnRunFlop2)

$btnRunFlop3 = New-Object System.Windows.Forms.Button
$btnRunFlop3.Text = "Run flop3"
$btnRunFlop3.Location = New-Object System.Drawing.Point(362, 210)
$btnRunFlop3.Size = New-Object System.Drawing.Size(90, 28)
$btnRunFlop3.FlatStyle = "Flat"
$btnRunFlop3.ForeColor = [System.Drawing.Color]::White
$btnRunFlop3.BackColor = [System.Drawing.Color]::FromArgb(36, 86, 60)
$form.Controls.Add($btnRunFlop3)

$btnRunTurn = New-Object System.Windows.Forms.Button
$btnRunTurn.Text = "Run Turn+E"
$btnRunTurn.Location = New-Object System.Drawing.Point(458, 210)
$btnRunTurn.Size = New-Object System.Drawing.Size(90, 28)
$btnRunTurn.FlatStyle = "Flat"
$btnRunTurn.ForeColor = [System.Drawing.Color]::White
$btnRunTurn.BackColor = [System.Drawing.Color]::FromArgb(96, 78, 36)
$form.Controls.Add($btnRunTurn)

$btnRunRiver = New-Object System.Windows.Forms.Button
$btnRunRiver.Text = "Run River+E"
$btnRunRiver.Location = New-Object System.Drawing.Point(554, 210)
$btnRunRiver.Size = New-Object System.Drawing.Size(90, 28)
$btnRunRiver.FlatStyle = "Flat"
$btnRunRiver.ForeColor = [System.Drawing.Color]::White
$btnRunRiver.BackColor = [System.Drawing.Color]::FromArgb(96, 66, 36)
$form.Controls.Add($btnRunRiver)

$btnRunFlopSet = New-Object System.Windows.Forms.Button
$btnRunFlopSet.Text = "Run Flop (1-3)"
$btnRunFlopSet.Location = New-Object System.Drawing.Point(650, 210)
$btnRunFlopSet.Size = New-Object System.Drawing.Size(140, 28)
$btnRunFlopSet.FlatStyle = "Flat"
$btnRunFlopSet.ForeColor = [System.Drawing.Color]::White
$btnRunFlopSet.BackColor = [System.Drawing.Color]::FromArgb(24, 104, 78)
$form.Controls.Add($btnRunFlopSet)

$btnRunHero = New-Object System.Windows.Forms.Button
$btnRunHero.Text = "Run Hero"
$btnRunHero.Location = New-Object System.Drawing.Point(796, 210)
$btnRunHero.Size = New-Object System.Drawing.Size(160, 28)
$btnRunHero.FlatStyle = "Flat"
$btnRunHero.ForeColor = [System.Drawing.Color]::White
$btnRunHero.BackColor = [System.Drawing.Color]::FromArgb(88, 66, 120)
$form.Controls.Add($btnRunHero)

$btnFold = New-Object System.Windows.Forms.Button
$btnFold.Text = "Fold"
$btnFold.Location = New-Object System.Drawing.Point(840, 18)
$btnFold.Size = New-Object System.Drawing.Size(84, 28)
$btnFold.FlatStyle = "Flat"
$btnFold.ForeColor = [System.Drawing.Color]::White
$btnFold.BackColor = [System.Drawing.Color]::FromArgb(112, 118, 126)
$btnFold.Add_Click({ Invoke-ManualActionSelection -ActionToken "FOLD" })
$form.Controls.Add($btnFold)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Check"
$btnCheck.Location = New-Object System.Drawing.Point(840, 18)
$btnCheck.Size = New-Object System.Drawing.Size(84, 28)
$btnCheck.FlatStyle = "Flat"
$btnCheck.ForeColor = [System.Drawing.Color]::White
$btnCheck.BackColor = [System.Drawing.Color]::FromArgb(40, 108, 88)
$btnCheck.Add_Click({ Invoke-ManualActionSelection -ActionToken ([string]$script:checkCallButtonToken) })
$form.Controls.Add($btnCheck)
$script:btnCheck = $btnCheck

$btnCall = New-Object System.Windows.Forms.Button
$btnCall.Text = "Call"
$btnCall.Location = New-Object System.Drawing.Point(930, 18)
$btnCall.Size = New-Object System.Drawing.Size(84, 28)
$btnCall.FlatStyle = "Flat"
$btnCall.ForeColor = [System.Drawing.Color]::White
$btnCall.BackColor = [System.Drawing.Color]::FromArgb(38, 120, 68)
$btnCall.Add_Click({ Invoke-ManualActionSelection -ActionToken "CALL" })
$btnCall.Visible = $false
$form.Controls.Add($btnCall)

$btnRaise = New-Object System.Windows.Forms.Button
$btnRaise.Text = "Default Raise"
$btnRaise.Location = New-Object System.Drawing.Point(1020, 18)
$btnRaise.Size = New-Object System.Drawing.Size(84, 28)
$btnRaise.FlatStyle = "Flat"
$btnRaise.ForeColor = [System.Drawing.Color]::White
$btnRaise.BackColor = [System.Drawing.Color]::FromArgb(184, 112, 42)
$btnRaise.Add_Click({ Invoke-ManualRaisePreset -Preset "default" })
$form.Controls.Add($btnRaise)
$script:btnRaise = $btnRaise

$btnRaise25 = New-Object System.Windows.Forms.Button
$btnRaise25.Text = "25% Pot"
$btnRaise25.Tag = "25% Pot"
$btnRaise25.Location = New-Object System.Drawing.Point(1020, 48)
$btnRaise25.Size = New-Object System.Drawing.Size(84, 28)
$btnRaise25.FlatStyle = "Flat"
$btnRaise25.ForeColor = [System.Drawing.Color]::White
$btnRaise25.BackColor = [System.Drawing.Color]::FromArgb(184, 112, 42)
$btnRaise25.Add_Click({ Invoke-ManualRaisePreset -Preset "pot25" })
$form.Controls.Add($btnRaise25)
$script:btnRaise25 = $btnRaise25

$btnRaise50 = New-Object System.Windows.Forms.Button
$btnRaise50.Text = "50% Pot"
$btnRaise50.Tag = "50% Pot"
$btnRaise50.Location = New-Object System.Drawing.Point(1110, 48)
$btnRaise50.Size = New-Object System.Drawing.Size(84, 28)
$btnRaise50.FlatStyle = "Flat"
$btnRaise50.ForeColor = [System.Drawing.Color]::White
$btnRaise50.BackColor = [System.Drawing.Color]::FromArgb(184, 112, 42)
$btnRaise50.Add_Click({ Invoke-ManualRaisePreset -Preset "pot50" })
$form.Controls.Add($btnRaise50)
$script:btnRaise50 = $btnRaise50

$btnRaise100 = New-Object System.Windows.Forms.Button
$btnRaise100.Text = "100% Pot"
$btnRaise100.Tag = "100% Pot"
$btnRaise100.Location = New-Object System.Drawing.Point(1200, 48)
$btnRaise100.Size = New-Object System.Drawing.Size(84, 28)
$btnRaise100.FlatStyle = "Flat"
$btnRaise100.ForeColor = [System.Drawing.Color]::White
$btnRaise100.BackColor = [System.Drawing.Color]::FromArgb(184, 112, 42)
$btnRaise100.Add_Click({ Invoke-ManualRaisePreset -Preset "pot100" })
$form.Controls.Add($btnRaise100)
$script:btnRaise100 = $btnRaise100

$lblRaiseAmountTitle = New-Object System.Windows.Forms.Label
$lblRaiseAmountTitle.Text = "Custom Raise"
$lblRaiseAmountTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblRaiseAmountTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblRaiseAmountTitle.Location = New-Object System.Drawing.Point(1020, 78)
$lblRaiseAmountTitle.AutoSize = $true
$form.Controls.Add($lblRaiseAmountTitle)
$script:lblRaiseAmountTitle = $lblRaiseAmountTitle

$trkRaiseAmount = New-Object System.Windows.Forms.TrackBar
$trkRaiseAmount.Location = New-Object System.Drawing.Point(1020, 98)
$trkRaiseAmount.Size = New-Object System.Drawing.Size(130, 30)
$trkRaiseAmount.Minimum = 0
$trkRaiseAmount.Maximum = 100
$trkRaiseAmount.TickStyle = [System.Windows.Forms.TickStyle]::None
$trkRaiseAmount.SmallChange = 1
$trkRaiseAmount.LargeChange = 5
$form.Controls.Add($trkRaiseAmount)
$script:trkRaiseAmount = $trkRaiseAmount

$numRaiseAmount = New-Object System.Windows.Forms.NumericUpDown
$numRaiseAmount.Location = New-Object System.Drawing.Point(1156, 98)
$numRaiseAmount.Size = New-Object System.Drawing.Size(72, 24)
$numRaiseAmount.Minimum = 0
$numRaiseAmount.Maximum = 100000
$numRaiseAmount.Value = 0
$numRaiseAmount.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($numRaiseAmount)
$script:numRaiseAmount = $numRaiseAmount

$lblRaiseAmountValue = New-Object System.Windows.Forms.Label
$lblRaiseAmountValue.Text = "Raise Chips: 0"
$lblRaiseAmountValue.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
$lblRaiseAmountValue.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblRaiseAmountValue.Location = New-Object System.Drawing.Point(1020, 124)
$lblRaiseAmountValue.Size = New-Object System.Drawing.Size(208, 20)
$form.Controls.Add($lblRaiseAmountValue)
$script:lblRaiseAmountValue = $lblRaiseAmountValue

$trkRaiseAmount.Add_Scroll({
  if ($script:raiseAmountSyncBusy) { return }
  $script:raiseAmountSyncBusy = $true
  try {
    if ($null -ne $script:numRaiseAmount -and -not $script:numRaiseAmount.IsDisposed) {
      $script:numRaiseAmount.Value = [decimal][int]$script:trkRaiseAmount.Value
    }
    Update-HeroRaiseAmountDisplay
  }
  finally {
    $script:raiseAmountSyncBusy = $false
  }
}.GetNewClosure())

$numRaiseAmount.Add_ValueChanged({
  if ($script:raiseAmountSyncBusy) { return }
  $script:raiseAmountSyncBusy = $true
  try {
    if ($null -ne $script:trkRaiseAmount -and -not $script:trkRaiseAmount.IsDisposed) {
      $trackValue = [int][decimal]$script:numRaiseAmount.Value
      if ($trackValue -lt $script:trkRaiseAmount.Minimum) { $trackValue = $script:trkRaiseAmount.Minimum }
      if ($trackValue -gt $script:trkRaiseAmount.Maximum) { $trackValue = $script:trkRaiseAmount.Maximum }
      $script:trkRaiseAmount.Value = $trackValue
    }
    Update-HeroRaiseAmountDisplay
  }
  finally {
    $script:raiseAmountSyncBusy = $false
  }
}.GetNewClosure())

$btnAllIn = New-Object System.Windows.Forms.Button
$btnAllIn.Text = "All In"
$btnAllIn.Location = New-Object System.Drawing.Point(1110, 18)
$btnAllIn.Size = New-Object System.Drawing.Size(84, 28)
$btnAllIn.FlatStyle = "Flat"
$btnAllIn.ForeColor = [System.Drawing.Color]::White
$btnAllIn.BackColor = [System.Drawing.Color]::FromArgb(120, 34, 34)
$btnAllIn.Add_Click({ Invoke-ManualActionSelection -ActionToken "ALL IN" })
$btnAllIn.Visible = $true
$form.Controls.Add($btnAllIn)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Flow: select target -> pick ROI -> run OCR (flop/turn/river/hero)."
$hint.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hint.Location = New-Object System.Drawing.Point(20, 244)
$hint.Size = New-Object System.Drawing.Size(780, 18)
$hint.AutoSize = $false
$hint.AutoEllipsis = $true
$form.Controls.Add($hint)

$lblCaptureMode = New-Object System.Windows.Forms.Label
$lblCaptureMode.Text = "Mode"
$lblCaptureMode.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblCaptureMode.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCaptureMode.Location = New-Object System.Drawing.Point(20, 176)
$lblCaptureMode.AutoSize = $true
$form.Controls.Add($lblCaptureMode)

$cmbCaptureMode = New-Object System.Windows.Forms.ComboBox
$cmbCaptureMode.DropDownStyle = "DropDownList"
$cmbCaptureMode.Location = New-Object System.Drawing.Point(110, 173)
$cmbCaptureMode.Size = New-Object System.Drawing.Size(190, 24)
$cmbCaptureMode.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbCaptureMode.Items.Add("Individual Card ROIs")
$cmbCaptureMode.SelectedIndex = 0
$cmbCaptureMode.Enabled = $false
$form.Controls.Add($cmbCaptureMode)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "ROI Target"
$lblTarget.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblTarget.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblTarget.Location = New-Object System.Drawing.Point(320, 176)
$lblTarget.AutoSize = $true
$form.Controls.Add($lblTarget)

$cmbTarget = New-Object System.Windows.Forms.ComboBox
$cmbTarget.DropDownStyle = "DropDownList"
$cmbTarget.Location = New-Object System.Drawing.Point(455, 173)
$cmbTarget.Size = New-Object System.Drawing.Size(140, 24)
$cmbTarget.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbTarget.Items.Add("flop1")
[void]$cmbTarget.Items.Add("flop2")
[void]$cmbTarget.Items.Add("flop3")
[void]$cmbTarget.Items.Add("turn")
[void]$cmbTarget.Items.Add("river")
[void]$cmbTarget.Items.Add("hero")
[void]$cmbTarget.Items.Add("pot")
[void]$cmbTarget.Items.Add("villain")
[void]$cmbTarget.Items.Add("CHECK / CALL")
[void]$cmbTarget.Items.Add("fold")
[void]$cmbTarget.Items.Add("RAISE / ALL IN")
$cmbTarget.SelectedIndex = 0
$cmbTarget.Enabled = $true
$form.Controls.Add($cmbTarget)
$lblTarget.Enabled = $true

$advicePanel = New-Object System.Windows.Forms.Panel
$advicePanel.Location = New-Object System.Drawing.Point(960, 96)
$advicePanel.Size = New-Object System.Drawing.Size(270, 598)
$advicePanel.BackColor = [System.Drawing.Color]::FromArgb(26, 32, 40)
$advicePanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$advicePanel.AutoScroll = $true
$form.Controls.Add($advicePanel)

$adviceTitle = New-Object System.Windows.Forms.Label
$adviceTitle.Text = "ADVICE"
$adviceTitle.ForeColor = [System.Drawing.Color]::White
$adviceTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14, [System.Drawing.FontStyle]::Bold)
$adviceTitle.Location = New-Object System.Drawing.Point(18, 16)
$adviceTitle.AutoSize = $true
$advicePanel.Controls.Add($adviceTitle)

$adviceSub = New-Object System.Windows.Forms.Label
$adviceSub.Text = "Live action output for the current state."
$adviceSub.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 205)
$adviceSub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$adviceSub.Location = New-Object System.Drawing.Point(18, 44)
$adviceSub.Size = New-Object System.Drawing.Size(210, 32)
$adviceSub.AutoEllipsis = $true
$advicePanel.Controls.Add($adviceSub)

$lblAdviceValue = New-Object System.Windows.Forms.Label
$lblAdviceValue.Text = $advicePrimary
$lblAdviceValue.ForeColor = [System.Drawing.Color]::FromArgb(255, 235, 160)
$lblAdviceValue.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 24, [System.Drawing.FontStyle]::Bold)
$lblAdviceValue.Location = New-Object System.Drawing.Point(18, 84)
$lblAdviceValue.Size = New-Object System.Drawing.Size(210, 60)
$lblAdviceValue.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$advicePanel.Controls.Add($lblAdviceValue)

$adviceDivider = New-Object System.Windows.Forms.Label
$adviceDivider.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$adviceDivider.Location = New-Object System.Drawing.Point(18, 160)
$adviceDivider.Size = New-Object System.Drawing.Size(210, 2)
$advicePanel.Controls.Add($adviceDivider)

$adviceMetaTitle = New-Object System.Windows.Forms.Label
$adviceMetaTitle.Text = "Advice Detail"
$adviceMetaTitle.ForeColor = [System.Drawing.Color]::White
$adviceMetaTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$adviceMetaTitle.Location = New-Object System.Drawing.Point(18, 272)
$adviceMetaTitle.AutoSize = $true
$advicePanel.Controls.Add($adviceMetaTitle)

$stakesTitle = New-Object System.Windows.Forms.Label
$stakesTitle.Text = "Stakes"
$stakesTitle.ForeColor = [System.Drawing.Color]::White
$stakesTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$stakesTitle.Location = New-Object System.Drawing.Point(18, 176)
$stakesTitle.AutoSize = $true
$advicePanel.Controls.Add($stakesTitle)

$lblSmallBlind = New-Object System.Windows.Forms.Label
$lblSmallBlind.Text = "SB"
$lblSmallBlind.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblSmallBlind.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblSmallBlind.Location = New-Object System.Drawing.Point(18, 204)
$lblSmallBlind.AutoSize = $true
$advicePanel.Controls.Add($lblSmallBlind)

$numSmallBlind = New-Object System.Windows.Forms.NumericUpDown
$numSmallBlind.Location = New-Object System.Drawing.Point(44, 200)
$numSmallBlind.Size = New-Object System.Drawing.Size(58, 24)
$numSmallBlind.Minimum = 1
$numSmallBlind.Maximum = 10000
$numSmallBlind.Value = 1
$numSmallBlind.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$advicePanel.Controls.Add($numSmallBlind)

$lblBigBlind = New-Object System.Windows.Forms.Label
$lblBigBlind.Text = "BB"
$lblBigBlind.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblBigBlind.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblBigBlind.Location = New-Object System.Drawing.Point(118, 204)
$lblBigBlind.AutoSize = $true
$advicePanel.Controls.Add($lblBigBlind)

$numBigBlind = New-Object System.Windows.Forms.NumericUpDown
$numBigBlind.Location = New-Object System.Drawing.Point(146, 200)
$numBigBlind.Size = New-Object System.Drawing.Size(58, 24)
$numBigBlind.Minimum = 1
$numBigBlind.Maximum = 10000
$numBigBlind.Value = 2
$numBigBlind.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$advicePanel.Controls.Add($numBigBlind)

$lblBuyIn = New-Object System.Windows.Forms.Label
$lblBuyIn.Text = "Buy-In"
$lblBuyIn.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblBuyIn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblBuyIn.Location = New-Object System.Drawing.Point(18, 236)
$lblBuyIn.AutoSize = $true
$advicePanel.Controls.Add($lblBuyIn)

$numBuyIn = New-Object System.Windows.Forms.NumericUpDown
$numBuyIn.Location = New-Object System.Drawing.Point(72, 232)
$numBuyIn.Size = New-Object System.Drawing.Size(132, 24)
$numBuyIn.Minimum = 2
$numBuyIn.Maximum = 100000
$numBuyIn.Value = 100
$numBuyIn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$advicePanel.Controls.Add($numBuyIn)

$lblCurrentPotTitle = New-Object System.Windows.Forms.Label
$lblCurrentPotTitle.Text = "Current Pot"
$lblCurrentPotTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblCurrentPotTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCurrentPotTitle.Location = New-Object System.Drawing.Point(18, 272)
$lblCurrentPotTitle.AutoSize = $true
$advicePanel.Controls.Add($lblCurrentPotTitle)

$lblCurrentPotValue = New-Object System.Windows.Forms.Label
$lblCurrentPotValue.Text = "Pot: 0"
$lblCurrentPotValue.ForeColor = [System.Drawing.Color]::White
$lblCurrentPotValue.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
$lblCurrentPotValue.Location = New-Object System.Drawing.Point(18, 292)
$lblCurrentPotValue.Size = New-Object System.Drawing.Size(210, 22)
$advicePanel.Controls.Add($lblCurrentPotValue)

$lblCurrentChipsTitle = New-Object System.Windows.Forms.Label
$lblCurrentChipsTitle.Text = "Hero Stack"
$lblCurrentChipsTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblCurrentChipsTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCurrentChipsTitle.Location = New-Object System.Drawing.Point(18, 318)
$lblCurrentChipsTitle.AutoSize = $true
$advicePanel.Controls.Add($lblCurrentChipsTitle)

$lblCurrentChipsValue = New-Object System.Windows.Forms.Label
$lblCurrentChipsValue.Text = "Hero Chips: 0"
$lblCurrentChipsValue.ForeColor = [System.Drawing.Color]::White
$lblCurrentChipsValue.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
  $lblCurrentChipsValue.Location = New-Object System.Drawing.Point(18, 338)
  $lblCurrentChipsValue.Size = New-Object System.Drawing.Size(210, 22)
  $advicePanel.Controls.Add($lblCurrentChipsValue)

$lblCurrentVillainChipsTitle = New-Object System.Windows.Forms.Label
$lblCurrentVillainChipsTitle.Text = "Villain Stack"
$lblCurrentVillainChipsTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblCurrentVillainChipsTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCurrentVillainChipsTitle.Location = New-Object System.Drawing.Point(18, 364)
$lblCurrentVillainChipsTitle.AutoSize = $true
$advicePanel.Controls.Add($lblCurrentVillainChipsTitle)

$lblCurrentVillainChipsValue = New-Object System.Windows.Forms.Label
$lblCurrentVillainChipsValue.Text = "Villain Chips: 0"
$lblCurrentVillainChipsValue.ForeColor = [System.Drawing.Color]::White
$lblCurrentVillainChipsValue.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
$lblCurrentVillainChipsValue.Location = New-Object System.Drawing.Point(18, 384)
$lblCurrentVillainChipsValue.Size = New-Object System.Drawing.Size(210, 22)
$advicePanel.Controls.Add($lblCurrentVillainChipsValue)
$script:lblCurrentVillainChipsValue = $lblCurrentVillainChipsValue

$lblHeroPositionTitle = New-Object System.Windows.Forms.Label
$lblHeroPositionTitle.Text = "Position"
$lblHeroPositionTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblHeroPositionTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblHeroPositionTitle.Location = New-Object System.Drawing.Point(18, 410)
$lblHeroPositionTitle.AutoSize = $true
$advicePanel.Controls.Add($lblHeroPositionTitle)

$lblHeroPositionValue = New-Object System.Windows.Forms.Label
$lblHeroPositionValue.Text = "SB / BTN"
$lblHeroPositionValue.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
$lblHeroPositionValue.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblHeroPositionValue.Location = New-Object System.Drawing.Point(18, 430)
$lblHeroPositionValue.Size = New-Object System.Drawing.Size(210, 34)
$lblHeroPositionValue.AutoEllipsis = $true
$advicePanel.Controls.Add($lblHeroPositionValue)
$script:lblHeroPositionValue = $lblHeroPositionValue

$lblTableStatusTitle = New-Object System.Windows.Forms.Label
$lblTableStatusTitle.Text = "Status"
$lblTableStatusTitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblTableStatusTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblTableStatusTitle.Location = New-Object System.Drawing.Point(18, 468)
$lblTableStatusTitle.AutoSize = $true
$advicePanel.Controls.Add($lblTableStatusTitle)

$lblTableStatusValue = New-Object System.Windows.Forms.Label
$lblTableStatusValue.Text = "STATUS: WAIT"
$lblTableStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 160)
$lblTableStatusValue.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9, [System.Drawing.FontStyle]::Bold)
$lblTableStatusValue.Location = New-Object System.Drawing.Point(18, 488)
$lblTableStatusValue.Size = New-Object System.Drawing.Size(210, 32)
$lblTableStatusValue.AutoEllipsis = $true
$advicePanel.Controls.Add($lblTableStatusValue)
$script:lblTableStatusValue = $lblTableStatusValue

$btnToggleVillainCards = New-Object System.Windows.Forms.Button
$btnToggleVillainCards.Text = "Show Villain Cards"
$btnToggleVillainCards.Location = New-Object System.Drawing.Point(18, 524)
$btnToggleVillainCards.Size = New-Object System.Drawing.Size(210, 28)
$btnToggleVillainCards.FlatStyle = "Flat"
$btnToggleVillainCards.ForeColor = [System.Drawing.Color]::White
$btnToggleVillainCards.BackColor = [System.Drawing.Color]::FromArgb(58, 70, 88)
$btnToggleVillainCards.Add_Click({ Toggle-VillainCardsVisibility })
$advicePanel.Controls.Add($btnToggleVillainCards)
$script:btnToggleVillainCards = $btnToggleVillainCards

$lblVillainCardsValue = New-Object System.Windows.Forms.Label
$lblVillainCardsValue.Text = "Villain Cards: Hidden"
$lblVillainCardsValue.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
$lblVillainCardsValue.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblVillainCardsValue.Location = New-Object System.Drawing.Point(18, 558)
$lblVillainCardsValue.Size = New-Object System.Drawing.Size(210, 32)
$lblVillainCardsValue.AutoEllipsis = $true
$advicePanel.Controls.Add($lblVillainCardsValue)

$lblVillainMode = New-Object System.Windows.Forms.Label
$lblVillainMode.Text = "Villain Mode"
$lblVillainMode.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblVillainMode.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblVillainMode.Location = New-Object System.Drawing.Point(18, 594)
$lblVillainMode.AutoSize = $true
$advicePanel.Controls.Add($lblVillainMode)

$cmbVillainMode = New-Object System.Windows.Forms.ComboBox
$cmbVillainMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbVillainMode.Items.AddRange(@("Manual", "Scripted", "Engine Random"))
$cmbVillainMode.SelectedItem = "Scripted"
$cmbVillainMode.Location = New-Object System.Drawing.Point(18, 614)
$cmbVillainMode.Size = New-Object System.Drawing.Size(210, 24)
$cmbVillainMode.Add_SelectedIndexChanged({
  Set-VillainMode -Mode ([string]$cmbVillainMode.SelectedItem)
  if ([string]$script:villainMode -ne "Manual") {
    [void](Try-RunAutomaticVillainTurn)
  }
}.GetNewClosure())
$advicePanel.Controls.Add($cmbVillainMode)
$script:cmbVillainMode = $cmbVillainMode

$lblVillainStyle = New-Object System.Windows.Forms.Label
$lblVillainStyle.Text = "Villain Style"
$lblVillainStyle.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblVillainStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblVillainStyle.Location = New-Object System.Drawing.Point(18, 644)
$lblVillainStyle.AutoSize = $true
$advicePanel.Controls.Add($lblVillainStyle)

$cmbVillainStyle = New-Object System.Windows.Forms.ComboBox
$cmbVillainStyle.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbVillainStyle.Items.AddRange(@("Tight", "Aggressive"))
$cmbVillainStyle.SelectedItem = "Tight"
$cmbVillainStyle.Location = New-Object System.Drawing.Point(18, 664)
$cmbVillainStyle.Size = New-Object System.Drawing.Size(210, 24)
$cmbVillainStyle.Add_SelectedIndexChanged({
  Set-VillainStyle -Style ([string]$cmbVillainStyle.SelectedItem)
}.GetNewClosure())
$advicePanel.Controls.Add($cmbVillainStyle)
$script:cmbVillainStyle = $cmbVillainStyle

$btnVillainActionMenu = New-Object System.Windows.Forms.Button
$btnVillainActionMenu.Text = "Villain Action"
$btnVillainActionMenu.Location = New-Object System.Drawing.Point(18, 696)
$btnVillainActionMenu.Size = New-Object System.Drawing.Size(210, 28)
$btnVillainActionMenu.FlatStyle = "Flat"
$btnVillainActionMenu.ForeColor = [System.Drawing.Color]::White
$btnVillainActionMenu.BackColor = [System.Drawing.Color]::FromArgb(88, 56, 92)
$advicePanel.Controls.Add($btnVillainActionMenu)
$script:btnVillainActionMenu = $btnVillainActionMenu

$villainActionMenu = New-Object System.Windows.Forms.ContextMenuStrip
$btnVillainActionMenu.Add_Click({
  Show-VillainActionMenu
}.GetNewClosure())
$script:villainActionMenu = $villainActionMenu

$btnHeroWinsPot = New-Object System.Windows.Forms.Button
$btnHeroWinsPot.Text = "Hero Wins"
$btnHeroWinsPot.Location = New-Object System.Drawing.Point(18, 518)
$btnHeroWinsPot.Size = New-Object System.Drawing.Size(100, 26)
$btnHeroWinsPot.FlatStyle = "Flat"
$btnHeroWinsPot.ForeColor = [System.Drawing.Color]::White
$btnHeroWinsPot.BackColor = [System.Drawing.Color]::FromArgb(46, 104, 72)
$btnHeroWinsPot.Add_Click({ Award-PotToWinner -Winner "hero" -Reason "manual_settle_button" }.GetNewClosure())
$btnHeroWinsPot.Visible = $false
$advicePanel.Controls.Add($btnHeroWinsPot)
$script:btnHeroWinsPot = $btnHeroWinsPot

$btnVillainWinsPot = New-Object System.Windows.Forms.Button
$btnVillainWinsPot.Text = "Villain Wins"
$btnVillainWinsPot.Location = New-Object System.Drawing.Point(128, 518)
$btnVillainWinsPot.Size = New-Object System.Drawing.Size(100, 26)
$btnVillainWinsPot.FlatStyle = "Flat"
$btnVillainWinsPot.ForeColor = [System.Drawing.Color]::White
$btnVillainWinsPot.BackColor = [System.Drawing.Color]::FromArgb(112, 118, 126)
$btnVillainWinsPot.Add_Click({ Award-PotToWinner -Winner "villain" -Reason "manual_settle_button" }.GetNewClosure())
$btnVillainWinsPot.Visible = $false
$advicePanel.Controls.Add($btnVillainWinsPot)
$script:btnVillainWinsPot = $btnVillainWinsPot

$numSmallBlind.Add_ValueChanged({
  if ($numBigBlind.Value -lt $numSmallBlind.Value) {
    $numBigBlind.Value = $numSmallBlind.Value
  }
  if (([string]$heroCards["hero1"]).Trim().ToUpperInvariant() -eq "??" -and ([string]$heroCards["hero2"]).Trim().ToUpperInvariant() -eq "??") {
    Reset-TableStateToCurrentStakes
  }
})
$numBigBlind.Add_ValueChanged({
  if ($numSmallBlind.Value -gt $numBigBlind.Value) {
    $numSmallBlind.Value = $numBigBlind.Value
  }
  if ($numBuyIn.Value -lt $numBigBlind.Value) {
    $numBuyIn.Value = $numBigBlind.Value
  }
  if (([string]$heroCards["hero1"]).Trim().ToUpperInvariant() -eq "??" -and ([string]$heroCards["hero2"]).Trim().ToUpperInvariant() -eq "??") {
    Reset-TableStateToCurrentStakes
  }
})
$numBuyIn.Add_ValueChanged({
  if ($numBuyIn.Value -lt $numBigBlind.Value) {
    $numBuyIn.Value = $numBigBlind.Value
  }
  if (([string]$heroCards["hero1"]).Trim().ToUpperInvariant() -eq "??" -and ([string]$heroCards["hero2"]).Trim().ToUpperInvariant() -eq "??") {
    Reset-TableStateToCurrentStakes
  }
})

$txtAdviceDetail = New-Object System.Windows.Forms.TextBox
$txtAdviceDetail.Location = New-Object System.Drawing.Point(18, 576)
$txtAdviceDetail.Size = New-Object System.Drawing.Size(210, 120)
$txtAdviceDetail.Multiline = $true
$txtAdviceDetail.ReadOnly = $true
$txtAdviceDetail.ScrollBars = "Vertical"
$txtAdviceDetail.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtAdviceDetail.BackColor = [System.Drawing.Color]::FromArgb(14, 18, 23)
$txtAdviceDetail.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
$txtAdviceDetail.Text = $adviceSecondary
$advicePanel.Controls.Add($txtAdviceDetail)

foreach ($manualActionButton in @($btnCheck, $btnFold, $btnCall, $btnRaise, $btnRaise25, $btnRaise50, $btnRaise100, $btnAllIn)) {
  $advicePanel.Controls.Add($manualActionButton)
}
foreach ($raiseControl in @($lblRaiseAmountTitle, $trkRaiseAmount, $numRaiseAmount, $lblRaiseAmountValue)) {
  $advicePanel.Controls.Add($raiseControl)
}

Set-VillainCardsVisibility -Visible:$false
Set-VillainMode -Mode "Scripted"
Set-VillainStyle -Style "Tight"

$latestLabel = New-Object System.Windows.Forms.Label
$latestLabel.Text = "Latest OCR Text"
$latestLabel.ForeColor = [System.Drawing.Color]::White
$latestLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$latestLabel.Location = New-Object System.Drawing.Point(20, 274)
$latestLabel.AutoSize = $true
$form.Controls.Add($latestLabel)

$txtLatest = New-Object System.Windows.Forms.TextBox
$txtLatest.Location = New-Object System.Drawing.Point(20, 298)
$txtLatest.Size = New-Object System.Drawing.Size(780, 150)
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
$logLabel.Location = New-Object System.Drawing.Point(20, 460)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(20, 484)
$logBox.Size = New-Object System.Drawing.Size(780, 210)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(14, 18, 23)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 245)
$logBox.DetectUrls = $false
$logBox.WordWrap = $false
$logBox.HideSelection = $false
$form.Controls.Add($logBox)

function Update-MainLayout {
  $margin = 20
  $gap = 10
  $clientWidth = [Math]::Max([int]$form.ClientSize.Width, 1120)
  $clientHeight = [Math]::Max([int]$form.ClientSize.Height, 720)
  $adviceWidth = [Math]::Min(360, [Math]::Max(300, [int]([double]$clientWidth * 0.24)))
  $adviceLeft = [int]($clientWidth - $adviceWidth - $margin)
  $leftRight = [int]($adviceLeft - $gap)
  $leftWidth = [Math]::Max(620, [int]($leftRight - $margin))

  $status.Size = New-Object System.Drawing.Size($leftWidth, 18)
  $engineStatusLine.Size = New-Object System.Drawing.Size($leftWidth, 18)
  $regionLabel.Size = New-Object System.Drawing.Size($leftWidth, 20)
  $cardStatusLabel.Size = New-Object System.Drawing.Size($leftWidth, 18)

  $row1Y = 136
  $x = $margin
  $btnPick.Location = New-Object System.Drawing.Point($x, $row1Y)
  $x += [int]$btnPick.Width + $gap
  $btnOnce.Location = New-Object System.Drawing.Point($x, $row1Y)
  $x += [int]$btnOnce.Width + $gap
  $btnRandomCard.Location = New-Object System.Drawing.Point($x, $row1Y)
  $btnRestart.Location = New-Object System.Drawing.Point(($leftRight - [int]$btnRestart.Width), $row1Y)
  $btnNewHand.Location = New-Object System.Drawing.Point(($btnRestart.Left - $gap - [int]$btnNewHand.Width), $row1Y)
  $btnRunEngine.Location = New-Object System.Drawing.Point(($btnNewHand.Left - $gap - [int]$btnRunEngine.Width), $row1Y)

  $row2Y = 176
  $lblCaptureMode.Location = New-Object System.Drawing.Point($margin, ($row2Y + 4))
  $cmbCaptureMode.Location = New-Object System.Drawing.Point(88, $row2Y)
  $cmbCaptureMode.Size = New-Object System.Drawing.Size(190, 24)
  $lblTarget.Location = New-Object System.Drawing.Point(292, ($row2Y + 4))
  $cmbTarget.Location = New-Object System.Drawing.Point(362, $row2Y)
  $cmbTarget.Size = New-Object System.Drawing.Size(150, 24)
  $lblAuto.Location = New-Object System.Drawing.Point(526, ($row2Y + 4))
  $numInterval.Location = New-Object System.Drawing.Point(662, $row2Y)
  $btnAutoStart.Location = New-Object System.Drawing.Point(742, ($row2Y - 1))
  $btnAutoStop.Location = New-Object System.Drawing.Point(($btnAutoStart.Right + $gap), ($row2Y - 1))

  $row3Y = 212
  $btnTargets.Location = New-Object System.Drawing.Point($margin, $row3Y)
  $btnResetRois.Location = New-Object System.Drawing.Point(($btnTargets.Right + $gap), $row3Y)
  $btnSetHeroes.Location = New-Object System.Drawing.Point(($btnResetRois.Right + $gap), $row3Y)
  $lblEngineProfile.Location = New-Object System.Drawing.Point(($btnSetHeroes.Right + 18), ($row3Y + 4))
  $cmbEngineProfile.Location = New-Object System.Drawing.Point(($lblEngineProfile.Right + 8), ($row3Y + 1))

  $quickRowY = 248
  $quickButtons = @($btnRunFlop1, $btnRunFlop2, $btnRunFlop3, $btnRunTurn, $btnRunRiver)
  $lblQuick.Visible = -not $quickSingleSlotHidden
  foreach ($ctl in $quickButtons) {
    $ctl.Visible = -not $quickSingleSlotHidden
  }
  $btnQuickToggle.Text = $(if ($quickSingleSlotHidden) { "Show Quick Tests" } else { "Hide Quick Tests" })
  $quickCursorX = $margin
  if (-not $quickSingleSlotHidden) {
    $lblQuick.Location = New-Object System.Drawing.Point($quickCursorX, ($quickRowY + 4))
    $quickCursorX += 140
  }
  $btnQuickToggle.Location = New-Object System.Drawing.Point($quickCursorX, $quickRowY)
  $quickCursorX += [int]$btnQuickToggle.Width + $gap
  if (-not $quickSingleSlotHidden) {
    foreach ($ctl in $quickButtons) {
      $ctl.Location = New-Object System.Drawing.Point($quickCursorX, $quickRowY)
      $quickCursorX += [int]$ctl.Width + 6
    }
  }

  $batchRowY = $(if ($quickSingleSlotHidden) { 248 } else { 282 })
  $btnRunFlopSet.Location = New-Object System.Drawing.Point($margin, $batchRowY)
  $btnRunHero.Location = New-Object System.Drawing.Point(($btnRunFlopSet.Right + $gap), $batchRowY)

  $hintY = $batchRowY + 36
  $hint.Location = New-Object System.Drawing.Point($margin, $hintY)
  $hint.Size = New-Object System.Drawing.Size($leftWidth, 18)

  $latestLabelY = $hintY + 26
  $latestLabel.Location = New-Object System.Drawing.Point($margin, $latestLabelY)
  $latestY = $latestLabelY + 24
  $logLabelY = [int]($clientHeight - 290)
  $latestHeight = [Math]::Max(130, [int]($logLabelY - $latestY - 12))
  $txtLatest.Location = New-Object System.Drawing.Point($margin, $latestY)
  $txtLatest.Size = New-Object System.Drawing.Size($leftWidth, $latestHeight)

  $logLabel.Location = New-Object System.Drawing.Point($margin, $logLabelY)
  $logY = $logLabelY + 24
  $logHeight = [Math]::Max(170, [int]($clientHeight - $logY - 26))
  $logBox.Location = New-Object System.Drawing.Point($margin, $logY)
  $logBox.Size = New-Object System.Drawing.Size($leftWidth, $logHeight)

  $adviceTop = 84
  $advicePanel.Location = New-Object System.Drawing.Point($adviceLeft, $adviceTop)
  $advicePanel.Size = New-Object System.Drawing.Size($adviceWidth, [Math]::Max(420, [int]($clientHeight - $adviceTop - 14)))
  $innerWidth = [Math]::Max(180, [int]($advicePanel.ClientSize.Width - 36))
  $adviceSub.Size = New-Object System.Drawing.Size($innerWidth, 34)
  $lblAdviceValue.Size = New-Object System.Drawing.Size($innerWidth, 56)
  $adviceDivider.Size = New-Object System.Drawing.Size($innerWidth, 2)

  $manualActionButtons = @($btnCheck, $btnFold)
  $manualActionButtonWidth = [Math]::Max(84, [int](($innerWidth - $gap) / 2))
  foreach ($btn in $manualActionButtons) {
    $btn.Size = New-Object System.Drawing.Size($manualActionButtonWidth, 28)
  }
  $btnCheck.Location = New-Object System.Drawing.Point(18, 176)
  $btnFold.Location = New-Object System.Drawing.Point(($btnCheck.Right + $gap), 176)
  $btnCall.Visible = $false

  $raiseAllInOnly = ([string]$script:raiseAllInButtonToken).Trim().ToUpperInvariant() -eq "ALL IN"
  $raiseButtonWidth = [Math]::Max(84, [int](($innerWidth - $gap) / 2))
  foreach ($raiseBtn in @($btnRaise, $btnRaise25, $btnRaise50, $btnRaise100)) {
    if ($null -eq $raiseBtn -or $raiseBtn.IsDisposed) { continue }
    $raiseBtn.Size = New-Object System.Drawing.Size($raiseButtonWidth, 28)
  }

  if ($raiseAllInOnly) {
    $btnRaise.Visible = $true
    $btnRaise.Size = New-Object System.Drawing.Size($innerWidth, 34)
    $btnRaise.Location = New-Object System.Drawing.Point(18, 214)
    $btnRaise25.Visible = $false
    $btnRaise50.Visible = $false
    $btnRaise100.Visible = $false
    $lblRaiseAmountTitle.Visible = $false
    $trkRaiseAmount.Visible = $false
    $numRaiseAmount.Visible = $false
    $lblRaiseAmountValue.Visible = $false
    $btnAllIn.Visible = $false
    $stakesTopY = [int]($btnRaise.Bottom + 12)
  }
  else {
    $btnRaise.Visible = $true
    $btnRaise25.Visible = $true
    $btnRaise50.Visible = $true
    $btnRaise100.Visible = $true
    $lblRaiseAmountTitle.Visible = $true
    $trkRaiseAmount.Visible = $true
    $numRaiseAmount.Visible = $true
    $lblRaiseAmountValue.Visible = $true

    $btnRaise.Location = New-Object System.Drawing.Point(18, 214)
    $btnRaise25.Location = New-Object System.Drawing.Point(($btnRaise.Right + $gap), 214)
    $btnRaise50.Location = New-Object System.Drawing.Point(18, 246)
    $btnRaise100.Location = New-Object System.Drawing.Point(($btnRaise50.Right + $gap), 246)
    $lblRaiseAmountTitle.Location = New-Object System.Drawing.Point(18, 276)
    $numRaiseWidth = [Math]::Max(72, [int]($innerWidth * 0.30))
    $numRaiseAmount.Location = New-Object System.Drawing.Point(([int](18 + $innerWidth - $numRaiseWidth)), 294)
    $numRaiseAmount.Size = New-Object System.Drawing.Size($numRaiseWidth, 24)
    $trackWidth = [Math]::Max(96, [int]($numRaiseAmount.Left - 18 - 6))
    $trkRaiseAmount.Location = New-Object System.Drawing.Point(18, 294)
    $trkRaiseAmount.Size = New-Object System.Drawing.Size($trackWidth, 30)
    $lblRaiseAmountValue.Location = New-Object System.Drawing.Point(18, 322)
    $lblRaiseAmountValue.Size = New-Object System.Drawing.Size($innerWidth, 20)

    $btnAllIn.Visible = $true
    $btnAllIn.Text = "ALL IN"
    $btnAllIn.BackColor = [System.Drawing.Color]::FromArgb(168, 38, 38)
    $btnAllIn.Location = New-Object System.Drawing.Point(18, 346)
    $btnAllIn.Size = New-Object System.Drawing.Size($innerWidth, 24)
    $stakesTopY = [int]($btnAllIn.Bottom + 10)
  }

  $stakesTitle.Location = New-Object System.Drawing.Point(18, $stakesTopY)
  $lblSmallBlind.Location = New-Object System.Drawing.Point(18, ($stakesTopY + 24))
  $numSmallBlind.Location = New-Object System.Drawing.Point(42, ($stakesTopY + 20))
  $stakesControlWidth = [Math]::Max(56, [int](($innerWidth - 70) / 2))
  $numSmallBlind.Size = New-Object System.Drawing.Size($stakesControlWidth, 24)
  $lblBigBlind.Location = New-Object System.Drawing.Point(($numSmallBlind.Right + 12), ($stakesTopY + 24))
  $numBigBlind.Location = New-Object System.Drawing.Point(($lblBigBlind.Right + 6), ($stakesTopY + 20))
  $numBigBlind.Size = New-Object System.Drawing.Size([Math]::Max(56, [int]($innerWidth - ($numBigBlind.Left - 18))), 24)
  $lblBuyIn.Location = New-Object System.Drawing.Point(18, ($stakesTopY + 52))
  $numBuyIn.Location = New-Object System.Drawing.Point(68, ($stakesTopY + 48))
  $numBuyIn.Size = New-Object System.Drawing.Size([Math]::Max(96, [int]($innerWidth - 50)), 24)

  $stateTopY = $stakesTopY + 80
  $lblCurrentPotTitle.Location = New-Object System.Drawing.Point(18, $stateTopY)
  $lblCurrentPotValue.Location = New-Object System.Drawing.Point(18, ($stateTopY + 18))
  $lblCurrentPotValue.Size = New-Object System.Drawing.Size($innerWidth, 20)
  $lblCurrentChipsTitle.Location = New-Object System.Drawing.Point(18, ($stateTopY + 40))
  $lblCurrentChipsValue.Location = New-Object System.Drawing.Point(18, ($stateTopY + 58))
  $lblCurrentChipsValue.Size = New-Object System.Drawing.Size($innerWidth, 20)
  $lblCurrentVillainChipsTitle.Location = New-Object System.Drawing.Point(18, ($stateTopY + 80))
  $lblCurrentVillainChipsValue.Location = New-Object System.Drawing.Point(18, ($stateTopY + 98))
  $lblCurrentVillainChipsValue.Size = New-Object System.Drawing.Size($innerWidth, 20)
  $lblHeroPositionTitle.Location = New-Object System.Drawing.Point(18, ($stateTopY + 120))
  $lblHeroPositionValue.Location = New-Object System.Drawing.Point(18, ($stateTopY + 138))
  $lblHeroPositionValue.Size = New-Object System.Drawing.Size($innerWidth, 20)
  $lblTableStatusTitle.Location = New-Object System.Drawing.Point(18, ($stateTopY + 160))
  $lblTableStatusValue.Location = New-Object System.Drawing.Point(18, ($stateTopY + 178))
  $lblTableStatusValue.Size = New-Object System.Drawing.Size($innerWidth, 34)
  $btnToggleVillainCards.Location = New-Object System.Drawing.Point(18, ($stateTopY + 216))
  $btnToggleVillainCards.Size = New-Object System.Drawing.Size($innerWidth, 28)
  $lblVillainCardsValue.Location = New-Object System.Drawing.Point(18, ($stateTopY + 248))
  $lblVillainCardsValue.Size = New-Object System.Drawing.Size($innerWidth, 20)
  $lblVillainMode.Location = New-Object System.Drawing.Point(18, ($stateTopY + 274))
  $cmbVillainMode.Location = New-Object System.Drawing.Point(18, ($stateTopY + 294))
  $cmbVillainMode.Size = New-Object System.Drawing.Size($innerWidth, 24)
  $lblVillainStyle.Location = New-Object System.Drawing.Point(18, ($stateTopY + 324))
  $cmbVillainStyle.Location = New-Object System.Drawing.Point(18, ($stateTopY + 344))
  $cmbVillainStyle.Size = New-Object System.Drawing.Size($innerWidth, 24)
  $btnVillainActionMenu.Location = New-Object System.Drawing.Point(18, ($stateTopY + 376))
  $btnVillainActionMenu.Size = New-Object System.Drawing.Size($innerWidth, 28)

  $settleButtonWidth = [Math]::Max(84, [int](($innerWidth - $gap) / 2))
  $btnHeroWinsPot.Location = New-Object System.Drawing.Point(18, ($stateTopY + 410))
  $btnHeroWinsPot.Size = New-Object System.Drawing.Size($settleButtonWidth, 26)
  $btnVillainWinsPot.Location = New-Object System.Drawing.Point(($btnHeroWinsPot.Right + $gap), ($stateTopY + 410))
  $btnVillainWinsPot.Size = New-Object System.Drawing.Size($settleButtonWidth, 26)

  $detailTopY = [int]($btnVillainActionMenu.Bottom + 12)
  $availableDetailHeight = [int]($advicePanel.ClientSize.Height - ($detailTopY + 10))
  $canShowDetail = ($availableDetailHeight -ge 100)
  $adviceMetaTitle.Visible = $canShowDetail
  $txtAdviceDetail.Visible = $canShowDetail
  if ($canShowDetail) {
    $adviceMetaTitle.Location = New-Object System.Drawing.Point(18, $detailTopY)
    $txtAdviceDetail.Location = New-Object System.Drawing.Point(18, ($detailTopY + 24))
    $txtAdviceDetail.Size = New-Object System.Drawing.Size($innerWidth, [Math]::Max(80, [int]($availableDetailHeight - 28)))
  }
  $contentBottom = if ($canShowDetail) { [int]($txtAdviceDetail.Bottom + 12) } else { [int]($btnVillainActionMenu.Bottom + 14) }
  $advicePanel.AutoScrollMinSize = New-Object System.Drawing.Size(0, $contentBottom)
}

function Apply-UiPolish {
  $form.BackColor = [System.Drawing.Color]::FromArgb(16, 22, 30)
  $advicePanel.BackColor = [System.Drawing.Color]::FromArgb(24, 31, 41)
  $advicePanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $txtLatest.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $txtAdviceDetail.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

  $buttonList = @(
    $btnPick, $btnOnce, $btnRandomCard, $btnAutoStart, $btnAutoStop, $btnRunEngine, $btnNewHand, $btnRestart,
    $btnTargets, $btnResetRois, $btnSetHeroes, $btnQuickToggle, $btnRunFlop1, $btnRunFlop2, $btnRunFlop3,
    $btnRunTurn, $btnRunRiver, $btnRunFlopSet, $btnRunHero, $btnCheck, $btnFold, $btnRaise, $btnRaise25, $btnRaise50, $btnRaise100, $btnCall, $btnAllIn,
    $btnToggleVillainCards, $btnVillainActionMenu
  )
  foreach ($btn in @($buttonList)) {
    if ($null -eq $btn -or $btn.IsDisposed) { continue }
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(92, 112, 142)
    $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(62, 82, 112)
    $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(48, 66, 94)
    $btn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  }

  foreach ($input in @($cmbTarget, $cmbCaptureMode, $cmbEngineProfile, $cmbVillainMode, $cmbVillainStyle, $numSmallBlind, $numBigBlind, $numBuyIn, $numInterval, $numRaiseAmount)) {
    if ($null -eq $input -or $input.IsDisposed) { continue }
    $input.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $input.BackColor = [System.Drawing.Color]::FromArgb(235, 239, 246)
  }
  if ($null -ne $trkRaiseAmount -and -not $trkRaiseAmount.IsDisposed) {
    $trkRaiseAmount.BackColor = [System.Drawing.Color]::FromArgb(24, 31, 41)
    $trkRaiseAmount.TickStyle = [System.Windows.Forms.TickStyle]::None
  }
}

function Write-Log {
  param(
    [string]$Message,
    [string]$Type = "log",
    [hashtable]$Data = $null
  )
  function Get-LogVisualColor {
    param(
      [string]$LineText,
      [string]$LineType
    )
    $text = ([string]$LineText).ToUpperInvariant()
    $evt = ([string]$LineType).ToLowerInvariant()

    if ($text -match "\b(ERROR|FAILED|EXCEPTION|TIMEOUT)\b" -or $evt -in @("engine_job_failed", "engine_job_timeout")) {
      return [System.Drawing.Color]::FromArgb(255, 112, 112)
    }
    if ($text -match "\b(ALL IN|RAISE)\b" -or $evt -in @("manual_action_set", "villain_action_set", "street_raise_cap")) {
      return [System.Drawing.Color]::FromArgb(255, 132, 132)
    }
    if ($text -match "\b(FOLD)\b") {
      return [System.Drawing.Color]::FromArgb(188, 196, 205)
    }
    if ($text -match "\b(CHECK|CALL)\b") {
      return [System.Drawing.Color]::FromArgb(128, 232, 156)
    }
    if ($text -match "\b(WINS|AWARDED|SHOWDOWN)\b" -or $evt -eq "hand_settled") {
      return [System.Drawing.Color]::FromArgb(255, 230, 160)
    }
    return [System.Drawing.Color]::FromArgb(225, 235, 245)
  }

  function Write-StyledLogLine {
    param(
      [string]$LineText,
      [string]$LineType
    )
    if ($null -eq $logBox -or $logBox.IsDisposed) {
      return
    }
    $lineColor = Get-LogVisualColor -LineText $LineText -LineType $LineType
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $lineColor
    $logBox.SelectionFont = $logBox.Font
    $logBox.AppendText("$LineText`r`n")
    $logBox.SelectionColor = $logBox.ForeColor
    $logBox.SelectionFont = $logBox.Font
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.ScrollToCaret()
  }

  $stamp = (Get-Date).ToString("HH:mm:ss")
  $line = "[$stamp] $Message"
  Write-StyledLogLine -LineText $line -LineType $Type
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

function Set-AdviceState {
  param(
    [Parameter(Mandatory = $true)][string]$Primary,
    [string]$Secondary = ""
  )
  $script:advicePrimary = ([string]$Primary).Trim().ToUpperInvariant()
  if (-not $script:advicePrimary) {
    $script:advicePrimary = "WAIT"
  }
  $script:adviceSecondary = ([string]$Secondary).Trim()
  if (-not $script:adviceSecondary) {
    $script:adviceSecondary = "No actionable advice yet."
  }
  $primaryColor = Get-AdvicePrimaryColor -Primary $script:advicePrimary
  if ($null -ne $lblAdviceValue) {
    $lblAdviceValue.Text = $script:advicePrimary
    $lblAdviceValue.ForeColor = $primaryColor
  }
  if ($null -ne $txtAdviceDetail) {
    $txtAdviceDetail.Text = $script:adviceSecondary
  }
  if ($null -ne $adviceOverlayValueLabel) {
    $adviceOverlayValueLabel.Text = $script:advicePrimary
    $adviceOverlayValueLabel.ForeColor = $primaryColor
  }
  if ($null -ne $adviceOverlayTitleLabel) {
    $adviceOverlayTitleLabel.Text = (Get-CompactOverlaySecondaryText -Primary $script:advicePrimary -Secondary $script:adviceSecondary)
  }
}

function Get-CompactOverlaySecondaryText {
  param(
    [string]$Primary,
    [string]$Secondary
  )
  $primaryText = ([string]$Primary).Trim().ToUpperInvariant()
  $text = ([string]$Secondary).Trim()
  if (-not $text) {
    return "No actionable advice yet."
  }

  $isShowdown = ($primaryText -in @("HERO WINS", "VILLAIN WINS", "CHOP")) -or ($text -match "(?i)\bshowdown\b")
  if (-not $isShowdown) {
    if ($text.Length -gt 96) {
      return ($text.Substring(0, 93) + "...")
    }
    return $text
  }

  $potLine = ""
  $potMatch = [regex]::Match($text, "(?i)\bpot\s+(\d+)\s+awarded\b")
  if ($potMatch.Success) {
    $potLine = ("Pot +{0}" -f [string]$potMatch.Groups[1].Value)
  }
  $core = $text
  $core = $core -replace "(?i)^showdown:\s*", ""
  $core = $core -replace "(?i)\.\s*pot\s+\d+\s+awarded\.?\s*$", ""
  $core = $core -replace "(?i)\s+beats\s+", " > "
  $core = $core -replace "(?i)\s+with\s+", " w/ "
  $core = $core -replace "\s+", " "
  $core = $core.Trim(" ", ".", "|")
  if ($core.Length -gt 78) {
    $core = $core.Substring(0, 75) + "..."
  }
  if ($potLine) {
    return ("{0}`n{1}" -f $core, $potLine)
  }
  return $core
}

function Set-CheckCallButtonMode {
  param([Parameter(Mandatory = $true)][string]$ActionToken)

  $normalized = ([string]$ActionToken).Trim().ToUpperInvariant()
  if ($normalized -ne "CALL") {
    $normalized = "CHECK"
  }
  $script:checkCallButtonToken = $normalized
  if ($null -ne $script:btnCheck) {
    $script:btnCheck.Text = $(if ($normalized -eq "CALL") { "Call" } else { "Check" })
    $script:btnCheck.BackColor = $(if ($normalized -eq "CALL") {
      [System.Drawing.Color]::FromArgb(38, 120, 68)
    } else {
      [System.Drawing.Color]::FromArgb(40, 108, 88)
    })
  }
}

function Get-RecommendedRaiseBaseAmount {
  $stakes = Get-StakeSettings
  if ($script:lastRecommendedRaiseAmount -gt 0) {
    return [int]$script:lastRecommendedRaiseAmount
  }
  if ([int]$script:currentFacingBetAmount -gt 0) {
    return [int]([Math]::Max(([int]$script:currentFacingBetAmount + $stakes.big_blind), $stakes.big_blind))
  }
  return [int]([Math]::Max(($stakes.big_blind * 3), $stakes.big_blind))
}

function Update-HeroRaiseAmountDisplay {
  if ($null -eq $script:lblRaiseAmountValue -or $script:lblRaiseAmountValue.IsDisposed) {
    return
  }
  $value = 0
  if ($null -ne $script:numRaiseAmount -and -not $script:numRaiseAmount.IsDisposed) {
    try { $value = [int][decimal]$script:numRaiseAmount.Value } catch { $value = 0 }
  }
  $script:lblRaiseAmountValue.Text = ("Raise Chips: {0}" -f [int]([Math]::Max(0, $value)))
}

function Sync-HeroRaiseAmountControls {
  if (($null -eq $script:numRaiseAmount) -or $script:numRaiseAmount.IsDisposed -or ($null -eq $script:trkRaiseAmount) -or $script:trkRaiseAmount.IsDisposed) {
    return
  }
  if ($script:raiseAmountSyncBusy) {
    return
  }
  $script:raiseAmountSyncBusy = $true
  try {
    $maxAmount = [int]([Math]::Max(0, $script:currentHeroChips))
    $recommended = [int]([Math]::Max(0, (Get-RecommendedRaiseBaseAmount)))
    if ($recommended -gt $maxAmount) { $recommended = $maxAmount }

    if ($maxAmount -lt 1) {
      $script:numRaiseAmount.Minimum = 0
      $script:numRaiseAmount.Maximum = 0
      $script:numRaiseAmount.Value = 0
      $script:trkRaiseAmount.Minimum = 0
      $script:trkRaiseAmount.Maximum = 0
      $script:trkRaiseAmount.Value = 0
      Update-HeroRaiseAmountDisplay
      return
    }

    $script:numRaiseAmount.Minimum = 0
    $script:numRaiseAmount.Maximum = [decimal]$maxAmount
    $script:trkRaiseAmount.Minimum = 0
    $script:trkRaiseAmount.Maximum = $maxAmount

    $currentValue = 0
    try { $currentValue = [int][decimal]$script:numRaiseAmount.Value } catch { $currentValue = 0 }
    if ($currentValue -le 0) {
      $currentValue = $recommended
    }
    if ($currentValue -gt $maxAmount) { $currentValue = $maxAmount }
    if ($currentValue -lt 0) { $currentValue = 0 }

    $script:numRaiseAmount.Value = [decimal]$currentValue
    $script:trkRaiseAmount.Value = [int]$currentValue
    Update-HeroRaiseAmountDisplay
  }
  finally {
    $script:raiseAmountSyncBusy = $false
  }
}

function Get-HeroRaiseAmountFromControls {
  $maxAmount = [int]([Math]::Max(0, $script:currentHeroChips))
  if ($maxAmount -le 0) {
    return 0
  }
  $value = 0
  if ($null -ne $script:numRaiseAmount -and -not $script:numRaiseAmount.IsDisposed) {
    try { $value = [int][decimal]$script:numRaiseAmount.Value } catch { $value = 0 }
  }
  if ($value -le 0) {
    $value = [int]([Math]::Max(1, (Get-RecommendedRaiseBaseAmount)))
  }
  if ($value -gt $maxAmount) { $value = $maxAmount }
  if ($value -lt 0) { $value = 0 }
  return [int]$value
}

function Set-RaiseAllInButtonMode {
  param([Parameter(Mandatory = $true)][string]$ActionToken)

  $normalized = ([string]$ActionToken).Trim().ToUpperInvariant()
  if ($normalized -ne "ALL IN") {
    $normalized = "RAISE"
  }
  $script:raiseAllInButtonToken = $normalized
  $isAllInOnly = ($normalized -eq "ALL IN")
  $raiseButtonBackColor = $(if ($isAllInOnly) {
    [System.Drawing.Color]::FromArgb(180, 42, 42)
  } else {
    [System.Drawing.Color]::FromArgb(184, 112, 42)
  })

  if ($null -ne $script:btnRaise) {
    $script:btnRaise.Text = $(if ($isAllInOnly) { "All In" } else { "Default Raise" })
    $script:btnRaise.BackColor = $raiseButtonBackColor
    $script:btnRaise.Enabled = ([int]$script:currentHeroChips -gt 0)
  }
  foreach ($presetBtn in @($script:btnRaise25, $script:btnRaise50, $script:btnRaise100)) {
    if ($null -eq $presetBtn -or $presetBtn.IsDisposed) { continue }
    $presetBtn.Text = $(if ($isAllInOnly) { "All In" } else { [string]$presetBtn.Tag })
    $presetBtn.BackColor = $raiseButtonBackColor
    $presetBtn.Enabled = ([int]$script:currentHeroChips -gt 0)
  }
}

function Update-VillainActionControlState {
  if ($null -eq $script:btnVillainActionMenu) {
    return
  }
  $isManual = ([string]$script:villainMode -eq "Manual")
  $script:btnVillainActionMenu.Enabled = $isManual -and (-not $script:handResolved) -and ([int]$script:activeVillainCount -gt 0) -and ([int]$script:currentVillainChips -gt 0)
  $script:btnVillainActionMenu.Text = $(if ($isManual) { "Villain Action" } else { ("Villain: {0} ({1})" -f [string]$script:villainMode, [string]$script:villainStyle) })
}

function Update-CheckCallButtonModeFromState {
  $mode = if ([int]$script:currentFacingBetAmount -gt 0) { "CALL" } else { "CHECK" }
  Set-CheckCallButtonMode -ActionToken $mode
  $requiredRaiseAmount = [int](Get-RecommendedRaiseBaseAmount)
  $villainAllIn = (([int]$script:currentVillainChips -le 0) -and ([int]$script:currentFacingBetAmount -gt 0))
  $allInOnly = $villainAllIn -or ($requiredRaiseAmount -ge [int]$script:currentHeroChips)
  $raiseMode = if ($allInOnly) { "ALL IN" } else { "RAISE" }
  Set-RaiseAllInButtonMode -ActionToken $raiseMode

  $heroTurn = Test-IsHeroTurn
  $legalTokens = @()
  if ($heroTurn) {
    $legalTokens = @(Get-HeroLegalActionTokens)
  }
  $canCheckCall = $heroTurn -and (("CHECK" -in $legalTokens) -or ("CALL" -in $legalTokens))
  if ($null -ne $script:btnCheck) { $script:btnCheck.Enabled = [bool]$canCheckCall }
  if ($null -ne $script:btnCall) { $script:btnCall.Enabled = [bool]$canCheckCall }
  if ($null -ne $script:btnFold) { $script:btnFold.Enabled = [bool]($heroTurn -and ("FOLD" -in $legalTokens)) }
  $canRaiseAny = [bool]($heroTurn -and (("RAISE" -in $legalTokens) -or ("ALL IN" -in $legalTokens)))
  if ($null -ne $script:btnRaise) { $script:btnRaise.Enabled = $canRaiseAny }
  foreach ($presetBtn in @($script:btnRaise25, $script:btnRaise50, $script:btnRaise100)) {
    if ($null -eq $presetBtn -or $presetBtn.IsDisposed) { continue }
    $presetBtn.Enabled = $canRaiseAny
  }
  if ($null -ne $script:btnAllIn) { $script:btnAllIn.Enabled = [bool]($heroTurn -and ("ALL IN" -in $legalTokens)) }
  if ($null -ne $script:numRaiseAmount -and -not $script:numRaiseAmount.IsDisposed) {
    $script:numRaiseAmount.Enabled = $canRaiseAny
  }
  if ($null -ne $script:trkRaiseAmount -and -not $script:trkRaiseAmount.IsDisposed) {
    $script:trkRaiseAmount.Enabled = $canRaiseAny
  }
  Sync-HeroRaiseAmountControls
  Update-VillainActionControlState
}

function Get-CheckCallButtonModeFromWeightedRows {
  param([Parameter(Mandatory = $true)]$WeightedRows)

  foreach ($row in @($WeightedRows)) {
    if ($null -eq $row) {
      continue
    }
    $token = ([string]$row.token).Trim().ToLowerInvariant()
    if ($token -eq "call" -or $token -like "call:*") {
      return "CALL"
    }
  }
  return "CHECK"
}

function Get-AdvicePrimaryColor {
  param(
    [string]$Primary
  )
  $value = ([string]$Primary).Trim().ToUpperInvariant()
  if ($value -like "FOLD*") { return [System.Drawing.Color]::FromArgb(208, 214, 222) }
  if ($value -like "CALL*") { return [System.Drawing.Color]::FromArgb(120, 235, 150) }
  if ($value -like "CHECK*") { return [System.Drawing.Color]::FromArgb(120, 235, 150) }
  if ($value -like "BET*" -or $value -like "RAISE*") { return [System.Drawing.Color]::FromArgb(255, 128, 128) }
  if ($value -like "ALL IN*") { return [System.Drawing.Color]::FromArgb(255, 110, 110) }
  if ($value -eq "THINKING") { return [System.Drawing.Color]::FromArgb(255, 235, 160) }
  return [System.Drawing.Color]::FromArgb(255, 235, 160)
}

function Get-AmountFromActionToken {
  param([string]$Token)
  $tokenValue = ([string]$Token).Trim().ToLowerInvariant()
  if ($tokenValue -match "^(?:call|bet|raise):(-?\d+)$") {
    try {
      return [int]$matches[1]
    }
    catch {
      return 0
    }
  }
  return 0
}

function Normalize-AdviceTokenForCurrentHeroState {
  param([string]$Token)
  $tokenValue = ([string]$Token).Trim().ToLowerInvariant()
  if (-not $tokenValue) {
    return ""
  }
  $facingBetNow = ([int]$script:currentFacingBetAmount -gt 0)
  if ($facingBetNow) {
    if ($tokenValue -eq "check") {
      return "call"
    }
    return $tokenValue
  }
  if ($tokenValue -eq "call" -or $tokenValue -like "call:*") {
    return "check"
  }
  return $tokenValue
}

function Get-ActionTokenForSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Slot
  )
  switch (([string]$Slot).ToLowerInvariant()) {
    "check_btn" { return [string]$script:checkCallButtonToken }
    "fold_btn" { return "FOLD" }
    "call_btn" { return [string]$script:checkCallButtonToken }
    "bet_btn" { return [string]$script:raiseAllInButtonToken }
    "raise_btn" { return [string]$script:raiseAllInButtonToken }
    "allin_btn" { return [string]$script:raiseAllInButtonToken }
    default { return "" }
  }
}

function Get-ActionSlotOverlayText {
  param(
    [Parameter(Mandatory = $true)][string]$Slot
  )
  return (Get-ActionTokenForSlot -Slot $Slot)
}

function Prompt-ForChipAmount {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [int]$DefaultValue = 0,
    [int]$MaxValue = 0,
    [int]$BasePotAmount = 0
  )
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = $Title
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ShowInTaskbar = $false
  $showPotButtons = ([int]$BasePotAmount -gt 0)
  $dialog.ClientSize = $(if ($showPotButtons) {
    New-Object System.Drawing.Size(330, 176)
  } else {
    New-Object System.Drawing.Size(330, 136)
  })

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.Location = New-Object System.Drawing.Point(14, 14)
  $label.Size = New-Object System.Drawing.Size(300, 34)
  $dialog.Controls.Add($label)

  $numAmount = New-Object System.Windows.Forms.NumericUpDown
  $numAmount.Location = New-Object System.Drawing.Point(18, 56)
  $numAmount.Size = New-Object System.Drawing.Size(120, 26)
  $numAmount.Minimum = 0
  $numAmount.Maximum = [decimal]([Math]::Max(0, $MaxValue))
  $numAmount.Value = [decimal]([Math]::Min([Math]::Max(0, $DefaultValue), [Math]::Max(0, $MaxValue)))
  $numAmount.Font = New-Object System.Drawing.Font("Segoe UI", 10)
  $dialog.Controls.Add($numAmount)

  if ($showPotButtons) {
    $shortcutPercents = @(
      @{ label = "25% Pot"; factor = 0.25 },
      @{ label = "50% Pot"; factor = 0.50 },
      @{ label = "100% Pot"; factor = 1.00 }
    )
    $shortcutX = 18
    foreach ($shortcut in $shortcutPercents) {
      $btnShortcut = New-Object System.Windows.Forms.Button
      $btnShortcut.Text = [string]$shortcut.label
      $btnShortcut.Location = New-Object System.Drawing.Point($shortcutX, 92)
      $btnShortcut.Size = New-Object System.Drawing.Size(92, 26)
      $factor = [double]$shortcut.factor
      $btnShortcut.Add_Click({
        $targetAmount = [int][Math]::Round(([double]$BasePotAmount * $factor), 0, [System.MidpointRounding]::AwayFromZero)
        $bounded = [int]([Math]::Min([Math]::Max(0, $targetAmount), [Math]::Max(0, $MaxValue)))
        $numAmount.Value = [decimal]$bounded
      }.GetNewClosure())
      $dialog.Controls.Add($btnShortcut)
      $shortcutX += 100
    }
  }

  $btnOk = New-Object System.Windows.Forms.Button
  $btnOk.Text = "OK"
  $btnOk.Location = $(if ($showPotButtons) {
    New-Object System.Drawing.Point(156, 136)
  } else {
    New-Object System.Drawing.Point(156, 96)
  })
  $btnOk.Size = New-Object System.Drawing.Size(72, 28)
  $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dialog.Controls.Add($btnOk)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text = "Cancel"
  $btnCancel.Location = $(if ($showPotButtons) {
    New-Object System.Drawing.Point(238, 136)
  } else {
    New-Object System.Drawing.Point(238, 96)
  })
  $btnCancel.Size = New-Object System.Drawing.Size(72, 28)
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $dialog.Controls.Add($btnCancel)

  $dialog.AcceptButton = $btnOk
  $dialog.CancelButton = $btnCancel

  $result = $dialog.ShowDialog($form)
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    $dialog.Dispose()
    return $null
  }
  $value = [int][decimal]$numAmount.Value
  $dialog.Dispose()
  return $value
}

function Get-HeroLegalActionTokensForSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Slot
  )

  if (-not (Test-IsHeroTurn)) {
    return @()
  }

  $slotKey = ([string]$Slot).ToLowerInvariant()
  switch ($slotKey) {
    "check_btn" { return @([string]$script:checkCallButtonToken) }
    "call_btn" { return @([string]$script:checkCallButtonToken) }
    "fold_btn" { return @("FOLD") }
    "bet_btn" { $slotKey = "raise_btn" }
    "raise_btn" {
      if ([int]$script:currentHeroChips -le 0) {
        return @()
      }
      if ([string]$script:raiseAllInButtonToken -eq "ALL IN") {
        return @("ALL IN")
      }
      return @("RAISE", "ALL IN")
    }
    "allin_btn" {
      if ([int]$script:currentHeroChips -le 0) {
        return @()
      }
      if ([string]$script:raiseAllInButtonToken -eq "ALL IN") {
        return @("ALL IN")
      }
      return @("RAISE", "ALL IN")
    }
    default { return @() }
  }
}

function Get-HeroLegalActionTokens {
  if ($script:handResolved -or $script:heroFolded -or $script:villainFolded) {
    return @()
  }
  if ([int]$script:currentHeroChips -le 0) {
    return @()
  }
  if (-not (Test-IsHeroTurn)) {
    return @()
  }
  $tokens = New-Object System.Collections.Generic.List[string]
  $villainAllIn = ([int]$script:currentVillainChips -le 0)
  $checkCall = ([string]$script:checkCallButtonToken).Trim().ToUpperInvariant()
  if ($checkCall -notin @("CHECK", "CALL")) {
    $checkCall = "CHECK"
  }
  [void]$tokens.Add($checkCall)
  [void]$tokens.Add("FOLD")
  if (([int]$script:currentHeroChips -gt 0) -and (-not $villainAllIn)) {
    $raiseToken = ([string]$script:raiseAllInButtonToken).Trim().ToUpperInvariant()
    if ($raiseToken -eq "ALL IN") {
      [void]$tokens.Add("ALL IN")
    }
    else {
      [void]$tokens.Add("RAISE")
      [void]$tokens.Add("ALL IN")
    }
  }
  return @($tokens | Select-Object -Unique)
}

function Normalize-AdviceWeightedRowsToHeroLegal {
  param([Parameter(Mandatory = $true)]$WeightedRows)

  $rows = @($WeightedRows)
  $legalTokens = @(Get-HeroLegalActionTokens)
  if ($rows.Count -le 0 -or $legalTokens.Count -le 0) {
    return $rows
  }

  $tokenWeights = @{}
  foreach ($row in $rows) {
    if ($null -eq $row) { continue }
    $tokenRaw = ([string]$row.token).Trim().ToLowerInvariant()
    if (-not $tokenRaw) { continue }
    $weight = 0.0
    try { $weight = [double]$row.weight } catch { $weight = 0.0 }
    if ($weight -le 0.0) { continue }

    $mapped = ""
    if ($tokenRaw -eq "fold") {
      if ($legalTokens -contains "FOLD") { $mapped = "fold" }
    }
    elseif ($tokenRaw -eq "check") {
      if ($legalTokens -contains "CHECK") { $mapped = "check" }
      elseif ($legalTokens -contains "CALL") { $mapped = "call" }
    }
    elseif ($tokenRaw -eq "call" -or $tokenRaw -like "call:*") {
      if ($legalTokens -contains "CALL") { $mapped = $tokenRaw }
      elseif ($legalTokens -contains "CHECK") { $mapped = "check" }
    }
    elseif ($tokenRaw -eq "all in" -or $tokenRaw -eq "allin") {
      if ($legalTokens -contains "ALL IN") { $mapped = "all in" }
      elseif ($legalTokens -contains "RAISE") { $mapped = "raise" }
    }
    elseif ($tokenRaw -eq "bet" -or $tokenRaw -eq "raise" -or $tokenRaw -like "bet:*" -or $tokenRaw -like "raise:*") {
      if ($legalTokens -contains "RAISE") {
        if ($tokenRaw -like "bet:*" -or $tokenRaw -like "raise:*") {
          $amount = [int](Get-AmountFromActionToken -Token $tokenRaw)
          $mapped = $(if ($amount -gt 0) { ("raise:{0}" -f [int]$amount) } else { "raise" })
        }
        else {
          $mapped = "raise"
        }
      }
      elseif ($legalTokens -contains "ALL IN") {
        $mapped = "all in"
      }
    }

    if (-not $mapped) { continue }
    if (-not $tokenWeights.ContainsKey($mapped)) {
      $tokenWeights[$mapped] = 0.0
    }
    $tokenWeights[$mapped] = [double]$tokenWeights[$mapped] + [double]$weight
  }

  if ($tokenWeights.Count -le 0) {
    return @()
  }

  $resultRows = New-Object System.Collections.Generic.List[object]
  foreach ($key in $tokenWeights.Keys) {
    [void]$resultRows.Add([pscustomobject]@{
      token = [string]$key
      weight = [double]$tokenWeights[$key]
    })
  }
  # Keep sorting simple/stable to avoid dynamic binder mismatches in mixed PS runtimes.
  $sorted = @($resultRows | Sort-Object -Property token | Sort-Object -Property weight -Descending)
  return @($sorted)
}

function Convert-TextToChipAmount {
  param([string]$Text)
  $value = ([string]$Text).Trim()
  if (-not $value) {
    return $null
  }
  $matches = [regex]::Matches($value, "\d[\d,\.]*")
  if ($matches.Count -le 0) {
    return $null
  }
  $raw = [string]$matches[$matches.Count - 1].Value
  $digitsOnly = ($raw -replace "[^\d]", "")
  if (-not $digitsOnly) {
    return $null
  }
  $parsed = 0
  if ([int]::TryParse($digitsOnly, [ref]$parsed)) {
    return [int]$parsed
  }
  return $null
}

function Maybe-RefreshAdviceAfterActionStateChange {
  param(
    [string]$StageLabel = "manual_state"
  )
  if ($script:stateRefreshBusy) {
    return
  }
  $script:stateRefreshBusy = $true
  try {
  if ($script:heroFolded -or $script:villainFolded) {
    return
  }
  if ($script:handResolved) {
    return
  }
  if (-not (Get-HeroCardsReady)) {
    return
  }
  for ($pass = 0; $pass -lt 8; $pass++) {
    if (Try-ResolveAllInRunoutIfNoActions) {
      if ($script:handResolved) {
        return
      }
      continue
    }
    if (Try-AdvanceStreetIfRoundResolved) {
      if ($script:handResolved) {
        return
      }
      continue
    }
    if (Try-RunAutomaticVillainTurn) {
      if ($script:handResolved) {
        return
      }
      continue
    }
    break
  }

  if ($isBusy) {
    return
  }
  if (Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)) {
    [void](Queue-EngineSolveForBoard -BoardTokens @($lastBoardTokens) -StageLabel $StageLabel)
    return
  }
  Try-AutoSendHeroCardsToEngine
  }
  finally {
    $script:stateRefreshBusy = $false
  }
}

function Show-VillainActionMenu {
  if ($null -eq $script:btnVillainActionMenu) {
    return
  }
  if ([string]$script:villainMode -ne "Manual") {
    return
  }
  $legalTokens = @(Get-VillainLegalActionTokens)
  if ($legalTokens.Count -le 0) {
    return
  }
  if ($null -eq $script:villainActionMenu) {
    $script:villainActionMenu = New-Object System.Windows.Forms.ContextMenuStrip
  }
  $menu = $script:villainActionMenu
  $menu.Items.Clear()
  $title = New-Object System.Windows.Forms.ToolStripMenuItem
  $title.Text = "Villain Action"
  $title.Enabled = $false
  [void]$menu.Items.Add($title)
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  foreach ($token in @($legalTokens)) {
    $capturedToken = [string]$token
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = $capturedToken
    $item.Add_Click({
      param($sender, $e)
      Invoke-VillainActionSelection -ActionToken $capturedToken
    }.GetNewClosure())
    [void]$menu.Items.Add($item)
  }
  $menu.Show($script:btnVillainActionMenu, 0, $script:btnVillainActionMenu.Height)
}

function Award-PotToWinner {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("hero", "villain")][string]$Winner,
    [string]$Reason = "manual_settle",
    [string]$OutcomeSummary = ""
  )
  $award = [int]([Math]::Max(0, $script:currentPotAmount))
  if ($Winner -eq "hero") {
    $script:currentHeroChips = [int]$script:currentHeroChips + $award
  }
  else {
    $script:currentVillainChips = [int]$script:currentVillainChips + $award
  }
  $script:currentPotAmount = 0
  $script:handResolved = $true
  $script:activeVillainCount = 0
  Reset-StreetActionState
  $script:heroFolded = $false
  $script:villainFolded = $false
  $winnerLabel = if ($Winner -eq "hero") { "HERO WINS" } else { "VILLAIN WINS" }
  $script:adviceActionPrimary = $winnerLabel
  $summaryText = ([string]$OutcomeSummary).Trim()
  if (-not $summaryText) {
    $summaryText = ("Pot {0} awarded." -f [int]$award)
  }
  $script:adviceActionSecondary = $summaryText
  $script:adviceHasAction = $true
  Set-AdviceState -Primary $script:adviceActionPrimary -Secondary $script:adviceActionSecondary
  Update-TableStateDisplay
  Prepare-NextHandBackendState
  Write-Log ("Pot awarded to {0}: {1} chips." -f $Winner, [int]$award) -Type "hand_settled" -Data @{
    winner = $Winner
    amount = [int]$award
    reason = $Reason
    current_pot = [int]$script:currentPotAmount
    current_hero_chips = [int]$script:currentHeroChips
    current_villain_chips = [int]$script:currentVillainChips
  }
}

function Invoke-VillainActionSelection {
  param(
    [Parameter(Mandatory = $true)][string]$ActionToken,
    [int]$AmountOverride = -1,
    [switch]$AutoMode
  )
  $normalizedAction = ([string]$ActionToken).Trim().ToUpperInvariant()
  if (-not $normalizedAction) {
    return
  }
  if ($script:handResolved) {
    Write-Log "Villain action ignored: hand already resolved."
    return
  }

  $committedAmount = 0
  $stakes = Get-StakeSettings
  switch ($normalizedAction) {
    "CHECK" {
      $script:lastVillainAction = "CHECK"
      $script:villainFolded = $false
      $script:villainActedThisRound = $true
      Clear-FacingBetAmount
      Update-TableStateDisplay
    }
    "FOLD" {
      $script:lastVillainAction = "FOLD"
      $script:villainFolded = $true
      $script:villainActedThisRound = $true
      Clear-FacingBetAmount
      Set-AdviceState -Primary "VILLAIN FOLDS" -Secondary "Pot awarded to hero."
      Award-PotToWinner -Winner "hero" -Reason "villain_fold"
      return
    }
    "ALL IN" {
      $script:lastVillainAction = "ALL IN"
      $script:villainFolded = $false
      $script:villainActedThisRound = $true
      $committedAmount = [int]([Math]::Max(0, $script:currentVillainChips))
      if ($committedAmount -gt 0) {
        $committedAmount = Apply-VillainCommitmentToPot -Amount $committedAmount -SetAsFacingBet
        Register-StreetRaiseAction -Actor "villain" -Action "ALL IN" -Amount $committedAmount
      }
      else {
        Update-TableStateDisplay
      }
    }
    "CALL" {
      $script:lastVillainAction = "CALL"
      $script:villainFolded = $false
      $script:villainActedThisRound = $true
      $callGap = [int]([Math]::Max(0, ([int]$script:currentHeroStreetCommit - [int]$script:currentVillainStreetCommit)))
      if ($callGap -gt 0) {
        $committedAmount = Apply-VillainCommitmentToPot -Amount $callGap
      }
      Clear-FacingBetAmount
      Update-TableStateDisplay
    }
    { $_ -in @("BET", "RAISE") } {
      $script:villainFolded = $false
      $script:villainActedThisRound = $true
      $script:lastVillainAction = "RAISE"
      $defaultAmount = if ($normalizedAction -eq "RAISE" -and [int]$script:currentFacingBetAmount -gt 0) {
        [int]([Math]::Max(([int]$script:currentFacingBetAmount + $stakes.big_blind), $stakes.big_blind))
      }
      else {
        [int]([Math]::Max(($stakes.big_blind * 3), $stakes.big_blind))
      }
      $maxAmount = [int]([Math]::Max(0, $script:currentVillainChips))
      if ($AmountOverride -ge 0) {
        $committedAmount = [int]([Math]::Min($maxAmount, [Math]::Max(0, $AmountOverride)))
      }
      else {
        $enteredAmount = Prompt-ForChipAmount -Title ("Villain {0}" -f $normalizedAction) -Prompt ("Enter villain {0} amount (chips)." -f $normalizedAction.ToLowerInvariant()) -DefaultValue $defaultAmount -MaxValue $maxAmount -BasePotAmount $(if ($normalizedAction -eq "RAISE") { [int]$script:currentPotAmount } else { 0 })
        if ($null -eq $enteredAmount) {
          Write-Log ("Villain action canceled: {0}" -f $normalizedAction)
          return
        }
        $committedAmount = [int]$enteredAmount
      }
      if ($committedAmount -gt 0) {
        $committedAmount = Apply-VillainCommitmentToPot -Amount $committedAmount -SetAsFacingBet
        Register-StreetRaiseAction -Actor "villain" -Action "RAISE" -Amount $committedAmount
      }
      else {
        Update-TableStateDisplay
      }
    }
  }

  $villainCommitNow = [int]([Math]::Max(0, $script:currentVillainStreetCommit))
  $heroCommitNow = [int]([Math]::Max(0, $script:currentHeroStreetCommit))
  $heroToCallNow = [int]([Math]::Max(0, $script:currentFacingBetAmount))
  Write-Log ("Villain action selected: {0} (put_in={1}, villain_commit={2}, hero_commit={3}, hero_to_call={4}, pot={5})" -f `
    $normalizedAction, [int]$committedAmount, $villainCommitNow, $heroCommitNow, $heroToCallNow, [int]$script:currentPotAmount) -Type "villain_action_set" -Data @{
    action = $normalizedAction
    amount = [int]$committedAmount
    current_pot = [int]$script:currentPotAmount
    current_hero_chips = [int]$script:currentHeroChips
    current_villain_chips = [int]$script:currentVillainChips
    facing_bet = [int]$script:currentFacingBetAmount
    hero_commit = $heroCommitNow
    villain_commit = $villainCommitNow
    hero_to_call = $heroToCallNow
  }

  # Preflop safeguard: when villain acts and it immediately becomes hero's turn,
  # publish hero preflop advice directly here (independent of auto-send lock timing).
  if ((Get-CurrentStreetName) -eq "preflop" -and (Get-HeroCardsReady) -and (Test-IsHeroTurn)) {
    $null = Ensure-PreflopHeroAdvice
    Write-Log ("Preflop advice refreshed after villain action: facing_bet={0}, hero_commit={1}, villain_commit={2}." -f `
      [int]$script:currentFacingBetAmount, [int]$script:currentHeroStreetCommit, [int]$script:currentVillainStreetCommit) -Type "hero_preflop_refresh_post_villain" -Data @{
      hero1 = [string]$heroCards["hero1"]
      hero2 = [string]$heroCards["hero2"]
      facing_bet = [int]$script:currentFacingBetAmount
      hero_commit = [int]$script:currentHeroStreetCommit
      villain_commit = [int]$script:currentVillainStreetCommit
    }
  }
  Maybe-RefreshAdviceAfterActionStateChange -StageLabel "villain_action"
}

function Invoke-ManualRaisePreset {
  param(
    [ValidateSet("default", "pot25", "pot50", "pot100")]
    [string]$Preset = "default"
  )

  $targetAggro = ([string]$script:raiseAllInButtonToken).Trim().ToUpperInvariant()
  if ($targetAggro -eq "ALL IN") {
    Invoke-ManualActionSelection -ActionToken "ALL IN"
    return
  }

  $maxAmount = [int]([Math]::Max(0, $script:currentHeroChips))
  if ($maxAmount -le 0) {
    Write-Log "Manual raise ignored: hero has no chips."
    return
  }

  $raiseAmount = 0
  switch ($Preset) {
    "pot25" {
      $raiseAmount = [int][Math]::Round(([double]$script:currentPotAmount * 0.25), 0, [System.MidpointRounding]::AwayFromZero)
    }
    "pot50" {
      $raiseAmount = [int][Math]::Round(([double]$script:currentPotAmount * 0.50), 0, [System.MidpointRounding]::AwayFromZero)
    }
    "pot100" {
      $raiseAmount = [int][Math]::Round(([double]$script:currentPotAmount * 1.00), 0, [System.MidpointRounding]::AwayFromZero)
    }
    default {
      $raiseAmount = [int](Get-HeroRaiseAmountFromControls)
    }
  }

  if ($raiseAmount -lt 1) {
    $raiseAmount = [int]([Math]::Max(1, (Get-RecommendedRaiseBaseAmount)))
  }
  if ($raiseAmount -gt $maxAmount) {
    $raiseAmount = $maxAmount
  }

  if ($null -ne $script:numRaiseAmount -and -not $script:numRaiseAmount.IsDisposed) {
    try { $script:numRaiseAmount.Value = [decimal]$raiseAmount } catch {}
  }
  Sync-HeroRaiseAmountControls
  Invoke-ManualActionSelection -ActionToken "RAISE" -AmountOverride $raiseAmount
}

function Invoke-ManualActionSelection {
  param(
    [Parameter(Mandatory = $true)][string]$ActionToken,
    [int]$AmountOverride = -1
  )
  $normalizedAction = ([string]$ActionToken).Trim().ToUpperInvariant()
  if (-not $normalizedAction) {
    return
  }
  if ($normalizedAction -in @("CHECK", "CALL")) {
    $normalizedAction = ([string]$script:checkCallButtonToken).Trim().ToUpperInvariant()
  }
  elseif ($normalizedAction -in @("RAISE", "ALL IN")) {
    $targetAggro = ([string]$script:raiseAllInButtonToken).Trim().ToUpperInvariant()
    if ($normalizedAction -eq "RAISE" -and $targetAggro -eq "ALL IN") {
      $normalizedAction = "ALL IN"
    }
  }
  $legalTokens = @(Get-HeroLegalActionTokens)
  if (-not ($legalTokens -contains $normalizedAction)) {
    Write-Log ("Manual action ignored: illegal in current state ({0})." -f $normalizedAction)
    Update-CheckCallButtonModeFromState
    return
  }
  if ($script:handResolved) {
    Write-Log "Manual action ignored: hand already resolved."
    return
  }

  $committedAmount = 0
  if ($normalizedAction -eq "ALL IN") {
    $script:heroFolded = $false
    $script:heroActedThisRound = $true
    $committedAmount = [int]([Math]::Max(0, $script:currentHeroChips))
    if ($committedAmount -gt 0) {
      $committedAmount = Apply-HeroCommitmentToPot -Amount $committedAmount -ClearFacingBet
      Register-StreetRaiseAction -Actor "hero" -Action "ALL IN" -Amount $committedAmount
    }
  }
  elseif ($normalizedAction -in @("CALL", "RAISE")) {
    $script:heroFolded = $false
    $script:heroActedThisRound = $true
    $stakes = Get-StakeSettings
    $maxAmount = [int]([Math]::Max(0, $script:currentHeroChips))
    if ($normalizedAction -eq "CALL") {
      $committedAmount = if ([int]$script:currentFacingBetAmount -gt 0) {
        [int]$script:currentFacingBetAmount
      }
      elseif ($script:lastRecommendedCallAmount -gt 0) {
        [int]$script:lastRecommendedCallAmount
      }
      else {
        [int]$stakes.big_blind
      }
      $committedAmount = [int]([Math]::Min($maxAmount, [Math]::Max(0, $committedAmount)))
    }
    else {
      $defaultAmount = if ($script:lastRecommendedRaiseAmount -gt 0) {
        [int]$script:lastRecommendedRaiseAmount
      }
      elseif ([int]$script:currentFacingBetAmount -gt 0) {
        [int]([Math]::Max(([int]$script:currentFacingBetAmount + $stakes.big_blind), $stakes.big_blind))
      }
      else {
        [int]([Math]::Max(($stakes.big_blind * 3), $stakes.big_blind))
      }
      if ($AmountOverride -ge 0) {
        $enteredAmount = [int]([Math]::Min($maxAmount, [Math]::Max(0, $AmountOverride)))
      }
      else {
        $enteredAmount = Prompt-ForChipAmount -Title ("Use {0}" -f $normalizedAction) -Prompt ("Enter {0} amount (chips)." -f $normalizedAction.ToLowerInvariant()) -DefaultValue $defaultAmount -MaxValue $maxAmount -BasePotAmount ([int]$script:currentPotAmount)
        if ($null -eq $enteredAmount) {
          Write-Log ("Manual action canceled: {0}" -f $normalizedAction)
          return
        }
      }
      $committedAmount = [int]$enteredAmount
    }
    if ($committedAmount -gt 0) {
      $committedAmount = Apply-HeroCommitmentToPot -Amount $committedAmount -ClearFacingBet
      if ($normalizedAction -eq "RAISE") {
        Register-StreetRaiseAction -Actor "hero" -Action "RAISE" -Amount $committedAmount
      }
    }
  }
  elseif ($normalizedAction -eq "FOLD") {
    $script:heroFolded = $true
    $script:heroActedThisRound = $true
    Clear-FacingBetAmount
    Set-AdviceState -Primary "FOLD" -Secondary "Pot awarded to villain."
    Award-PotToWinner -Winner "villain" -Reason "hero_fold"
    return
  }
  else {
    $script:heroFolded = $false
    $script:heroActedThisRound = $true
  }
  $script:adviceActionPrimary = $normalizedAction
  $script:lastHeroAction = $normalizedAction
  if ($committedAmount -gt 0) {
    $script:adviceActionSecondary = ("Manual action override. Amount: {0}" -f [int]$committedAmount)
  }
  else {
    $script:adviceActionSecondary = "Manual action override."
  }
  $script:adviceHasAction = $true
  Set-AdviceState -Primary $script:adviceActionPrimary -Secondary $script:adviceActionSecondary
  Write-Log ("Manual action selected: {0}" -f $normalizedAction) -Type "manual_action_set" -Data @{
    action = $normalizedAction
    amount = [int]$committedAmount
    current_pot = [int]$script:currentPotAmount
    current_hero_chips = [int]$script:currentHeroChips
    current_villain_chips = [int]$script:currentVillainChips
  }
  Maybe-RefreshAdviceAfterActionStateChange -StageLabel "manual_action"
}

function Convert-AdviceActionTokenToLabel {
  param(
    [string]$Token
  )
  $tokenValue = ([string]$Token).Trim().ToLowerInvariant()
  if (-not $tokenValue) {
    return ""
  }
  if ($tokenValue -match "^(call|bet|raise):(-?\d+)$") {
    $verb = [string]$matches[1]
    if ($verb -eq "bet") { $verb = "raise" }
    return ("{0} {1}" -f $verb.ToUpperInvariant(), $matches[2])
  }
  if ($tokenValue -eq "bet") { return "RAISE" }
  return $tokenValue.ToUpperInvariant()
}

function Convert-ActionSummaryRowToToken {
  param(
    $Row
  )
  if ($null -eq $Row) {
    return ""
  }
  $actionName = ""
  if ($Row.PSObject.Properties.Name -contains "action" -and $Row.action) {
    $actionName = ([string]$Row.action).Trim().ToLowerInvariant()
  }
  if (-not $actionName) {
    return ""
  }
  if ($actionName -in @("call", "bet", "raise")) {
    $amount = 0
    if ($Row.PSObject.Properties.Name -contains "amount" -and $null -ne $Row.amount) {
      try { $amount = [int][Math]::Round([double]$Row.amount) } catch { $amount = 0 }
    }
    if ($amount -gt 0) {
      return ("{0}:{1}" -f $actionName, $amount)
    }
  }
  return $actionName
}

function Get-AdviceDecisionPrimary {
  param(
    [Parameter(Mandatory = $true)]$WeightedRows
  )

  $topToken = ""
  if ($WeightedRows.Count -gt 0) {
    $topToken = [string]$WeightedRows[0].token
  }
  $foldWeight = 0.0
  $callWeight = 0.0
  $checkWeight = 0.0
  $raiseWeight = 0.0
  $bestRaiseToken = ""
  $bestRaiseWeight = [double]::NegativeInfinity

  foreach ($row in @($WeightedRows)) {
    $token = ([string]$row.token).Trim().ToLowerInvariant()
    $weight = 0.0
    try { $weight = [double]$row.weight } catch { $weight = 0.0 }
    if ($token -eq "fold") {
      $foldWeight += $weight
      continue
    }
    if ($token -eq "call") {
      $callWeight += $weight
      continue
    }
    if ($token -eq "check") {
      $checkWeight += $weight
      continue
    }
    if ($token -like "bet:*" -or $token -like "raise:*" -or $token -eq "bet" -or $token -eq "raise") {
      $raiseWeight += $weight
      if (($bestRaiseToken -eq "") -or ($weight -gt $bestRaiseWeight)) {
        $bestRaiseToken = $token
        $bestRaiseWeight = $weight
      }
    }
  }

  if ($checkWeight -ge 0.95 -and $callWeight -le 0.05 -and $foldWeight -le 0.05 -and $raiseWeight -le 0.05) {
    return "CHECK"
  }
  if ($topToken -match "^call:\d+$") {
    return (Convert-AdviceActionTokenToLabel -Token $topToken)
  }
  if ($topToken -match "^(bet|raise):\d+$") {
    return (Convert-AdviceActionTokenToLabel -Token $topToken)
  }
  if ($callWeight -ge 0.85 -and $foldWeight -le 0.10 -and $raiseWeight -le 0.15) {
    return "CALL ANY"
  }
  if ($raiseWeight -ge $callWeight -and $raiseWeight -ge $foldWeight -and $raiseWeight -gt 0.20) {
    if ($bestRaiseToken) {
      return (Convert-AdviceActionTokenToLabel -Token $bestRaiseToken)
    }
    return "RAISE"
  }
  if ($foldWeight -ge $callWeight -and $foldWeight -ge $raiseWeight -and $foldWeight -gt 0.0) {
    return "FOLD"
  }
  if ($callWeight -gt 0.0) {
    return "CALL"
  }
  if ($checkWeight -gt 0.0) {
    return "CHECK"
  }
  return (Convert-AdviceActionTokenToLabel -Token $topToken)
}

function Get-CardRankStrength {
  param([Parameter(Mandatory = $true)][string]$Token)
  switch (([string]$Token).Substring(0, 1).ToUpperInvariant()) {
    "A" { return 14 }
    "K" { return 13 }
    "Q" { return 12 }
    "J" { return 11 }
    "T" { return 10 }
    "9" { return 9 }
    "8" { return 8 }
    "7" { return 7 }
    "6" { return 6 }
    "5" { return 5 }
    "4" { return 4 }
    "3" { return 3 }
    "2" { return 2 }
    default { return 0 }
  }
}

function Convert-HoleCardsToStructuralCombo {
  param([string[]]$Cards)
  if ($Cards.Count -ne 2) {
    return ""
  }
  $normalizedCards = @()
  foreach ($card in @($Cards)) {
    $token = Normalize-CardToken -Text ([string]$card)
    if (-not (Test-CardTokenStrict -Token $token)) {
      return ""
    }
    $normalizedCards += $token
  }
  $ordered = @($normalizedCards)
  if ($ordered.Count -ne 2) { return "" }
  $leftRank = Get-CardRankStrength -Token $ordered[0]
  $rightRank = Get-CardRankStrength -Token $ordered[1]
  if (($rightRank -gt $leftRank) -or (($rightRank -eq $leftRank) -and ([string]$ordered[1] -lt [string]$ordered[0]))) {
    $ordered = @($ordered[1], $ordered[0])
  }
  $rank1 = $ordered[0].Substring(0, 1).ToUpperInvariant()
  $rank2 = $ordered[1].Substring(0, 1).ToUpperInvariant()
  $suit1 = $ordered[0].Substring(1, 1).ToLowerInvariant()
  $suit2 = $ordered[1].Substring(1, 1).ToLowerInvariant()
  if ($rank1 -eq $rank2) {
    return ("{0}{1}" -f $rank1, $rank2)
  }
  if ($suit1 -eq $suit2) {
    return ("{0}{1}s" -f $rank1, $rank2)
  }
  return ("{0}{1}o" -f $rank1, $rank2)
}

function Build-PreflopHeuristicRootActions {
  param([Parameter(Mandatory = $true)][string[]]$HeroCards)

  if ($HeroCards.Count -ne 2) {
    return @()
  }
  $cardA = ([string]$HeroCards[0]).Trim().ToUpperInvariant()
  $cardB = ([string]$HeroCards[1]).Trim().ToUpperInvariant()
  if ((-not (Test-CardTokenStrict -Token $cardA)) -or (-not (Test-CardTokenStrict -Token $cardB))) {
    return @()
  }

  $rankA = Get-CardRankStrength -Token $cardA
  $rankB = Get-CardRankStrength -Token $cardB
  $highRank = [Math]::Max($rankA, $rankB)
  $lowRank = [Math]::Min($rankA, $rankB)
  $isPair = $rankA -eq $rankB
  $isSuited = $cardA.Substring(1, 1) -eq $cardB.Substring(1, 1)
  $gap = [Math]::Abs($rankA - $rankB) - 1
  if ($gap -lt 0) {
    $gap = 0
  }

  $strength = 0
  if ($isPair) {
    if ($highRank -ge 13) { $strength += 6 }
    elseif ($highRank -ge 11) { $strength += 5 }
    elseif ($highRank -ge 9) { $strength += 4 }
    elseif ($highRank -ge 7) { $strength += 3 }
    else { $strength += 2 }
  }
  else {
    if ($highRank -eq 14 -and $lowRank -ge 13) { $strength += 5 }
    elseif ($highRank -eq 14 -and $lowRank -ge 11) { $strength += 4 }
    elseif ($highRank -ge 13 -and $lowRank -ge 11) { $strength += 3 }
    elseif ($highRank -ge 11 -and $lowRank -ge 10) { $strength += 2 }
    elseif ($highRank -eq 14) { $strength += 2 }
    elseif ($highRank -ge 10) { $strength += 1 }
    if ($isSuited) { $strength += 1 }
    if ($gap -le 1) { $strength += 1 }
  }

  $foldWeight = 0.0
  $callWeight = 0.0
  $raiseWeight = 0.0
  if ($strength -ge 6) {
    $foldWeight = 0.00; $callWeight = 0.15; $raiseWeight = 0.85
  }
  elseif ($strength -ge 4) {
    $foldWeight = 0.05; $callWeight = 0.35; $raiseWeight = 0.60
  }
  elseif ($strength -ge 2) {
    $foldWeight = 0.20; $callWeight = 0.60; $raiseWeight = 0.20
  }
  elseif ($strength -ge 1) {
    $foldWeight = 0.50; $callWeight = 0.40; $raiseWeight = 0.10
  }
  else {
    $foldWeight = 0.70; $callWeight = 0.25; $raiseWeight = 0.05
  }

  $stakes = Get-StakeSettings
  $raiseAmount = [int]([Math]::Max(($stakes.big_blind * 3), $stakes.big_blind))
  if ([int]$script:currentFacingBetAmount -le 0) {
    return @(
      [pscustomobject]@{ action = "check"; avg_frequency = [double]($foldWeight + $callWeight) }
      [pscustomobject]@{ action = "raise"; amount = [int]$raiseAmount; avg_frequency = [double]$raiseWeight }
    )
  }

  return @(
    [pscustomobject]@{ action = "fold"; avg_frequency = [double]$foldWeight }
    [pscustomobject]@{ action = "call"; avg_frequency = [double]$callWeight }
    [pscustomobject]@{ action = "raise"; amount = [int]$raiseAmount; avg_frequency = [double]$raiseWeight }
  )
}

function Apply-PreflopHeuristicAdvice {
  param([Parameter(Mandatory = $true)][string[]]$HeroCards)

  $rootActions = @(Build-PreflopHeuristicRootActions -HeroCards $HeroCards)
  if ($rootActions.Count -eq 0) {
    return $false
  }
  $engineResult = [pscustomobject]@{
    selected_strategy = "preflop_heuristic"
    elapsed_sec = 0.0
    root_actions = @($rootActions)
  }
  Set-AdviceFromEngineResult -EngineResult $engineResult
  $txtLatest.Text = @(
    "run:   preflop_hero"
    ("hero1: {0}" -f [string]$HeroCards[0])
    ("hero2: {0}" -f [string]$HeroCards[1])
    "street: preflop"
    "source:preflop_heuristic"
  ) -join "`r`n"
  return $true
}

function Ensure-PreflopHeroAdvice {
  if ((Get-CurrentStreetName) -ne "preflop") {
    return $false
  }
  if (-not (Get-HeroCardsReady)) {
    return $false
  }
  if (-not (Test-IsHeroTurn)) {
    return $false
  }

  $applied = $false
  try {
    $applied = [bool](Apply-PreflopHeuristicAdvice -HeroCards @([string]$heroCards["hero1"], [string]$heroCards["hero2"]))
  }
  catch {
    $applied = $false
  }
  if ($applied) {
    return $true
  }

  $legal = @(Get-HeroLegalActionTokens)
  $fallbackPrimary = ""
  if ($legal -contains "CALL") { $fallbackPrimary = "CALL" }
  elseif ($legal -contains "CHECK") { $fallbackPrimary = "CHECK" }
  elseif ($legal -contains "FOLD") { $fallbackPrimary = "FOLD" }
  elseif ($legal -contains "RAISE") { $fallbackPrimary = "RAISE" }
  elseif ($legal -contains "ALL IN") { $fallbackPrimary = "ALL IN" }
  if (-not $fallbackPrimary) {
    return $false
  }
  $script:adviceActionPrimary = $fallbackPrimary
  $script:adviceActionSecondary = "Preflop fallback advice (heuristic unavailable)."
  $script:adviceHasAction = $true
  Set-AdviceState -Primary $script:adviceActionPrimary -Secondary $script:adviceActionSecondary
  Write-Log ("Preflop advice fallback applied: {0}" -f $fallbackPrimary) -Type "hero_preflop_fallback" -Data @{
    hero1 = [string]$heroCards["hero1"]
    hero2 = [string]$heroCards["hero2"]
    legal_actions = @($legal)
    facing_bet = [int]$script:currentFacingBetAmount
  }
  return $true
}

function Set-AdviceFromEngineResult {
  param(
    [Parameter(Mandatory = $true)]$EngineResult
  )

  try {
    $rawRows = @()
    if ($null -ne $EngineResult -and ($EngineResult.PSObject.Properties.Name -contains "root_actions") -and $null -ne $EngineResult.root_actions) {
      $rawRows = @($EngineResult.root_actions)
    }
    if ($rawRows.Count -eq 0) {
      return
    }

    $script:lastRecommendedCallAmount = 0
    $script:lastRecommendedRaiseAmount = 0
    $heroTurn = [bool](Test-IsHeroTurn)
    $legalTokens = @()
    if ($heroTurn) {
      $legalTokens = @(Get-HeroLegalActionTokens)
    }

    $tokenWeights = @{}
    foreach ($row in $rawRows) {
      if ($null -eq $row) { continue }
      $tokenRaw = [string](Convert-ActionSummaryRowToToken -Row $row)
      $tokenRaw = [string](Normalize-AdviceTokenForCurrentHeroState -Token $tokenRaw)
      if (-not $tokenRaw) { continue }

      $weight = 0.0
      if ($row.PSObject.Properties.Name -contains "avg_frequency" -and $null -ne $row.avg_frequency) {
        try { $weight = [double]$row.avg_frequency } catch { $weight = 0.0 }
      }
      elseif ($row.PSObject.Properties.Name -contains "frequency" -and $null -ne $row.frequency) {
        try { $weight = [double]$row.frequency } catch { $weight = 0.0 }
      }
      if ($weight -le 0.0) { continue }

      $token = ([string]$tokenRaw).Trim().ToLowerInvariant()
      if (-not $token) { continue }

      if ($heroTurn -and $legalTokens.Count -gt 0) {
        if ($token -eq "check" -and ($legalTokens -contains "CALL") -and (-not ($legalTokens -contains "CHECK"))) {
          $token = "call"
        }
        elseif (($token -eq "call" -or $token -like "call:*") -and ($legalTokens -contains "CHECK") -and (-not ($legalTokens -contains "CALL"))) {
          $token = "check"
        }
        elseif (($token -eq "bet" -or $token -eq "raise" -or $token -like "bet:*" -or $token -like "raise:*") -and (-not ($legalTokens -contains "RAISE")) -and ($legalTokens -contains "ALL IN")) {
          $token = "all in"
        }

        $tokenHead = $token
        if ($tokenHead -like "*:*") {
          $tokenHead = $tokenHead.Split(":")[0]
        }
        $tokenHead = $tokenHead.Trim().ToUpperInvariant()
        if (($tokenHead -eq "BET") -or ($tokenHead -eq "RAISE")) { $tokenHead = "RAISE" }
        if (($tokenHead -eq "ALLIN") -or ($tokenHead -eq "ALL IN")) { $tokenHead = "ALL IN" }
        if ($tokenHead -and (-not ($legalTokens -contains $tokenHead))) {
          continue
        }
      }

      if (-not $tokenWeights.ContainsKey($token)) {
        $tokenWeights[$token] = 0.0
      }
      $tokenWeights[$token] = [double]$tokenWeights[$token] + [double]$weight

      $amount = [int](Get-AmountFromActionToken -Token $token)
      if ($amount -gt 0) {
        if ($script:lastRecommendedCallAmount -le 0 -and $token -like "call:*") {
          $script:lastRecommendedCallAmount = [int]$amount
        }
        if ($script:lastRecommendedRaiseAmount -le 0 -and ($token -like "bet:*" -or $token -like "raise:*")) {
          $script:lastRecommendedRaiseAmount = [int]$amount
        }
      }
    }

    if ($tokenWeights.Count -eq 0 -and $heroTurn) {
      $fallbackToken = ""
      if ($legalTokens -contains "CALL") { $fallbackToken = "call" }
      elseif ($legalTokens -contains "CHECK") { $fallbackToken = "check" }
      elseif ($legalTokens -contains "FOLD") { $fallbackToken = "fold" }
      elseif ($legalTokens -contains "RAISE") { $fallbackToken = "raise" }
      elseif ($legalTokens -contains "ALL IN") { $fallbackToken = "all in" }
      if ($fallbackToken) {
        $tokenWeights[$fallbackToken] = 1.0
      }
    }
    if ($tokenWeights.Count -eq 0) {
      return
    }

    $rowsForDecision = New-Object System.Collections.Generic.List[object]
    foreach ($tokenKey in $tokenWeights.Keys) {
      [void]$rowsForDecision.Add([pscustomobject]@{
        token = [string]$tokenKey
        weight = [double]$tokenWeights[$tokenKey]
      })
    }

    $sortedRows = New-Object System.Collections.Generic.List[object]
    $rowCount = [int]$rowsForDecision.Count
    $usedIndexes = @{}
    for ($pick = 0; $pick -lt $rowCount; $pick++) {
      $bestIndex = -1
      $bestWeight = [double]::NegativeInfinity
      $bestToken = ""
      for ($i = 0; $i -lt $rowCount; $i++) {
        if ($usedIndexes.ContainsKey($i)) { continue }
        $candidate = $rowsForDecision[$i]
        if ($null -eq $candidate) { continue }
        $currentWeight = [double]$candidate.weight
        $currentToken = [string]$candidate.token
        if (($bestIndex -lt 0) -or ($currentWeight -gt $bestWeight) -or (($currentWeight -eq $bestWeight) -and ($currentToken -lt $bestToken))) {
          $bestIndex = $i
          $bestWeight = $currentWeight
          $bestToken = $currentToken
        }
      }
      if ($bestIndex -lt 0) { break }
      [void]$sortedRows.Add($rowsForDecision[$bestIndex])
      $usedIndexes[$bestIndex] = $true
    }

    Update-CheckCallButtonModeFromState

    $mixParts = New-Object System.Collections.Generic.List[string]
    $mixCount = [Math]::Min(2, $sortedRows.Count)
    for ($i = 0; $i -lt $mixCount; $i++) {
      $mixRow = $sortedRows[$i]
      [void]$mixParts.Add(("{0} {1:N2}" -f (Convert-AdviceActionTokenToLabel -Token ([string]$mixRow.token)), [double]$mixRow.weight))
    }

    $metaParts = New-Object System.Collections.Generic.List[string]
    if ($EngineResult.PSObject.Properties.Name -contains "selected_strategy" -and $EngineResult.selected_strategy) {
      [void]$metaParts.Add(("via {0}" -f [string]$EngineResult.selected_strategy))
    }
    if ($EngineResult.PSObject.Properties.Name -contains "elapsed_sec" -and $null -ne $EngineResult.elapsed_sec) {
      try { [void]$metaParts.Add(("{0:N2}s" -f [double]$EngineResult.elapsed_sec)) } catch {}
    }

    $sortedRowsArrayList = New-Object System.Collections.ArrayList
    foreach ($sortedRow in $sortedRows) {
      if ($null -eq $sortedRow) { continue }
      [void]$sortedRowsArrayList.Add([pscustomobject]@{
        token = [string]$sortedRow.token
        weight = [double]$sortedRow.weight
      })
    }
    $sortedRowsArray = $sortedRowsArrayList.ToArray()
    $script:adviceActionPrimary = Get-AdviceDecisionPrimary -WeightedRows $sortedRowsArray
    $script:lastAdviceWeightedRows = $sortedRowsArray

    $secondaryLines = New-Object System.Collections.Generic.List[string]
    if ($mixParts.Count -gt 0) { [void]$secondaryLines.Add(($mixParts -join " | ")) }
    if ($metaParts.Count -gt 0) { [void]$secondaryLines.Add(($metaParts -join " | ")) }
    $script:adviceActionSecondary = ($secondaryLines -join "`r`n")
    $script:adviceHasAction = $true
    Set-AdviceState -Primary $script:adviceActionPrimary -Secondary $script:adviceActionSecondary
  }
  catch {
    Write-Log ("Set-AdviceFromEngineResult internal error: {0}" -f $_.Exception.Message) -Type "advice_internal_error" -Data @{
      strategy = if ($EngineResult.PSObject.Properties.Name -contains "selected_strategy") { [string]$EngineResult.selected_strategy } else { "" }
    }
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("Set-AdviceFromEngineResult error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
    throw
  }
}

Set-AdviceState -Primary $advicePrimary -Secondary $adviceSecondary
Update-CheckCallButtonModeFromState

function New-AdviceOverlayForm {
  $overlay = New-Object System.Windows.Forms.Form
  $overlay.FormBorderStyle = "None"
  $overlay.StartPosition = "Manual"
  $overlay.ShowInTaskbar = $false
  $overlay.TopMost = $true
  $overlay.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $overlay.BackColor = [System.Drawing.Color]::FromArgb(16, 22, 30)
  $overlay.Opacity = 0.92
  $overlay.Size = New-Object System.Drawing.Size(320, 132)
  $overlay.Location = $(if ($null -ne $script:savedAdviceOverlayLocation) {
    New-Object System.Drawing.Point([int]$script:savedAdviceOverlayLocation.X, [int]$script:savedAdviceOverlayLocation.Y)
  } else {
    New-Object System.Drawing.Point(40, 40)
  })
  $overlay.Tag = [pscustomobject]@{
    down = $false
    offsetX = 0
    offsetY = 0
  }

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = "No actionable advice yet."
  $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 205, 220)
  $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $titleLabel.Location = New-Object System.Drawing.Point(12, 10)
  $titleLabel.Size = New-Object System.Drawing.Size(296, 42)
  $titleLabel.AutoEllipsis = $false
  $overlay.Controls.Add($titleLabel)

  $valueLabel = New-Object System.Windows.Forms.Label
  $valueLabel.Text = "WAIT"
  $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 235, 160)
  $valueLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 28, [System.Drawing.FontStyle]::Bold)
  $valueLabel.Location = New-Object System.Drawing.Point(10, 58)
  $valueLabel.Size = New-Object System.Drawing.Size(300, 64)
  $valueLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $overlay.Controls.Add($valueLabel)

  $dragHandlerDown = {
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $state = $overlay.Tag
      $state.down = $true
      $state.offsetX = [int]$e.X
      $state.offsetY = [int]$e.Y
    }
  }.GetNewClosure()
  $dragHandlerMove = {
    param($sender, $e)
    $state = $overlay.Tag
    if ($state.down) {
      $overlay.Left = [int]($overlay.Left + $e.X - $state.offsetX)
      $overlay.Top = [int]($overlay.Top + $e.Y - $state.offsetY)
    }
  }.GetNewClosure()
  $dragHandlerUp = {
    param($sender, $e)
    $state = $overlay.Tag
    $state.down = $false
    $script:savedAdviceOverlayLocation = New-Object System.Drawing.Point([int]$overlay.Left, [int]$overlay.Top)
    Save-RoiState
  }.GetNewClosure()

  foreach ($ctl in @($overlay, $titleLabel, $valueLabel)) {
    $ctl.Add_MouseDown($dragHandlerDown)
    $ctl.Add_MouseMove($dragHandlerMove)
    $ctl.Add_MouseUp($dragHandlerUp)
  }

  $script:adviceOverlayTitleLabel = $titleLabel
  $script:adviceOverlayValueLabel = $valueLabel
  Set-AdviceState -Primary $script:advicePrimary -Secondary $script:adviceSecondary
  return $overlay
}

function New-TableStateOverlayContextMenu {
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $itemNewHand = New-Object System.Windows.Forms.ToolStripMenuItem
  $itemNewHand.Text = "New Hand"
  $itemNewHand.Add_Click({
    param($sender, $e)
    Request-NewHandCycle
  }.GetNewClosure())
  [void]$menu.Items.Add($itemNewHand)
  return $menu
}

function New-TableStateOverlayForm {
  $overlay = New-Object System.Windows.Forms.Form
  $overlay.FormBorderStyle = "None"
  $overlay.StartPosition = "Manual"
  $overlay.ShowInTaskbar = $false
  $overlay.TopMost = $true
  $overlay.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $overlay.BackColor = [System.Drawing.Color]::FromArgb(16, 22, 30)
  $overlay.Opacity = 0.92
  $overlay.Size = New-Object System.Drawing.Size(240, 178)
  $overlay.Location = $(if ($null -ne $script:savedStateOverlayLocation) {
    New-Object System.Drawing.Point([int]$script:savedStateOverlayLocation.X, [int]$script:savedStateOverlayLocation.Y)
  } else {
    New-Object System.Drawing.Point(40, 182)
  })
  $overlay.Tag = [pscustomobject]@{
    down = $false
    offsetX = 0
    offsetY = 0
  }
  $overlay.ContextMenuStrip = New-TableStateOverlayContextMenu

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = "Table State"
  $titleLabel.ForeColor = [System.Drawing.Color]::White
  $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
  $titleLabel.Location = New-Object System.Drawing.Point(10, 8)
  $titleLabel.Size = New-Object System.Drawing.Size(200, 20)
  $overlay.Controls.Add($titleLabel)

  $potLabel = New-Object System.Windows.Forms.Label
  $potLabel.Text = "Pot: 0"
  $potLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
  $potLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
  $potLabel.Location = New-Object System.Drawing.Point(10, 34)
  $potLabel.Size = New-Object System.Drawing.Size(200, 20)
  $overlay.Controls.Add($potLabel)

  $chipsLabel = New-Object System.Windows.Forms.Label
  $chipsLabel.Text = "Hero Chips: 0"
  $chipsLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
  $chipsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
  $chipsLabel.Location = New-Object System.Drawing.Point(10, 56)
  $chipsLabel.Size = New-Object System.Drawing.Size(220, 20)
  $overlay.Controls.Add($chipsLabel)

  $villainChipsLabel = New-Object System.Windows.Forms.Label
  $villainChipsLabel.Text = "Villain Chips: 0"
  $villainChipsLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 240, 248)
  $villainChipsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
  $villainChipsLabel.Location = New-Object System.Drawing.Point(10, 78)
  $villainChipsLabel.Size = New-Object System.Drawing.Size(220, 20)
  $overlay.Controls.Add($villainChipsLabel)

  $positionLabel = New-Object System.Windows.Forms.Label
  $positionLabel.Text = "Position: Unknown"
  $positionLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
  $positionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $positionLabel.Location = New-Object System.Drawing.Point(10, 100)
  $positionLabel.Size = New-Object System.Drawing.Size(220, 20)
  $overlay.Controls.Add($positionLabel)

  $statusLabel = New-Object System.Windows.Forms.Label
  $statusLabel.Text = "STATUS: WAIT"
  $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 160)
  $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5, [System.Drawing.FontStyle]::Bold)
  $statusLabel.Location = New-Object System.Drawing.Point(10, 122)
  $statusLabel.Size = New-Object System.Drawing.Size(220, 20)
  $overlay.Controls.Add($statusLabel)

  $villainLabel = New-Object System.Windows.Forms.Label
  $villainLabel.Text = "Villain Cards: Hidden"
  $villainLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 235)
  $villainLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $villainLabel.Location = New-Object System.Drawing.Point(10, 144)
  $villainLabel.Size = New-Object System.Drawing.Size(220, 20)
  $overlay.Controls.Add($villainLabel)

  $dragHandlerDown = {
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $state = $overlay.Tag
      $state.down = $true
      $state.offsetX = [int]$e.X
      $state.offsetY = [int]$e.Y
    }
  }.GetNewClosure()
  $dragHandlerMove = {
    param($sender, $e)
    $state = $overlay.Tag
    if ($state.down) {
      $overlay.Left = [int]($overlay.Left + $e.X - $state.offsetX)
      $overlay.Top = [int]($overlay.Top + $e.Y - $state.offsetY)
    }
  }.GetNewClosure()
  $dragHandlerUp = {
    param($sender, $e)
    $state = $overlay.Tag
    $state.down = $false
    $script:savedStateOverlayLocation = New-Object System.Drawing.Point([int]$overlay.Left, [int]$overlay.Top)
    Save-RoiState
  }.GetNewClosure()

  foreach ($ctl in @($overlay, $titleLabel, $potLabel, $chipsLabel, $villainChipsLabel, $positionLabel, $statusLabel, $villainLabel)) {
    $ctl.ContextMenuStrip = $overlay.ContextMenuStrip
    $ctl.Add_MouseDown($dragHandlerDown)
    $ctl.Add_MouseMove($dragHandlerMove)
    $ctl.Add_MouseUp($dragHandlerUp)
  }

  $script:stateOverlayPotLabel = $potLabel
  $script:stateOverlayChipsLabel = $chipsLabel
  $script:stateOverlayVillainChipsLabel = $villainChipsLabel
  $script:stateOverlayPositionLabel = $positionLabel
  $script:stateOverlayStatusLabel = $statusLabel
  $script:stateOverlayVillainLabel = $villainLabel
  Update-TableStateDisplay
  return $overlay
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
          # Default fast_live quality tuning: allow a few more seconds for stronger decisions.
          if (-not $env:FAST_LIVE_BASELINE_TIMEOUT_SEC) { $env:FAST_LIVE_BASELINE_TIMEOUT_SEC = "6" }
          if (-not $env:FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC) { $env:FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC = "5" }
          if (-not $env:FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC) { $env:FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC = "4" }
          if (-not $env:FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC) { $env:FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC = "3" }
          if (-not $env:FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC) { $env:FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC = "6" }
          if (-not $env:FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC) { $env:FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC = "8" }
          if (-not $env:FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY) { $env:FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY = "0" }
          if (-not $env:FAST_LIVE_SPOT_MAX_ITERATIONS) { $env:FAST_LIVE_SPOT_MAX_ITERATIONS = "2" }
          if (-not $env:FAST_LIVE_SPOT_MAX_THREADS) { $env:FAST_LIVE_SPOT_MAX_THREADS = "4" }
          if (-not $env:FAST_LIVE_SPOT_MAX_RAISE_CAP) { $env:FAST_LIVE_SPOT_MAX_RAISE_CAP = "2" }
          Write-Log ("fast_live tuning: baseline(f/t/r)={0}/{1}/{2}s active_node={3}s active_node_flop={4}s lookup_only={5} iters={6} threads={7}" -f `
            [string]$env:FAST_LIVE_BASELINE_TIMEOUT_FLOP_SEC, `
            [string]$env:FAST_LIVE_BASELINE_TIMEOUT_TURN_SEC, `
            [string]$env:FAST_LIVE_BASELINE_TIMEOUT_RIVER_SEC, `
            [string]$env:FAST_LIVE_ACTIVE_NODE_TIMEOUT_SEC, `
            [string]$env:FAST_LIVE_ACTIVE_NODE_FLOP_TIMEOUT_SEC, `
            [string]$env:FAST_LIVE_ACTIVE_NODE_FLOP_LOOKUP_ONLY, `
            [string]$env:FAST_LIVE_SPOT_MAX_ITERATIONS, `
            [string]$env:FAST_LIVE_SPOT_MAX_THREADS) -Type "engine_fast_live_tuning"

          $env:NEURAL_BRAIN_ENABLED = if ($engineNeuralEnabled) { "1" } else { "0" }
          $env:NEURAL_BRAIN_MODE = [string]$engineNeuralMode
          $env:NEURAL_BRAIN_TIMEOUT_SEC = [string]$engineNeuralTimeoutSec
          $env:NEURAL_BRAIN_CFR_ITERS = [string]$engineNeuralCfrIters
          $env:NEURAL_BRAIN_CFR_SKIP_ITERS = [string]$engineNeuralCfrSkipIters
          if (-not [string]::IsNullOrWhiteSpace($engineNeuralPython)) {
            $env:NEURAL_BRAIN_PYTHON = [string]$engineNeuralPython
          }
          else {
            Remove-Item Env:\NEURAL_BRAIN_PYTHON -ErrorAction SilentlyContinue
          }
          Write-Log ("Neural bridge mode: enabled={0}, mode={1}, timeout={2}s, cfr={3}/{4}" -f `
            $(if ($engineNeuralEnabled) { "yes" } else { "no" }), $engineNeuralMode, [int]$engineNeuralTimeoutSec, [int]$engineNeuralCfrIters, [int]$engineNeuralCfrSkipIters) -Type "neural_bridge_config"
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
    Set-AdviceState -Primary "THINKING" -Secondary "Engine job in progress. Wait for the current calculation to finish."
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
    $engineText = ("Engine: idle (last {0})" -f [string]$engineLastResultSummary)
    if ($adviceHasAction -and $adviceActionPrimary) {
      Set-AdviceState -Primary $adviceActionPrimary -Secondary $adviceActionSecondary
    }
    else {
      Set-AdviceState -Primary "WAIT" -Secondary ("Engine idle. Last result: {0}" -f [string]$engineLastResultSummary)
    }
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
    $script:lastHeroStageKey = ""
    Rebuild-DeckShoeState
  }
  elseif ($Key -in $cardSlotOrder) {
    Update-LastBoardTokenFromSlot -Slot $Key -Token "??"
  }
  Set-SlotValueSource -Slot $Key -Source "none"
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
  $occupiedBy = Find-AssignedSlotForToken -Token $normalized -ExcludeSlot $Slot
  if ($occupiedBy) {
    Write-Log ("Manual card assign skipped for {0}: {1} is already assigned to {2}." -f $Slot, $normalized, $occupiedBy) -Type "manual_card_conflict" -Data @{
      slot = $Slot
      token = $normalized
      occupied_by = $occupiedBy
    }
    return
  }

  $queueManualBoardSolve = $false
  $manualStageLabel = "manual_single"

  if ($Slot -in $playerSlotOrder) {
    $heroCards[$Slot] = $normalized
    Set-SlotValueSource -Slot $Slot -Source "manual"
    Rebuild-DeckShoeState
    if (-not $suppressHeroAutoSend) {
      Try-AutoSendHeroCardsToEngine
    }
  }
  elseif ($Slot -in $cardSlotOrder) {
    if (-not (Get-HeroCardsReady)) {
      Write-Log ("Manual board assignment warning: hero cards are not accounted for yet. Set hero1/hero2 first when possible." ) -Type "manual_board_before_hero" -Data @{
        slot = $Slot
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
      }
    }
    Update-LastBoardTokenFromSlot -Slot $Slot -Token $normalized
    Set-SlotValueSource -Slot $Slot -Source "manual"
    $manualBoardReady = Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)
    if ($manualBoardReady -and (Get-HeroCardsReady)) {
      $queueManualBoardSolve = $true
      switch ($lastBoardTokens.Count) {
        3 { $manualStageLabel = "flop" }
        4 { $manualStageLabel = "turn" }
        5 { $manualStageLabel = "river" }
        default { $manualStageLabel = "manual_single" }
      }
    }
    elseif ($manualBoardReady) {
      Write-Log ("Manual board assignment held: board is ready but hero cards are still missing, so no solve was queued.") -Type "manual_board_hold_no_hero" -Data @{
        board = @($lastBoardTokens)
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
      }
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
  Refresh-RoiOverlays
  if ($queueManualBoardSolve) {
    [void](Queue-EngineSolveForBoard -BoardTokens @($lastBoardTokens) -StageLabel $manualStageLabel)
  }
}

function Repick-RoiForSlot {
  param(
    [Parameter(Mandatory = $true)][string]$Key
  )
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log ("Repick skipped for {0}: screen capture/OCR is disabled (manual mode)." -f $Key)
    return
  }
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

function Get-CardTokenOverlayText {
  param([string]$Token)
  $normalized = Normalize-CardToken -Text $Token
  if (-not (Test-CardTokenStrict -Token $normalized)) {
    return ""
  }
  $rank = $normalized.Substring(0, 1)
  $suit = $normalized.Substring(1, 1)
  $suitSymbol = switch ($suit) {
    "S" { [string][char]0x2660 }
    "H" { [string][char]0x2665 }
    "D" { [string][char]0x2666 }
    "C" { [string][char]0x2663 }
    default { $suit }
  }
  return ("{0}{1}" -f $rank, $suitSymbol)
}

function Get-ManualAssignableCardTokens {
  param(
    [Parameter(Mandatory = $true)][string]$SlotKey
  )
  $capturedSlot = [string]$SlotKey
  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($suitToken in @("S", "H", "D", "C")) {
    foreach ($rankToken in @("A", "K", "Q", "J", "T", "9", "8", "7", "6", "5", "4", "3", "2")) {
      $candidate = ("{0}{1}" -f $rankToken, $suitToken).ToUpperInvariant()
      $occupiedBy = Find-AssignedSlotForToken -Token $candidate -ExcludeSlot $capturedSlot
      if (-not $occupiedBy) {
        [void]$tokens.Add($candidate)
      }
    }
  }
  return @($tokens)
}

function New-ManualCardRandomMenuItem {
  param(
    [Parameter(Mandatory = $true)][string]$SlotKey
  )
  $capturedSlot = [string]$SlotKey
  $choices = @(Get-ManualAssignableCardTokens -SlotKey $capturedSlot)
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = "Random Card"
  if ($choices.Count -le 0) {
    $item.Enabled = $false
    return $item
  }
  $item.Add_Click({
    $available = @(Get-ManualAssignableCardTokens -SlotKey $capturedSlot)
    if ($available.Count -le 0) {
      Write-Log ("Random card assign skipped for {0}: no legal cards remain." -f $capturedSlot)
      return
    }
    $picked = Get-Random -InputObject $available
    Apply-ManualCardTokenToSlot -Slot $capturedSlot -Token ([string]$picked)
  }.GetNewClosure())
  return $item
}

function Invoke-RandomCardForSelectedTarget {
  $target = ""
  if ($null -ne $cmbTarget -and $cmbTarget.SelectedItem) {
    $target = [string]$cmbTarget.SelectedItem
  }
  if (-not $target) {
    $target = "flop1"
  }
  $slot = $target
  if ($target -eq "hero") {
    if (([string]$heroCards["hero1"]).Trim().ToUpperInvariant() -eq "??") {
      $slot = "hero1"
    }
    elseif (([string]$heroCards["hero2"]).Trim().ToUpperInvariant() -eq "??") {
      $slot = "hero2"
    }
    else {
      $slot = "hero1"
    }
  }
  if ((-not ($slot -in $cardSlotOrder)) -and (-not ($slot -in $playerSlotOrder))) {
    Write-Log ("Random card skipped for target {0}: only hero/community card slots support random assignment." -f $target)
    return
  }
  $available = @(Get-ManualAssignableCardTokens -SlotKey $slot)
  if ($available.Count -le 0) {
    Write-Log ("Random card skipped for {0}: no legal cards remain." -f $slot)
    return
  }
  $picked = Get-Random -InputObject $available
  Apply-ManualCardTokenToSlot -Slot $slot -Token ([string]$picked)
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
  $occupiedBy = Find-AssignedSlotForToken -Token $capturedToken -ExcludeSlot $capturedSlot
  if ($occupiedBy) {
    return $null
  }
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
    $rankItem = New-ManualCardRankMenuItem -SlotKey $capturedSlot -SuitToken $capturedSuit -RankToken $rankToken
    if ($null -ne $rankItem) {
      [void]$item.DropDownItems.Add($rankItem)
    }
  }
  if ($item.DropDownItems.Count -eq 0) {
    $item.Enabled = $false
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

function New-ManualActionMenu {
  param(
    [Parameter(Mandatory = $true)][string]$SlotKey
  )
  $legalTokens = @(Get-HeroLegalActionTokensForSlot -Slot $SlotKey)
  if ($legalTokens.Count -le 0) {
    return $null
  }
  if ($legalTokens.Count -eq 1) {
    $singleToken = [string]$legalTokens[0]
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = ("Use {0}" -f $singleToken)
    $item.Add_Click({
      Invoke-ManualActionSelection -ActionToken $singleToken
    }.GetNewClosure())
    return $item
  }

  $menu = New-Object System.Windows.Forms.ToolStripMenuItem
  $menu.Text = "Use Action"
  foreach ($token in $legalTokens) {
    $capturedToken = [string]$token
    $child = New-Object System.Windows.Forms.ToolStripMenuItem
    $child.Text = $capturedToken
    $child.Add_Click({
      Invoke-ManualActionSelection -ActionToken $capturedToken
    }.GetNewClosure())
    [void]$menu.DropDownItems.Add($child)
  }
  return $menu
}

function Populate-RoiSlotContextMenuItems {
  param(
    [Parameter(Mandatory = $true)][System.Windows.Forms.ContextMenuStrip]$Menu,
    [Parameter(Mandatory = $true)][string]$SlotKey
  )

  $Menu.Items.Clear()

  $title = New-Object System.Windows.Forms.ToolStripMenuItem
  $title.Text = ("Slot: {0}" -f $SlotKey)
  $title.Enabled = $false
  [void]$Menu.Items.Add($title)

  if (($SlotKey -in $cardSlotOrder) -or ($SlotKey -in $playerSlotOrder)) {
    [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$Menu.Items.Add((New-ManualCardRandomMenuItem -SlotKey $SlotKey))
    [void]$Menu.Items.Add((New-ManualCardMenu -SlotKey $SlotKey))

    $runItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $runItem.Text = "Run OCR"
    $runItem.Enabled = [bool]$script:screenCaptureEnabled
    $runItem.Add_Click({
      Run-OcrSingleSlot -Slot $SlotKey
    }.GetNewClosure())
    [void]$Menu.Items.Add($runItem)
  }
  elseif ($SlotKey -in $infoSlotOrder) {
    [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $runItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $runItem.Text = "Run OCR"
    $runItem.Enabled = [bool]$script:screenCaptureEnabled
    $runItem.Add_Click({
      Run-OcrSingleSlot -Slot $SlotKey
    }.GetNewClosure())
    [void]$Menu.Items.Add($runItem)
  }
  elseif ($SlotKey -in $stateSlotOrder) {
    [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  }
  elseif ($SlotKey -in $actionSlotOrder) {
    $actionMenu = New-ManualActionMenu -SlotKey $SlotKey
    if ($null -ne $actionMenu) {
      [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
      [void]$Menu.Items.Add($actionMenu)
    }
  }

  $repickItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $repickItem.Text = "Repick ROI"
  $repickItem.Enabled = [bool]$script:screenCaptureEnabled
  $repickItem.Add_Click({
    Repick-RoiForSlot -Key $SlotKey
  }.GetNewClosure())
  [void]$Menu.Items.Add($repickItem)

  $clearItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $clearItem.Text = "Clear ROI"
  $clearItem.Add_Click({
    Clear-RoiForSlot -Key $SlotKey
  }.GetNewClosure())
  [void]$Menu.Items.Add($clearItem)
}

function New-RoiSlotContextMenu {
  param(
    [Parameter(Mandatory = $true)][string]$Key
  )
  $slotKey = [string]$Key
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  Populate-RoiSlotContextMenuItems -Menu $menu -SlotKey $slotKey
  $menu.Add_Opening({
    Populate-RoiSlotContextMenuItems -Menu $menu -SlotKey $slotKey
  }.GetNewClosure())
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
  if (($Key -in $cardSlotOrder) -or ($Key -in $playerSlotOrder) -or ($Key -in $actionSlotOrder) -or ($Key -in $infoSlotOrder) -or ($Key -in $stateSlotOrder)) {
    $overlay.ContextMenuStrip = New-RoiSlotContextMenu -Key $Key
  }
  $overlay.Add_Paint({
    param($sender, $e)
    $state = $sender.Tag
    if ($null -eq $state) { return }
    $slotText = [string]$state.key
    if ($slotText -eq "villain_txt") {
      $slotText = "villain"
    }
    if ($state.key -in $actionSlotOrder) {
      $slotText = ""
    }
    $fontSize = 9.0
    if ($sender.Width -lt 52 -or $sender.Height -lt 22) {
      $fontSize = 7.0
    }
    $font = New-Object System.Drawing.Font("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 245, 255))
    $cardText = ""
    $cardColor = [System.Drawing.Color]::FromArgb(250, 255, 255)
    if (($state.key -in $cardSlotOrder) -or ($state.key -in $playerSlotOrder)) {
      $cardText = Get-CardTokenOverlayText -Token (Get-AssignedCardTokenForSlot -Slot ([string]$state.key))
    }
    elseif ($state.key -in $infoSlotOrder) {
      $cardText = ("POT {0}" -f [int]$script:currentPotAmount)
      $cardColor = [System.Drawing.Color]::FromArgb(180, 240, 255)
    }
    elseif ($state.key -in $stateSlotOrder) {
      $cardText = Get-VillainRoiOverlayText
      $cardColor = [System.Drawing.Color]::FromArgb(255, 210, 235)
    }
    elseif ($state.key -in $actionSlotOrder) {
      $cardText = Get-ActionSlotOverlayText -Slot ([string]$state.key)
      $cardColor = Get-AdvicePrimaryColor -Primary $cardText
    }
    $cardFont = $null
    $cardBrush = $null
    $fmt = $null
    try {
      $e.Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
      if ($slotText) {
        $e.Graphics.DrawString($slotText, $font, $brush, 4, 2)
      }
      if ($cardText) {
        if ($state.key -in $stateSlotOrder) {
          $cardFontSize = [Math]::Max(8.0, [Math]::Min([double]($sender.Height * 0.18), [double]($sender.Width * 0.12)))
          $cardFont = New-Object System.Drawing.Font("Segoe UI", [single]$cardFontSize, [System.Drawing.FontStyle]::Bold)
        }
        else {
          $cardFontSize = [Math]::Max(10.0, [Math]::Min([double]($sender.Height * 0.38), [double]($sender.Width * 0.28)))
          $cardFont = New-Object System.Drawing.Font("Segoe UI Symbol", [single]$cardFontSize, [System.Drawing.FontStyle]::Bold)
        }
        $cardBrush = New-Object System.Drawing.SolidBrush($cardColor)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rectTop = if ($state.key -in $stateSlotOrder) { [single]16 } else { [single]0 }
        $rectHeight = if ($state.key -in $stateSlotOrder) { [single]([Math]::Max(1, ($sender.ClientSize.Height - 14))) } else { [single]$sender.ClientSize.Height }
        $rect = New-Object System.Drawing.RectangleF(0, $rectTop, [single]$sender.ClientSize.Width, $rectHeight)
        $e.Graphics.DrawString($cardText, $cardFont, $cardBrush, $rect, $fmt)
      }
    }
    finally {
      if ($null -ne $fmt) { $fmt.Dispose() }
      if ($null -ne $cardBrush) { $cardBrush.Dispose() }
      if ($null -ne $cardFont) { $cardFont.Dispose() }
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
      if ($null -ne $form -and -not $form.IsDisposed) {
        $overlay.Show($form)
      }
      else {
        $overlay.Show()
      }
    }
    if ($overlay.Width -ne $rect.Width -or $overlay.Height -ne $rect.Height) {
      $overlay.Bounds = $rect
    }
    $overlay.Invalidate()
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

  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log ("Single-slot OCR skipped [{0}]: screen capture/OCR is disabled (manual mode)." -f $Slot)
    return
  }
  if ($isBusy) {
    return
  }
  if (-not ($allSlotOrder -contains $Slot)) {
    Write-Log ("Single-slot OCR skipped: unknown slot '{0}'." -f $Slot)
    return
  }
  if ($Slot -eq "pot_txt") {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$Slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      Write-Log ("Single-slot OCR skipped: ROI not set for {0}." -f $Slot)
      return
    }
    if (-not $tesseractExe) {
      Write-Log "Pot OCR skipped: Tesseract is not available."
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
      $best = Get-BestOcrForRegion -Region $slotRect -ProfileName "Numeric (pot/stack)" -TmpDir $tmpDir -Tag "pot"
      if ($null -eq $best) {
        Write-Log "Pot OCR warning: no readable output."
        return
      }
      $parsedAmount = Convert-TextToChipAmount -Text ([string]$best.text)
      if ($null -eq $parsedAmount) {
        Write-Log ("Pot OCR warning: could not parse numeric output ({0})." -f ([string]$best.text).Trim())
        return
      }
      $script:currentPotAmount = [int]$parsedAmount
      Update-TableStateDisplay
      $txtLatest.Text = @(
        "run:   single_slot"
        "slot:  pot_txt"
        ("pot:   {0}" -f [int]$script:currentPotAmount)
        ("raw:   {0}" -f ([string]$best.text).Trim())
        ("source:{0}/{1}" -f [string]$best.label, [string]$best.variant)
      ) -join "`r`n"
      Refresh-RoiOverlays
      Write-Log ("Pot OCR OK via {0}/{1}: {2} -> {3}" -f [string]$best.label, [string]$best.variant, ([string]$best.text).Trim(), [int]$script:currentPotAmount) -Type "ocr_pot" -Data @{
        slot = "pot_txt"
        raw = ([string]$best.text).Trim()
        parsed = [int]$script:currentPotAmount
        profile = [string]$best.label
        variant = [string]$best.variant
      }
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
    return
  }
  if (Test-SlotManualAuthority -Slot $Slot) {
    Write-Log ("Single-slot OCR skipped: {0} is locked by manual assignment ({1})." -f $Slot, (Get-AssignedCardTokenForSlot -Slot $Slot)) -Type "ocr_manual_skip" -Data @{
      slot = $Slot
      token = (Get-AssignedCardTokenForSlot -Slot $Slot)
    }
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
      Set-SlotValueSource -Slot $Slot -Source "none"
      Write-Log ("OCR NO_CARD [{0}] white={1:P1}, green={2:P1}" -f $Slot, [double]$resolved.white_ratio, [double]$resolved.green_ratio)
      $txtLatest.Text = @(
        "run:   single_slot"
        ("slot:  {0}" -f $Slot)
        "card:  NO_CARD"
        ("hero_cards: {0}" -f (Get-HeroCardsText))
        ("board: {0}" -f (Get-BoardTokensText))
      ) -join "`r`n"
      Refresh-RoiOverlays
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
      Set-SlotValueSource -Slot $Slot -Source "none"
      Write-Log ("OCR warning [Cards (local vision llava)] {0}: no readable output." -f $Slot)
      $txtLatest.Text = @(
        "run:   single_slot"
        ("slot:  {0}" -f $Slot)
        "card:  ??"
        ("hero_cards: {0}" -f (Get-HeroCardsText))
        ("board: {0}" -f (Get-BoardTokensText))
      ) -join "`r`n"
      Refresh-RoiOverlays
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
      Set-SlotValueSource -Slot $Slot -Source "vision"
      if (-not $suppressHeroAutoSend) {
        Try-AutoSendHeroCardsToEngine
      }
    }
    elseif ($Slot -in $cardSlotOrder) {
      Update-LastBoardTokenFromSlot -Slot $Slot -Token $token
      Set-SlotValueSource -Slot $Slot -Source "vision"
      $manualBoardReady = Get-BoardReadyFromTokens -Tokens @($lastBoardTokens)
      if ($manualBoardReady -and (Get-HeroCardsReady)) {
        $singleStageLabel = "manual_single"
        switch ($lastBoardTokens.Count) {
          3 { $singleStageLabel = "flop" }
          4 { $singleStageLabel = "turn" }
          5 { $singleStageLabel = "river" }
        }
        [void](Queue-EngineSolveForBoard -BoardTokens @($lastBoardTokens) -StageLabel $singleStageLabel)
      }
      elseif ($manualBoardReady) {
        Write-Log ("Single-slot board OCR held: board is ready but hero cards are still missing, so no solve was queued.") -Type "board_hold_no_hero" -Data @{
          board = @($lastBoardTokens)
          hero1 = [string]$heroCards["hero1"]
          hero2 = [string]$heroCards["hero2"]
        }
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
    Refresh-RoiOverlays
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

  $boardTokensInput = @($BoardTokens)
  $boardText = ($boardTokensInput -join " ")
  $configuredRuntimeProfile = ([string]$engineRuntimeProfile).Trim().ToLowerInvariant()
  if ($configuredRuntimeProfile -notin @("fast", "fast_live", "normal")) {
    $configuredRuntimeProfile = "fast"
  }
  $effectiveRuntimeProfile = $configuredRuntimeProfile
  $effectiveSolverTimeoutSec = [int]$engineSolverTimeoutSec
  $boardCountForProfile = Get-ValidBoardCardCount -Tokens @($boardTokensInput)
  $isPostflopFacingBet = ($boardCountForProfile -ge 3) -and ([int]$script:currentFacingBetAmount -gt 0)
  if ($engineFacingPostflopAutoOverrideEnabled -and ($configuredRuntimeProfile -eq "normal") -and $isPostflopFacingBet) {
    $effectiveRuntimeProfile = "fast_live"
    $effectiveSolverTimeoutSec = [int]([Math]::Max(3, [Math]::Min([int]$effectiveSolverTimeoutSec, [int]$engineFacingPostflopDeadlineSec)))
    Write-Log ("Engine runtime override: NORMAL -> FAST_LIVE (postflop facing_bet={0}, deadline={1}s)." -f [int]$script:currentFacingBetAmount, [int]$effectiveSolverTimeoutSec) -Type "engine_runtime_override" -Data @{
      stage = $StageLabel
      board = $boardTokensInput
      configured_profile = $configuredRuntimeProfile
      effective_profile = $effectiveRuntimeProfile
      facing_bet = [int]$script:currentFacingBetAmount
      deadline_sec = [int]$effectiveSolverTimeoutSec
    }
  }
  $stateSummary = if ($boardTokensInput.Count -gt 0) {
    "board $boardText"
  }
  elseif ($heroReady) {
    "hero " + ($heroTokens -join " ")
  }
  else {
    "empty_state"
  }
  Write-Log ("Engine handoff queued ({0}): {1} -> {2}" -f $StageLabel, $stateSummary, $bridgeSolveEndpoint) -Type "engine_queue" -Data @{
    stage = $StageLabel
    board = $boardTokensInput
    hero_cards = if ($heroReady) { $heroTokens } else { @() }
    endpoint = $bridgeSolveEndpoint
    runtime_profile = $configuredRuntimeProfile
    effective_runtime_profile = $effectiveRuntimeProfile
    llm_preset = $engineLlmPreset
    solver_timeout_sec = [int]$effectiveSolverTimeoutSec
  }

  try {
    $spot = Build-EngineSpotPayload -BoardCards $boardTokensInput -Label $StageLabel -HeroCards $heroTokens
    $requestPayload = [ordered]@{
      spot = $spot
      timeout_sec = [int]$effectiveSolverTimeoutSec
      quiet = $true
      llm = [ordered]@{
        preset = [string]$engineLlmPreset
      }
      runtime_profile = [string]$effectiveRuntimeProfile
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
      [int]([Math]::Max(60, $effectiveSolverTimeoutSec + 30))
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
        $rootActionsValue = @()
        if ($resp.PSObject.Properties.Name -contains "result" -and $resp.result) {
          $useActiveNode = $false
          if (($resp.result.PSObject.Properties.Name -contains "active_node_found") -and [bool]$resp.result.active_node_found -and `
              ($resp.result.PSObject.Properties.Name -contains "active_node_actions") -and $resp.result.active_node_actions) {
            $activeRows = @($resp.result.active_node_actions)
            if ($activeRows.Count -gt 0) {
              $rootActionsValue = @($activeRows)
              $useActiveNode = $true
            }
          }
          if ((-not $useActiveNode) -and ($resp.result.PSObject.Properties.Name -contains "root_actions") -and $resp.result.root_actions) {
            $rootActionsValue = @($resp.result.root_actions)
          }
        }
        if ($rootActionsValue.Count -eq 0 -and ($resp.PSObject.Properties.Name -contains "allowed_root_actions") -and $resp.allowed_root_actions) {
          $allowedTokens = @($resp.allowed_root_actions)
          if ($allowedTokens.Count -gt 0) {
            $uniformWeight = [double](1.0 / [double]$allowedTokens.Count)
            foreach ($tokenRaw in @($allowedTokens)) {
              $tokenText = ([string]$tokenRaw).Trim().ToLowerInvariant()
              if (-not $tokenText) { continue }
              $actionName = ""
              $amountValue = 0
              if ($tokenText -match "^(raise|bet|call):(-?\d+)$") {
                $actionName = [string]$matches[1]
                try { $amountValue = [int]$matches[2] } catch { $amountValue = 0 }
              }
              elseif ($tokenText -in @("fold", "call", "check", "raise", "bet", "all in", "allin")) {
                $actionName = $(if ($tokenText -eq "allin") { "all in" } else { $tokenText })
              }
              if (-not $actionName) { continue }
              $rootActionsValue += [pscustomobject]@{
                action = $actionName
                amount = [int]$amountValue
                avg_frequency = [double]$uniformWeight
              }
            }
          }
        }
        [pscustomobject]@{
          ok = $true
          elapsed_sec = [double]$elapsedSec
          selected_strategy = $selected
          exploitability = $exploitability
          node_lock_kept = $kept
          llm_error = $llmErr
          root_actions = @($rootActionsValue)
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
      board = $boardTokensInput
      runtime_profile = [string]$configuredRuntimeProfile
      effective_runtime_profile = [string]$effectiveRuntimeProfile
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
      board = $boardTokensInput
      runtime_profile = [string]$configuredRuntimeProfile
      effective_runtime_profile = [string]$effectiveRuntimeProfile
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
  if ($script:autoHeroSendInProgress) {
    return
  }
  $script:autoHeroSendInProgress = $true
  try {
  if (-not (Get-HeroCardsReady)) {
    return
  }

  $heroStageKey = ("{0}|{1}" -f [string]$heroCards["hero1"], [string]$heroCards["hero2"])
  $boardReadyNow = Get-BoardReadyFromTokens -Tokens $lastBoardTokens
  $isNewHeroStage = $heroStageKey -ne $lastHeroStageKey
  if ($isNewHeroStage) {
    if ($enginePendingJobs.Count -gt 0) {
      Stop-AllEngineJobs -Reason "new_hand_hero_staged"
    }
    $script:lastHeroAutoSendKey = ""
    $script:engineLastQueuedStateHash = ""
    $script:engineLastCompletedStateHash = ""
    $script:engineLastQueuedLogicalKey = ""
    $script:engineLastCompletedLogicalKey = ""
    Ensure-BackendsRunning
    $script:lastHeroStageKey = $heroStageKey
  }

  if (-not $boardReadyNow) {
    $preflopSolveKey = ("preflop|{0}|{1}|sb={2}|fb={3}|hc={4}|vc={5}|ha={6}|va={7}" -f `
      [string]$heroCards["hero1"], `
      [string]$heroCards["hero2"], `
      [int]([bool]$script:heroIsSmallBlind), `
      [int]$script:currentFacingBetAmount, `
      [int]$script:currentHeroStreetCommit, `
      [int]$script:currentVillainStreetCommit, `
      [int]([bool]$script:heroActedThisRound), `
      [int]([bool]$script:villainActedThisRound))
    if ($preflopSolveKey -eq $lastHeroAutoSendKey) {
      return
    }
    $villainActed = $false
    if (Test-IsVillainTurn) {
      $villainActed = Try-RunAutomaticVillainTurn
    }
    if ((-not $villainActed) -and (Test-IsVillainTurn)) {
      $script:adviceHasAction = $false
      $script:adviceActionPrimary = ""
      $script:adviceActionSecondary = ""
      Set-AdviceState -Primary "WAIT" -Secondary "Villain to act preflop."
      Write-Log ("Hero cards ready ({0}); waiting for villain action preflop." -f (Get-HeroCardsText)) -Type "hero_wait_villain_preflop" -Data @{
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
        stage_key = $heroStageKey
        preflop_key = $preflopSolveKey
      }
      $script:lastHeroAutoSendKey = $preflopSolveKey
      Update-CheckCallButtonModeFromState
      return
    }
    if (Test-IsHeroTurn) {
      $null = Ensure-PreflopHeroAdvice
    }
    $preflopSolveKey = ("preflop|{0}|{1}|sb={2}|fb={3}|hc={4}|vc={5}|ha={6}|va={7}" -f `
      [string]$heroCards["hero1"], `
      [string]$heroCards["hero2"], `
      [int]([bool]$script:heroIsSmallBlind), `
      [int]$script:currentFacingBetAmount, `
      [int]$script:currentHeroStreetCommit, `
      [int]$script:currentVillainStreetCommit, `
      [int]([bool]$script:heroActedThisRound), `
      [int]([bool]$script:villainActedThisRound))
    if ($isNewHeroStage) {
      Write-Log ("Hero cards ready ({0}); applied immediate preflop advice and warmed backends. Full solve begins on flop." -f (Get-HeroCardsText)) -Type "hero_prestaged" -Data @{
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
        stage_key = $heroStageKey
        preflop_key = $preflopSolveKey
      }
    }
    else {
      Write-Log ("Preflop state updated ({0}): facing_bet={1}, hero_commit={2}, villain_commit={3}, street_raises={4}." -f `
        (Get-HeroCardsText), [int]$script:currentFacingBetAmount, [int]$script:currentHeroStreetCommit, [int]$script:currentVillainStreetCommit, [int]$script:streetRaiseCount) -Type "hero_preflop_refresh" -Data @{
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
        stage_key = $heroStageKey
        preflop_key = $preflopSolveKey
        facing_bet = [int]$script:currentFacingBetAmount
        hero_commit = [int]$script:currentHeroStreetCommit
        villain_commit = [int]$script:currentVillainStreetCommit
        street_raise_count = [int]$script:streetRaiseCount
        max_raises_per_street = [int]$script:maxRaisesPerStreet
      }
    }
    $script:lastHeroAutoSendKey = $preflopSolveKey
    return
  }

  if ($isNewHeroStage) {
    Write-Log ("Hero cards completed with board already ready ({0}); queuing immediate solve." -f (Get-BoardTokensText)) -Type "hero_prestaged_board_ready" -Data @{
      hero1 = [string]$heroCards["hero1"]
      hero2 = [string]$heroCards["hero2"]
      board = @($lastBoardTokens)
      stage_key = $heroStageKey
    }
  }

  $solveKey = ("{0}|{1}|{2}" -f [string]$heroCards["hero1"], [string]$heroCards["hero2"], ($lastBoardTokens -join ","))
  if ($solveKey -eq $lastHeroAutoSendKey) {
    return
  }
  if (Queue-EngineSolveForBoard -BoardTokens $lastBoardTokens -StageLabel "hero_auto") {
    $script:lastHeroAutoSendKey = $solveKey
  }
  }
  finally {
    $script:autoHeroSendInProgress = $false
  }
}

function Run-OcrBoardSetAndQueueEngine {
  param(
    [Parameter(Mandatory = $true)][string]$StageLabel,
    [Parameter(Mandatory = $true)][string[]]$Slots
  )
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log ("{0} OCR skipped: screen capture/OCR is disabled (manual mode)." -f $StageLabel)
    return
  }
  if ($isBusy) {
    return
  }

  $cards = @{}
  $previewBySlot = @{}
  $slotsToResolve = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $Slots) {
    if (Test-SlotManualAuthority -Slot $slot) {
      $manualToken = Get-AssignedCardTokenForSlot -Slot $slot
      if (Test-CardTokenStrict -Token $manualToken) {
        $cards[$slot] = $manualToken
        $previewBySlot[$slot] = "manual"
        continue
      }
      Set-SlotValueSource -Slot $slot -Source "none"
    }
    [void]$slotsToResolve.Add([string]$slot)
  }

  if ($slotsToResolve.Count -gt 0 -and (-not (Test-OllamaEndpoint))) {
    Write-Log ("Vision skipped: Ollama endpoint unavailable at {0}." -f $ollamaHost)
    return
  }

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $slotsToResolve) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missing.Add([string]$slot)
    }
  }
  if ($missing.Count -gt 0) {
    Write-Log ("{0} OCR skipped: set ROIs first ({1})." -f $StageLabel, ($missing -join ", "))
    return
  }

  $script:isBusy = ($slotsToResolve.Count -gt 0)
  $restoreOverlaysAfter = $false
  $previousKeepAlive = [string]$ollamaVisionKeepAlive
  $useFastPrimary = $true
  try {
    if (($slotsToResolve.Count -gt 0) -and $overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 50
    }
    if ($slotsToResolve.Count -gt 0) {
      # Keep model warm for the current staged pass (flop/turn/river),
      # then release it in finally to preserve VRAM for solver tasks.
      $script:ollamaVisionKeepAlive = "20s"
    }

    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $resolvedBatch = @{}
    if ($slotsToResolve.Count -gt 0) {
      $resolvedBatch = Resolve-CardTokensBatch -Slots @($slotsToResolve) -TmpDir $tmpDir -SlotTagPrefix ("{0}set" -f $StageLabel.ToLowerInvariant()) -FastMode:$useFastPrimary
    }
    foreach ($slot in $slotsToResolve) {
      $resolved = $resolvedBatch[$slot]
      if ($null -eq $resolved) {
        $resolved = Resolve-CardTokenForSlot -Slot $slot -TmpDir $tmpDir -SlotTagPrefix ("{0}set" -f $StageLabel.ToLowerInvariant()) -FastMode:$useFastPrimary
      }
      if ($resolved.status -ne "ok") {
        $cards[$slot] = "??"
        Set-SlotValueSource -Slot $slot -Source "none"
        Write-Log ("OCR ERROR [{0}]: {1}" -f $slot, $resolved.message)
        continue
      }
      if ($resolved.no_card) {
        $cards[$slot] = "NO_CARD"
        Set-SlotValueSource -Slot $slot -Source "none"
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
      Set-SlotValueSource -Slot $slot -Source "vision"
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
    foreach ($slot in $slotsToResolve) {
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
        Set-SlotValueSource -Slot $slot -Source "vision"
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
    Set-LastBoardTokensWithStreetTransition -Tokens @($boardTokens)
    Refresh-RoiOverlays

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
    if (-not (Get-HeroCardsReady)) {
      Write-Log ("Engine handoff held: {0} board is ready but hero cards are not set yet." -f $StageLabel) -Type "board_hold_no_hero" -Data @{
        stage = $StageLabel
        board = $boardTokens
        hero1 = [string]$heroCards["hero1"]
        hero2 = [string]$heroCards["hero2"]
      }
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
  Reset-BoardAssignmentState
  $script:lastHeroAutoSendKey = ""
  $script:lastHeroStageKey = ""
  $script:engineLastQueuedStateHash = ""
  $script:engineLastCompletedStateHash = ""
  $script:engineLastQueuedLogicalKey = ""
  $script:engineLastCompletedLogicalKey = ""
  $heroCards["hero1"] = "??"
  $heroCards["hero2"] = "??"
  foreach ($slot in $playerSlotOrder) {
    Set-SlotValueSource -Slot $slot -Source "none"
  }
  Reset-TableStateToCurrentStakes
  $script:adviceActionPrimary = ""
  $script:adviceActionSecondary = ""
  $script:adviceHasAction = $false
  $script:lastAdviceWeightedRows = @()
  $script:lastHeroAction = "WAIT"
  $script:lastVillainAction = "WAIT"
  Update-CheckCallButtonModeFromState
  Write-Log "Hand state reset: cleared solver state and visible cards."
}

function Start-NewHandPreserveChips {
  $preservedChips = [int]$script:currentHeroChips
  $preservedVillainChips = [int]$script:currentVillainChips
  Reset-NewHandState
  $script:currentHeroChips = [int]$preservedChips
  Reset-HiddenVillainState -StartingChips ([int]$preservedVillainChips)
  $script:handCounter = [int]$script:handCounter + 1
  if ([int]$script:handCounter -eq 1) {
    # Randomize who starts as SB/BTN on the first hand, then alternate each hand.
    $script:heroIsSmallBlind = ((Get-Random -Minimum 0 -Maximum 2) -eq 1)
  }
  else {
    $script:heroIsSmallBlind = (-not [bool]$script:heroIsSmallBlind)
  }
  $script:configuredVillainCount = 1
  $script:activeVillainCount = 1
  $script:handResolved = $false
  $script:lastHandSummaryText = ""
  Start-ActiveDeckFromPreparedOrFresh
  Start-PostBlindRoundState
  $firstToActPreflop = if (Test-IsVillainTurn) { "villain" } else { "hero" }
  $script:suppressHeroAutoSend = $true
  try {
    Deal-InitialHoleCardsForCurrentHand
  }
  finally {
    $script:suppressHeroAutoSend = $false
  }
  $txtLatest.Text = @(
    "run:   new_hand"
    ("hero_role: {0}" -f $(if ($script:heroIsSmallBlind) { "SB / BTN" } else { "BB" }))
    ("villain_role: {0}" -f $(if ($script:heroIsSmallBlind) { "BB" } else { "SB / BTN" }))
    ("hero_cards: {0}" -f (Get-HeroCardsText))
    ("villain_cards: {0}" -f (Get-VillainCardsText))
    ("board: {0}" -f (Get-BoardTokensText))
    ("first_to_act_preflop: {0}" -f $firstToActPreflop)
    ("pot:   {0}" -f [int]$script:currentPotAmount)
    ("hero_chips: {0}" -f [int]$script:currentHeroChips)
    ("villain_chips: {0}" -f [int]$script:currentVillainChips)
    ("burns: {0}" -f (Get-BurnPileText))
  ) -join "`r`n"
  Update-TableStateDisplay
  Refresh-RoiOverlays
  Write-Log ("New hand started: hero={0}, villain={1}, pot={2}, hero_role={3}." -f [int]$script:currentHeroChips, [int]$script:currentVillainChips, [int]$script:currentPotAmount, $(if ($script:heroIsSmallBlind) { "SB / BTN" } else { "BB" })) -Type "new_hand" -Data @{
    current_pot = [int]$script:currentPotAmount
    current_hero_chips = [int]$script:currentHeroChips
    current_villain_chips = [int]$script:currentVillainChips
    hero_is_small_blind = [bool]$script:heroIsSmallBlind
    first_to_act_preflop = $firstToActPreflop
  }
  Try-AutoSendHeroCardsToEngine
  if ((Get-CurrentStreetName) -eq "preflop" -and (Test-IsHeroTurn) -and (Get-HeroCardsReady) -and (-not [bool]$script:adviceHasAction)) {
    $null = Ensure-PreflopHeroAdvice
  }
}

function Invoke-NewHandCycle {
  param(
    $Sender = $null,
    $EventArgs = $null
  )
  Start-NewHandPreserveChips
}

function Request-NewHandCycle {
  if ($null -ne $form -and -not $form.IsDisposed) {
    $action = [System.Action]{
      Invoke-NewHandCycle
    }.GetNewClosure()
    [void]$form.BeginInvoke($action)
    return
  }
  Invoke-NewHandCycle
}

function Run-OcrHeroSet {
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log "Run Hero skipped: screen capture/OCR is disabled (manual mode)."
    return
  }
  if ($isBusy) {
    return
  }

  $slotsToResolve = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $playerSlotOrder) {
    if (Test-SlotManualAuthority -Slot $slot) {
      continue
    }
    [void]$slotsToResolve.Add([string]$slot)
  }

  if ($slotsToResolve.Count -gt 0 -and (-not (Test-OllamaEndpoint))) {
    Write-Log ("Vision skipped: Ollama endpoint unavailable at {0}." -f $ollamaHost)
    return
  }

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $slotsToResolve) {
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
  $script:isBusy = ($slotsToResolve.Count -gt 0)
  $script:suppressHeroAutoSend = $true
  try {
    if (($slotsToResolve.Count -gt 0) -and $overlayVisible) {
      $restoreOverlaysAfter = $true
      Set-OverlayVisibilityForCapture -Enable $false
      Start-Sleep -Milliseconds 40
    }

    if ($slotsToResolve.Count -gt 0) {
      # Keep model warm only for hero1->hero2 sequence, then unload.
      $script:ollamaVisionKeepAlive = "20s"
    }
    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $resolvedBatch = @{}
    if ($slotsToResolve.Count -gt 0) {
      $resolvedBatch = Resolve-CardTokensBatch -Slots @($slotsToResolve) -TmpDir $tmpDir -SlotTagPrefix "hero" -FastMode -SkipPresenceCheck
    }
    foreach ($slot in $slotsToResolve) {
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
        Set-SlotValueSource -Slot $slot -Source "none"
        Write-Log ("Hero OCR ERROR [{0}]: {1}" -f $slot, $resolved.message)
        continue
      }
      if ($resolved.no_card) {
        $heroCards[$slot] = "NO_CARD"
        Set-SlotValueSource -Slot $slot -Source "none"
        Write-Log ("Hero OCR NO_CARD [{0}] white={1:P1}, green={2:P1}" -f $slot, [double]$resolved.white_ratio, [double]$resolved.green_ratio)
        continue
      }
      $token = ([string]$resolved.token).Trim().ToUpperInvariant()
      if (-not $token) {
        $token = "??"
      }
      $heroCards[$slot] = $token
      if (-not (Test-CardTokenStrict -Token $token)) {
        Set-SlotValueSource -Slot $slot -Source "none"
        Write-Log ("Hero OCR warning [{0}]: no readable output." -f $slot)
        continue
      }
      Set-SlotValueSource -Slot $slot -Source "vision"
      Write-Log ("Hero OCR OK [{0}] via {1}/{2}: parsed={3} (raw={4})" -f $slot, $resolved.variant, $resolved.source, $token, $resolved.preview) -Type "ocr_slot" -Data @{
        slot = $slot
        parsed = $token
        raw = [string]$resolved.preview
        source = [string]$resolved.source
        variant = [string]$resolved.variant
      }
    }

    $heroReady = Get-HeroCardsReady
    Rebuild-DeckShoeState
    $elapsed = ((Get-Date) - $started).TotalSeconds
    Refresh-RoiOverlays
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
    $script:suppressHeroAutoSend = $false
    Try-AutoSendHeroCardsToEngine
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
      $completedStage = if ($meta.ContainsKey("stage")) { [string]$meta.stage } else { "unknown" }
      $completedStrategy = if ($result.selected_strategy) { [string]$result.selected_strategy } else { "ok" }
      $script:engineLastResultSummary = ("{0}:{1} {2:N2}s" -f $completedStage, $completedStrategy, [double]$result.elapsed_sec)
      try {
        Set-AdviceFromEngineResult -EngineResult $result
      }
      catch {
        Write-Log ("Engine advice apply error: {0}" -f $_.Exception.Message) -Type "engine_advice_apply_error" -Data @{
          job_id = [int]$jobId
          stage = $completedStage
          strategy = $completedStrategy
          response_path = if ($result.PSObject.Properties.Name -contains "response_path") { [string]$result.response_path } else { "" }
        }
        if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
          Write-Log ("Engine advice apply error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
        }
        $legalTokens = @(Get-HeroLegalActionTokens)
        $fallbackPrimary = "WAIT"
        if ($legalTokens -contains "CALL") { $fallbackPrimary = "CALL" }
        elseif ($legalTokens -contains "CHECK") { $fallbackPrimary = "CHECK" }
        elseif ($legalTokens -contains "FOLD") { $fallbackPrimary = "FOLD" }
        elseif ($legalTokens -contains "RAISE") { $fallbackPrimary = "RAISE" }
        elseif ($legalTokens -contains "ALL IN") { $fallbackPrimary = "ALL IN" }
        $script:adviceActionPrimary = $fallbackPrimary
        $script:adviceActionSecondary = "Fallback advice after engine parse error."
        $script:adviceHasAction = ($fallbackPrimary -ne "WAIT")
        try {
          Set-AdviceState -Primary $script:adviceActionPrimary -Secondary $script:adviceActionSecondary
        }
        catch {}
      }
      try {
        [void](Try-RunAutomaticVillainTurn)
      }
      catch {
        Write-Log ("Auto villain turn error after engine response: {0}" -f $_.Exception.Message) -Type "auto_villain_after_engine_error" -Data @{
          job_id = [int]$jobId
          stage = $completedStage
          strategy = $completedStrategy
        }
        if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
          Write-Log ("Auto villain turn error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
        }
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
        runtime_profile = if ($meta.ContainsKey("runtime_profile")) { [string]$meta.runtime_profile } else { [string]$engineRuntimeProfile }
        effective_runtime_profile = if ($meta.ContainsKey("effective_runtime_profile")) { [string]$meta.effective_runtime_profile } else { [string]$engineRuntimeProfile }
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
      $failedStage = if ($meta.ContainsKey("stage")) { [string]$meta.stage } else { "unknown" }
      $script:engineLastResultSummary = ("{0}:failed" -f $failedStage)
      $script:adviceHasAction = $false
      $script:adviceActionPrimary = ""
      $script:adviceActionSecondary = ""
      $script:lastAdviceWeightedRows = @()
      Set-AdviceState -Primary "WAIT" -Secondary ("Engine error: {0}" -f $errMsg)
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
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log "OCR skipped: screen capture/OCR is disabled (manual mode)."
    return
  }
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

function Update-ScreenCaptureControlState {
  $captureEnabled = [bool]$script:screenCaptureEnabled
  foreach ($ctl in @(
      $btnPick,
      $btnOnce,
      $btnAutoStart,
      $btnAutoStop,
      $btnRunFlop1,
      $btnRunFlop2,
      $btnRunFlop3,
      $btnRunTurn,
      $btnRunRiver,
      $btnRunFlopSet,
      $btnRunHero
    )) {
    if ($null -ne $ctl) {
      $ctl.Enabled = $captureEnabled
    }
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
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
      Write-Log ("Engine poll error at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
    if ($enginePendingJobs.Count -eq 0) {
      $script:engineHandoffBusy = $false
    }
  }
  finally {
    Update-EngineButtonState
  }
})

$btnPick.Add_Click({
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log "Pick ROI skipped: screen capture/OCR is disabled (manual mode)."
    return
  }
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
    switch ($target) {
      "pot" { $target = "pot_txt" }
      "villain" { $target = "villain_txt" }
      "CHECK / CALL" { $target = "check_btn" }
      "RAISE / ALL IN" { $target = "raise_btn" }
      "check" { $target = "check_btn" }
      "fold" { $target = "fold_btn" }
      "call" { $target = "call_btn" }
      "raise" { $target = "raise_btn" }
      "all_in" { $target = "allin_btn" }
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

$btnRandomCard.Add_Click({
  Invoke-RandomCardForSelectedTarget
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

$btnQuickToggle.Add_Click({
  $script:quickSingleSlotHidden = -not $quickSingleSlotHidden
  Update-MainLayout
  Save-RoiState
})

$btnAutoStart.Add_Click({
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log "Auto OCR skipped: screen capture/OCR is disabled (manual mode)."
    return
  }
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

$btnNewHand.Add_Click({
  param($sender, $e)
  Request-NewHandCycle
}.GetNewClosure())

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
  Write-Log "ROIs reset. Re-pick flop1, flop2, flop3, turn, river, pot_txt, hero, and action button ROIs."
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
    $script:statusBaseText = ("Local Vision: {0} @ {1} (keep_alive={2}) | capture: {3} | card mode: {4} | ocr: {5} | bridge: {6} | profile: {7} | neural: {8}" -f `
      $ollamaVisionModel, $ollamaHost, $ollamaVisionKeepAlive, $screenCaptureStatusLabel, $modeLabel, $parallelLabel, $bridgeSolveEndpoint, $engineRuntimeProfile.ToUpperInvariant(), $neuralStatusLabel)
    Write-Log ("Engine runtime profile set to: {0}" -f $engineRuntimeProfile.ToUpperInvariant()) -Type "engine_runtime_profile" -Data @{
      runtime_profile = $engineRuntimeProfile
    }
    Update-EngineButtonState
  }
})

$form.Add_Shown({
  Apply-UiPolish
  Update-MainLayout
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
  Update-MainLayout
  $regionLabel.Text = "Selected: none"
  $hint.Text = "Individual mode: select target -> Pick ROI -> repeat for board, hero, and action ROIs."
  $cardStatusLabel.Text = Format-CardSlotStatus
  Update-TargetsButtonText
  Reset-TableStateToCurrentStakes
  Update-ScreenCaptureControlState
  Refresh-RoiOverlays
  if ($null -eq $adviceOverlay -or $adviceOverlay.IsDisposed) {
    $script:adviceOverlay = New-AdviceOverlayForm
  }
  if ($null -ne $adviceOverlay -and -not $adviceOverlay.Visible) {
    if ($null -ne $form -and -not $form.IsDisposed) {
      $adviceOverlay.Show($form)
    }
    else {
      $adviceOverlay.Show()
    }
  }
  if ($null -eq $stateOverlay -or $stateOverlay.IsDisposed) {
    $script:stateOverlay = New-TableStateOverlayForm
  }
  if ($null -ne $stateOverlay -and -not $stateOverlay.Visible) {
    if ($null -ne $form -and -not $form.IsDisposed) {
      $stateOverlay.Show($form)
    }
    else {
      $stateOverlay.Show()
    }
  }
  Ensure-BackendsRunning
  if (-not [bool]$script:screenCaptureEnabled) {
    Write-Log "Screen capture/OCR is disabled (manual mode). Set POKERBOT_ENABLE_SCREEN_CAPTURE=1 to re-enable."
  }
  if ([bool]$script:screenCaptureEnabled) {
    Write-Log "Ready. Select target, pick each ROI, then run OCR."
  }
  else {
    Write-Log "Ready. Screen capture/OCR disabled; use manual cards/actions and engine state flow."
  }
  $timer.Start()
  $engineJobTimer.Start()
})

$form.Add_Resize({
  Update-MainLayout
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
  if ($null -ne $adviceOverlay) {
    try {
      if (-not $adviceOverlay.IsDisposed) {
        $adviceOverlay.Close()
        $adviceOverlay.Dispose()
      }
    }
    catch {}
    $script:adviceOverlay = $null
  }
  if ($null -ne $stateOverlay) {
    try {
      if (-not $stateOverlay.IsDisposed) {
        $stateOverlay.Close()
        $stateOverlay.Dispose()
      }
    }
    catch {}
    $script:stateOverlay = $null
  }
  Save-RoiState
  Close-RoiOverlays
})

[void]$form.ShowDialog()
if ($pauseOnNormalExit) {
  Read-Host "Press Enter to exit"
}




