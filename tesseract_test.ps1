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
$selectedRegion = [System.Drawing.Rectangle]::Empty
$isBusy = $false
$autoEnabled = $false
$cardSlotOrder = @("flop1", "flop2", "flop3", "turn", "river")
$cardRegions = @{}
foreach ($slot in $cardSlotOrder) {
  $cardRegions[$slot] = [System.Drawing.Rectangle]::Empty
}

function Test-RegionSelected {
  param([System.Drawing.Rectangle]$Rect)
  return ($Rect.Width -gt 0 -and $Rect.Height -gt 0)
}

function Format-CardSlotStatus {
  $missing = @()
  foreach ($slot in $cardSlotOrder) {
    if (-not (Test-RegionSelected -Rect $cardRegions[$slot])) {
      $missing += $slot
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
    return ($rankMatch.Value + "?")
  }
  return ($rankMatch.Value + $suitMatch.Value)
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
  $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
  $imgPath = Join-Path $TmpDir ("capture_{0}_{1}.png" -f $Tag, $stamp)
  Capture-RegionImage -Region $Region -Path $imgPath

  $specs = Get-OcrProfileSpec -ProfileName $ProfileName
  $variantPaths = @($imgPath)
  $contrastPath = Join-Path $TmpDir ("capture_{0}_{1}.contrast.png" -f $Tag, $stamp)
  try {
    New-HighContrastVariant -SourcePath $imgPath -TargetPath $contrastPath
    $variantPaths += $contrastPath
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
      $cmd = @($variant, $outBase, "--oem", "1", "--psm", [string]$spec.psm)
      if ($spec.whitelist) {
        $cmd += @("-c", ("tessedit_char_whitelist={0}" -f [string]$spec.whitelist))
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

function Get-CardTokenFromRegion {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Region,
    [Parameter(Mandatory = $true)][string]$TmpDir,
    [Parameter(Mandatory = $true)][string]$SlotTag
  )

  $regions = @(
    [pscustomobject]@{ tag = "full"; rect = $Region }
  )

  if ($Region.Width -ge 20 -and $Region.Height -ge 20) {
    $x = $Region.X
    $y = $Region.Y
    $w = $Region.Width
    $h = $Region.Height
    $regions += [pscustomobject]@{
      tag = "rankcrop1"
      rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.60)), [Math]::Max(8, [int]($h * 0.70)))
    }
    $regions += [pscustomobject]@{
      tag = "rankcrop2"
      rect = New-Object System.Drawing.Rectangle($x, $y, [Math]::Max(8, [int]($w * 0.45)), [Math]::Max(8, [int]($h * 0.52)))
    }
    $regions += [pscustomobject]@{
      tag = "rankcrop3"
      rect = New-Object System.Drawing.Rectangle(
        $x + [Math]::Max(0, [int]($w * 0.03)),
        $y + [Math]::Max(0, [int]($h * 0.05)),
        [Math]::Max(8, [int]($w * 0.55)),
        [Math]::Max(8, [int]($h * 0.65))
      )
    }
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
    $token = Normalize-CardToken -Text $rawText
    $tokenScore = Get-CardTokenScore -Token $token
    $combinedScore = $tokenScore + [int]$best.score
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

$form = New-Object System.Windows.Forms.Form
$form.Text = "Tesseract Region Test"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 700)
$form.MinimumSize = New-Object System.Drawing.Size(980, 700)
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 30)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Tesseract OCR Region Test"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$status = New-Object System.Windows.Forms.Label
$status.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$status.Location = New-Object System.Drawing.Point(20, 44)
$status.AutoSize = $true
if ($tesseractExe) {
  $status.Text = "Tesseract: $tesseractExe"
  $status.ForeColor = [System.Drawing.Color]::FromArgb(140, 220, 170)
}
else {
  $status.Text = "Tesseract: NOT FOUND (set TESSERACT_PATH or add to PATH)"
  $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 180, 120)
}
$form.Controls.Add($status)

$regionLabel = New-Object System.Windows.Forms.Label
$regionLabel.Text = "Region: Not selected"
$regionLabel.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$regionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$regionLabel.Location = New-Object System.Drawing.Point(20, 74)
$regionLabel.AutoSize = $true
$form.Controls.Add($regionLabel)

