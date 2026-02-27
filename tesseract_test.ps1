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

$tesseractExe = Resolve-TesseractExecutable
$ollamaHost = if ($env:OLLAMA_HOST) { [string]$env:OLLAMA_HOST } else { "http://127.0.0.1:11434" }
$ollamaVisionModel = if ($env:OLLAMA_VISION_MODEL) { [string]$env:OLLAMA_VISION_MODEL } else { "llava:13b" }
$roiStatePath = Join-Path (Join-Path $env:APPDATA "PokeHerFace") "vision_tester_rois.json"
$selectedRegion = [System.Drawing.Rectangle]::Empty
$isBusy = $false
$autoEnabled = $false
$overlayVisible = $true
$cardSlotOrder = @("flop1", "flop2", "flop3", "turn", "river")
$cardRegions = @{}
$overlayForms = @{}
$overlayColors = @{
  board = [System.Drawing.Color]::FromArgb(40, 200, 255)
  flop1 = [System.Drawing.Color]::FromArgb(80, 230, 140)
  flop2 = [System.Drawing.Color]::FromArgb(80, 230, 140)
  flop3 = [System.Drawing.Color]::FromArgb(80, 230, 140)
  turn  = [System.Drawing.Color]::FromArgb(255, 215, 90)
  river = [System.Drawing.Color]::FromArgb(255, 150, 80)
}
foreach ($slot in $cardSlotOrder) {
  $cardRegions[$slot] = [System.Drawing.Rectangle]::Empty
}