$cardStatusLabel = New-Object System.Windows.Forms.Label
$cardStatusLabel.Text = Format-CardSlotStatus
$cardStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$cardStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$cardStatusLabel.Location = New-Object System.Drawing.Point(20, 94)
$cardStatusLabel.AutoSize = $true
$form.Controls.Add($cardStatusLabel)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = "Pick OCR Rectangle"
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

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Pick ROI with left-drag (or right-click 2 corners). In Cards profile, set all 5 boxes (flop1/2/3, turn, river)."
$hint.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hint.Location = New-Object System.Drawing.Point(20, 162)
$hint.AutoSize = $true
$form.Controls.Add($hint)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "ROI Target"
$lblTarget.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblTarget.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblTarget.Location = New-Object System.Drawing.Point(876, 90)
$lblTarget.AutoSize = $true
$form.Controls.Add($lblTarget)

$cmbTarget = New-Object System.Windows.Forms.ComboBox
$cmbTarget.DropDownStyle = "DropDownList"
$cmbTarget.Location = New-Object System.Drawing.Point(876, 108)
$cmbTarget.Size = New-Object System.Drawing.Size(90, 24)
$cmbTarget.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbTarget.Items.Add("General ROI")
[void]$cmbTarget.Items.Add("flop1")
[void]$cmbTarget.Items.Add("flop2")
[void]$cmbTarget.Items.Add("flop3")
[void]$cmbTarget.Items.Add("turn")
[void]$cmbTarget.Items.Add("river")
$cmbTarget.SelectedIndex = 1
$form.Controls.Add($cmbTarget)

$lblProfile = New-Object System.Windows.Forms.Label
$lblProfile.Text = "OCR Profile"
$lblProfile.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblProfile.Location = New-Object System.Drawing.Point(876, 136)
$lblProfile.AutoSize = $true
$form.Controls.Add($lblProfile)

$cmbProfile = New-Object System.Windows.Forms.ComboBox
$cmbProfile.DropDownStyle = "DropDownList"
$cmbProfile.Location = New-Object System.Drawing.Point(876, 154)
$cmbProfile.Size = New-Object System.Drawing.Size(90, 24)
$cmbProfile.Font = New-Object System.Drawing.Font("Segoe UI", 9)
[void]$cmbProfile.Items.Add("General")
[void]$cmbProfile.Items.Add("Cards (ranks/suits)")
[void]$cmbProfile.Items.Add("Numeric (pot/stack)")
$cmbProfile.SelectedIndex = 1
$form.Controls.Add($cmbProfile)

$latestLabel = New-Object System.Windows.Forms.Label
$latestLabel.Text = "Latest OCR Text"
$latestLabel.ForeColor = [System.Drawing.Color]::White
$latestLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$latestLabel.Location = New-Object System.Drawing.Point(20, 180)
$latestLabel.AutoSize = $true
$form.Controls.Add($latestLabel)

$txtLatest = New-Object System.Windows.Forms.TextBox
$txtLatest.Location = New-Object System.Drawing.Point(20, 204)
$txtLatest.Size = New-Object System.Drawing.Size(936, 190)
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
$logLabel.Location = New-Object System.Drawing.Point(20, 404)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 428)
$logBox.Size = New-Object System.Drawing.Size(936, 220)
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