function Get-RoiTargets {
  return @("flop1", "flop2", "flop3", "turn", "river")
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

function Save-RoiState {
  try {
    $dir = Split-Path -Parent $roiStatePath
    if (-not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload = @{}
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
    foreach ($key in (Get-RoiTargets)) {
      $node = $obj.$key
      if ($null -eq $node) {
        continue
      }
      $x = [int]$node.x
      $y = [int]$node.y
      $w = [int]$node.w
      $h = [int]$node.h
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
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($slot in $cardSlotOrder) {
    $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
    if (-not (Test-RegionSelected -Rect $slotRect)) {
      [void]$missing.Add([string]$slot)
    }
  }
  if ($missing.Count -eq 0) {
    return "Card ROIs: ready (flop1, flop2, flop3, turn, river)"
  }
  return ("Card ROIs missing: {0}" -f ($missing -join ", "))
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
    $keepSlot = $slots[0]
    $keepScore = if ($CardScores.ContainsKey($keepSlot)) { [int]$CardScores[$keepSlot] } else { -100000 }
    foreach ($slot in $slots) {
      $score = if ($CardScores.ContainsKey($slot)) { [int]$CardScores[$slot] } else { -100000 }
      if ($score -gt $keepScore) {
        $keepScore = $score
        $keepSlot = $slot
      }
    }
    foreach ($slot in $slots) {
      if ($slot -ne $keepSlot) {
        $Cards[$slot] = "??"
      }
    }
    [void]$warnings.Add(("Duplicate card token {0} detected in {1}; kept {2}, cleared others to ??." -f $token, ($slots -join ","), $keepSlot))
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
      [int]$x = [int]$Region.X
      [int]$y = [int]$Region.Y
      [int]$w = [int]$Region.Width
      [int]$h = [int]$Region.Height
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
          $x + [Math]::Max(0, [int]($w * 0.03)),
          $y + [Math]::Max(0, [int]($h * 0.05)),
          [Math]::Max(8, [int]($w * 0.55)),
          [Math]::Max(8, [int]($h * 0.65))
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
  $prompt = "Read exactly one poker community card from this image crop. Output exactly one token only: rank+suit using AKQJT98765432 and shdc (examples: As, Td, 7h). If uncertain return ??. No other words."
  $payload = @{
    model = $ollamaVisionModel
    prompt = $prompt
    images = @($b64)
    stream = $false
    options = @{
      temperature = 0
      top_p = 0.1
      num_predict = 6
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

function Get-CardTokenFromVisionRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$SlotTag
  )
  $Region = Convert-ToRectangleSafe -Value $Region
  if ($Region.Width -le 0 -or $Region.Height -le 0) {
    return $null
  }

  $regions = New-Object System.Collections.Generic.List[object]
  [void]$regions.Add([pscustomobject]@{ tag = "full"; rect = $Region })
  if ($Region.Width -ge 20 -and $Region.Height -ge 20) {
    [int]$x = [int]$Region.X
    [int]$y = [int]$Region.Y
    [int]$w = [int]$Region.Width
    [int]$h = [int]$Region.Height
    [void]$regions.Add([pscustomobject]@{
      tag = "rankcrop1"
      rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.60)), [Math]::Max(8, [int]($h * 0.70)))
    })
  }

  $bestToken = ""
  $bestRaw = ""
  $bestSource = ""
  $bestVariant = ""
  $bestScore = -100000

  foreach ($entry in $regions) {
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
    $imgPath = Join-Path $TmpDir ("vision_{0}_{1}_{2}.png" -f $SlotTag, $entry.tag, $stamp)
    Capture-RegionImage -Region $entry.rect -Path $imgPath
    $imagePaths = New-Object System.Collections.Generic.List[string]
    [void]$imagePaths.Add([string]$imgPath)
    $contrastPath = Join-Path $TmpDir ("vision_{0}_{1}_{2}.contrast.png" -f $SlotTag, $entry.tag, $stamp)
    try {
      New-HighContrastVariant -SourcePath $imgPath -TargetPath $contrastPath
      [void]$imagePaths.Add([string]$contrastPath)
    }
    catch {
      Write-Log ("Vision preprocess warning ({0}): {1}" -f $SlotTag, $_.Exception.Message)
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
      if (-not $rawText) {
        continue
      }
      $token = Normalize-CardToken -Text $rawText
      $tokenScore = Get-CardTokenScore -Token $token
      if ($token -eq "??") {
        $tokenScore -= 10
      }
      if ($tokenScore -gt $bestScore) {
        $bestScore = $tokenScore
        $bestToken = if ($token) { $token } else { "??" }
        $bestRaw = $rawText
        $bestSource = [string]$entry.tag
        $bestVariant = [System.IO.Path]::GetFileName($candidatePath)
      }
      if ($bestToken -match "^[AKQJT98765432][SHDC]$") {
        break
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
$status.Text = ("Local Vision: {0} @ {1}" -f $ollamaVisionModel, $ollamaHost)
$status.ForeColor = [System.Drawing.Color]::FromArgb(140, 220, 170)
$form.Controls.Add($status)

$regionLabel = New-Object System.Windows.Forms.Label
$regionLabel.Text = "Selected: none"
$regionLabel.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$regionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$regionLabel.Location = New-Object System.Drawing.Point(20, 74)
$regionLabel.AutoSize = $true
$form.Controls.Add($regionLabel)

$cardStatusLabel = New-Object System.Windows.Forms.Label
$cardStatusLabel.Text = "Set all 5 card targets (flop1, flop2, flop3, turn, river)."
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
$btnAutoStart.Size = New-Object System.Drawing.Size(120, 34)
$btnAutoStart.FlatStyle = "Flat"
$btnAutoStart.ForeColor = [System.Drawing.Color]::White
$btnAutoStart.BackColor = [System.Drawing.Color]::FromArgb(30, 105, 68)
$form.Controls.Add($btnAutoStart)

$btnAutoStop = New-Object System.Windows.Forms.Button
$btnAutoStop.Text = "Stop Auto"
$btnAutoStop.Location = New-Object System.Drawing.Point(740, 118)
$btnAutoStop.Size = New-Object System.Drawing.Size(120, 34)
$btnAutoStop.FlatStyle = "Flat"
$btnAutoStop.ForeColor = [System.Drawing.Color]::White
$btnAutoStop.BackColor = [System.Drawing.Color]::FromArgb(110, 30, 30)
$btnAutoStop.Enabled = $false
$form.Controls.Add($btnAutoStop)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "Restart App"
$btnRestart.Location = New-Object System.Drawing.Point(870, 118)
$btnRestart.Size = New-Object System.Drawing.Size(90, 34)
$btnRestart.FlatStyle = "Flat"
$btnRestart.ForeColor = [System.Drawing.Color]::White
$btnRestart.BackColor = [System.Drawing.Color]::FromArgb(52, 64, 92)
$form.Controls.Add($btnRestart)

$btnTargets = New-Object System.Windows.Forms.Button
$btnTargets.Text = "Targets: On"
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

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "1) Select ROI target 2) Pick ROI 3) Repeat for all 5 4) Run OCR."
$hint.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hint.Location = New-Object System.Drawing.Point(20, 186)
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
$cmbTarget.SelectedIndex = 0
$cmbTarget.Enabled = $true
$form.Controls.Add($cmbTarget)
$lblTarget.Enabled = $true

$latestLabel = New-Object System.Windows.Forms.Label
$latestLabel.Text = "Latest OCR Text"
$latestLabel.ForeColor = [System.Drawing.Color]::White
$latestLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$latestLabel.Location = New-Object System.Drawing.Point(20, 210)
$latestLabel.AutoSize = $true
$form.Controls.Add($latestLabel)

$txtLatest = New-Object System.Windows.Forms.TextBox
$txtLatest.Location = New-Object System.Drawing.Point(20, 234)
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
$logLabel.Location = New-Object System.Drawing.Point(20, 402)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 426)
$logBox.Size = New-Object System.Drawing.Size(936, 222)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(14, 18, 23)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 245)
$form.Controls.Add($logBox)

function Write-Log {
  param([string]$Message)
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $logBox.AppendText("[$stamp] $Message`r`n")
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
  return $cardSlotOrder
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
  $overlay.ShowInTaskbar = $false
  $overlay.TopMost = $true
  $overlay.BackColor = $Color
  $overlay.Opacity = 0.28
  $overlay.Bounds = $Rect
  $overlay.Tag = [pscustomobject]@{
    key = $Key
    down = $false
    offsetX = 0
    offsetY = 0
  }

  $tagLabel = New-Object System.Windows.Forms.Label
  $tagLabel.Text = $Key
  $tagLabel.ForeColor = [System.Drawing.Color]::White
  $tagLabel.BackColor = [System.Drawing.Color]::Transparent
  $tagLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
  $tagLabel.AutoSize = $true
  $tagLabel.Location = New-Object System.Drawing.Point(4, 2)
  $tagLabel.Tag = $overlay
  $overlay.Controls.Add($tagLabel)

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

  # Dragging on the label moves the overlay too.
  $tagLabel.Add_MouseDown({
    param($sender, $e)
    $owner = $sender.Tag
    if ($null -eq $owner) { return }
    $state = $owner.Tag
    if ($null -eq $state) { return }
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $state.down = $true
      $state.offsetX = [int]$e.X + [int]$sender.Left
      $state.offsetY = [int]$e.Y + [int]$sender.Top
    }
  })
  $tagLabel.Add_MouseMove({
    param($sender, $e)
    $owner = $sender.Tag
    if ($null -eq $owner) { return }
    $state = $owner.Tag
    if ($null -eq $state -or -not $state.down) {
      return
    }
    $pt = [System.Windows.Forms.Control]::MousePosition
    $owner.Left = [int]($pt.X - [int]$state.offsetX)
    $owner.Top = [int]($pt.Y - [int]$state.offsetY)
  })
  $tagLabel.Add_MouseUp({
    param($sender, $e)
    $owner = $sender.Tag
    if ($null -eq $owner) { return }
    $state = $owner.Tag
    if ($null -eq $state -or -not $state.down) {
      return
    }
    $state.down = $false
    Sync-OverlayToRoi -Key ([string]$state.key) -OverlayForm $owner
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
    if ($overlay.Bounds -ne $rect) {
      $overlay.Bounds = $rect
    }
    if (-not $overlay.Visible) {
      $overlay.Show()
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

  $script:isBusy = $true
  try {
    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $cards = @{}
    $cardScores = @{}
    foreach ($slot in $cardSlotOrder) {
      $slotRect = Convert-ToRectangleSafe -Value $cardRegions[$slot]
      $bestCard = Get-CardTokenFromVisionRegion -Region $slotRect -TmpDir $tmpDir -SlotTag $slot
      if (-not $bestCard) {
        $cards[$slot] = "??"
        $cardScores[$slot] = -100000
        Write-Log ("OCR warning [Cards (local vision llava)] {0}: no readable output." -f $slot)
        continue
      }
      $cards[$slot] = $bestCard.token
      $cardScores[$slot] = if ($null -ne $bestCard.score) { [int]$bestCard.score } else { -100000 }
      $preview = (($bestCard.raw_text -replace "\r?\n", " ") -as [string]).Trim()
      if ($preview.Length -gt 96) {
        $preview = $preview.Substring(0, 96) + "..."
      }
      Write-Log ("OCR OK [Cards (local vision llava)] {0} via {1}/{2}: {3}" -f $slot, $bestCard.variant, $bestCard.source, $preview)
    }

    $collisionResult = Resolve-BoardCardCollisions -Cards $cards -CardScores $cardScores
    $cards = $collisionResult.cards
    foreach ($warn in $collisionResult.warnings) {
      Write-Log ("OCR warning [Cards (local vision llava)] {0}" -f $warn)
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

$btnPick.Add_Click({
  Write-Log "Selecting OCR rectangle..."
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
    if ($cardRegions.ContainsKey($target)) {
      $cardRegions[$target] = $rect
      $regionLabel.Text = ("Selected: {0} -> X={1}, Y={2}, W={3}, H={4}" -f $target, $rect.X, $rect.Y, $rect.Width, $rect.Height)
      Write-Log ("Card ROI [{0}] set to X={1}, Y={2}, W={3}, H={4}" -f $target, $rect.X, $rect.Y, $rect.Width, $rect.Height)
      $cardStatusLabel.Text = Format-CardSlotStatus
    }
    else {
      Write-Log ("Unknown ROI target: {0}" -f $target)
    }
    Save-RoiState
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
  $form.Close()
})

$btnTargets.Add_Click({
  $script:overlayVisible = -not $overlayVisible
  $btnTargets.Text = if ($overlayVisible) { "Targets: On" } else { "Targets: Off" }
  Refresh-RoiOverlays
  Write-Log ("Target overlays {0}." -f (if ($overlayVisible) { "enabled" } else { "hidden" }))
})

$btnResetRois.Add_Click({
  foreach ($slot in $cardSlotOrder) {
    $cardRegions[$slot] = [System.Drawing.Rectangle]::Empty
  }
  $script:selectedRegion = [System.Drawing.Rectangle]::Empty
  $regionLabel.Text = "Selected: none"
  $cardStatusLabel.Text = Format-CardSlotStatus
  Save-RoiState
  Refresh-RoiOverlays
  Write-Log "ROIs reset. Re-pick flop1, flop2, flop3, turn, river."
})

$cmbCaptureMode.Add_SelectedIndexChanged({
  $hint.Text = "Individual mode: select target -> Pick ROI -> repeat for all 5 cards."
  $cardStatusLabel.Text = Format-CardSlotStatus
  Refresh-RoiOverlays
})

$form.Add_Shown({
  Load-RoiState
  $regionLabel.Text = "Selected: none"
  $hint.Text = "Individual mode: select target -> Pick ROI -> repeat for all 5 cards."
  $cardStatusLabel.Text = Format-CardSlotStatus
  $btnTargets.Text = if ($overlayVisible) { "Targets: On" } else { "Targets: Off" }
  Refresh-RoiOverlays
  Write-Log "Ready. Select target, pick each ROI, then run OCR."
  $timer.Start()
})

$form.Add_FormClosing({
  $script:autoEnabled = $false
  $timer.Stop()
  Save-RoiState
  Close-RoiOverlays
})

[void]$form.ShowDialog()