function Run-Ocr {
  if (-not $tesseractExe) {
    Write-Log "OCR skipped: tesseract not found."
    return
  }
  if ($isBusy) {
    return
  }

  $profileName = [string]$cmbProfile.SelectedItem
  if (-not $profileName) {
    $profileName = "General"
  }

  if ($profileName -eq "Cards (ranks/suits)") {
    $missing = @()
    foreach ($slot in $cardSlotOrder) {
      if (-not (Test-RegionSelected -Rect $cardRegions[$slot])) {
        $missing += $slot
      }
    }
    if ($missing.Count -gt 0) {
      Write-Log ("OCR skipped: set all card ROIs first ({0})." -f ($missing -join ", "))
      return
    }
  }
  elseif (-not (Test-RegionSelected -Rect $selectedRegion)) {
    Write-Log "OCR skipped: select a region first."
    return
  }

  $script:isBusy = $true
  try {
    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    if ($profileName -eq "Cards (ranks/suits)") {
      $cards = @{}
      foreach ($slot in $cardSlotOrder) {
        $cards[$slot] = "--"
      }
      foreach ($slot in $cardSlotOrder) {
        $bestCard = Get-CardTokenFromRegion -Region $cardRegions[$slot] -TmpDir $tmpDir -SlotTag $slot
        if (-not $bestCard) {
          $cards[$slot] = "??"
          Write-Log ("OCR warning [Cards (ranks/suits)] {0}: no readable output." -f $slot)
          continue
        }
        $cards[$slot] = $bestCard.token
        $preview = (($bestCard.raw_text -replace "\r?\n", " ") -as [string]).Trim()
        if ($preview.Length -gt 64) {
          $preview = $preview.Substring(0, 64) + "..."
        }
        Write-Log ("OCR OK [Cards (ranks/suits)] {0} {1} via {2}/{3}: {4}" -f $slot, $bestCard.label, $bestCard.variant, $bestCard.source, $preview)
      }

      $out = @(
        "run:   all_cards"
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
    else {
      $best = Get-BestOcrForRegion -Region $selectedRegion -ProfileName $profileName -TmpDir $tmpDir -Tag "region"
      if ($best) {
        $bestText = if ($best.text -is [System.Array]) {
          [string]::Join([Environment]::NewLine, ($best.text | ForEach-Object { [string]$_ }))
        }
        else {
          [string]$best.text
        }
        $bestText = $bestText.Trim()
        $txtLatest.Text = $bestText
        $preview = (($bestText -replace "\r?\n", " ") -as [string]).Trim()
        if ($preview.Length -gt 120) {
          $preview = $preview.Substring(0, 120) + "..."
        }
        Write-Log ("OCR OK [{0}] {1} via {2}: {3}" -f $profileName, $best.label, $best.variant, $preview)
      }
      else {
        Write-Log ("OCR finished but no readable output was produced for profile: {0}" -f $profileName)
      }
    }
  }
  catch {
    Write-Log ("OCR ERROR: {0}" -f $_.Exception.Message)
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
  $form.Hide()
  Start-Sleep -Milliseconds 150
  $rect = Select-ScreenRegion
  $form.Show()
  $form.Activate()
  if ($rect -ne [System.Drawing.Rectangle]::Empty) {
    $target = [string]$cmbTarget.SelectedItem
    if (-not $target) {
      $target = "General ROI"
    }
    if ($target -eq "General ROI") {
      $script:selectedRegion = $rect
      $regionLabel.Text = Format-RegionText -Rect $selectedRegion
      Write-Log ("General ROI updated. {0}" -f $regionLabel.Text)
    }
    else {
      if ($cardRegions.ContainsKey($target)) {
        $cardRegions[$target] = $rect
        Write-Log ("Card ROI [{0}] set to X={1}, Y={2}, W={3}, H={4}" -f $target, $rect.X, $rect.Y, $rect.Width, $rect.Height)
        $cardStatusLabel.Text = Format-CardSlotStatus
      }
      else {
        Write-Log ("Unknown ROI target: {0}" -f $target)
      }
    }
  }
  else {
    Write-Log "Rectangle selection canceled."
  }
})

$btnOnce.Add_Click({
  Run-Ocr
})

$btnAutoStart.Add_Click({
  if (-not $tesseractExe) {
    [void][System.Windows.Forms.MessageBox]::Show(
      "Tesseract not found. Set TESSERACT_PATH or add tesseract to PATH first.",
      "Missing Tesseract",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  $profileName = [string]$cmbProfile.SelectedItem
  if (-not $profileName) {
    $profileName = "General"
  }
  if ($profileName -eq "Cards (ranks/suits)") {
    $missing = @()
    foreach ($slot in $cardSlotOrder) {
      if (-not (Test-RegionSelected -Rect $cardRegions[$slot])) {
        $missing += $slot
      }
    }
    if ($missing.Count -gt 0) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ("Set all five card ROIs before auto mode. Missing: {0}" -f ($missing -join ", ")),
        "Missing Card ROIs",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      )
      return
    }
  }
  elseif (-not (Test-RegionSelected -Rect $selectedRegion)) {
    [void][System.Windows.Forms.MessageBox]::Show(
      "Pick an OCR rectangle first.",
      "No Region",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  $timer.Interval = [int]([int]$numInterval.Value * 1000)
  $script:autoEnabled = $true
  $btnAutoStart.Enabled = $false
  $btnAutoStop.Enabled = $true
  if ($profileName -eq "Cards (ranks/suits)") {
    Write-Log ("Auto OCR started (every {0}s, all five card boxes)." -f [int]$numInterval.Value)
  }
  else {
    Write-Log ("Auto OCR started (every {0}s)." -f [int]$numInterval.Value)
  }
})

$btnAutoStop.Add_Click({
  $script:autoEnabled = $false
  $btnAutoStart.Enabled = $true
  $btnAutoStop.Enabled = $false
  Write-Log "Auto OCR stopped."
})

$form.Add_Shown({
  $regionLabel.Text = Format-RegionText -Rect $selectedRegion
  $cardStatusLabel.Text = Format-CardSlotStatus
  Write-Log "Ready. In Cards profile, set ROI target and pick all five card boxes."
  $timer.Start()
})

$form.Add_FormClosing({
  $script:autoEnabled = $false
  $timer.Stop()
})

[void]$form.ShowDialog()
