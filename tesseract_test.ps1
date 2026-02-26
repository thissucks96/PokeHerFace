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
  ) | Where-Object { $_ -and $_.Trim() -ne "" }

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

function Select-ScreenRegion {
  $resultRect = [System.Drawing.Rectangle]::Empty
  $virtualScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $state = [pscustomobject]@{
    Start = [System.Drawing.Point]::Empty
    Current = [System.Drawing.Point]::Empty
    Dragging = $false
    AnchorMode = $false
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
          $resultRect = New-Object System.Drawing.Rectangle(($x + $virtualScreen.X), ($y + $virtualScreen.Y), $w, $h)
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
        $resultRect = New-Object System.Drawing.Rectangle(($x + $virtualScreen.X), ($y + $virtualScreen.Y), $w, $h)
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
  return $resultRect
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

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = "Pick OCR Rectangle"
$btnPick.Location = New-Object System.Drawing.Point(20, 104)
$btnPick.Size = New-Object System.Drawing.Size(190, 34)
$btnPick.FlatStyle = "Flat"
$btnPick.ForeColor = [System.Drawing.Color]::White
$btnPick.BackColor = [System.Drawing.Color]::FromArgb(46, 56, 68)
$form.Controls.Add($btnPick)

$btnOnce = New-Object System.Windows.Forms.Button
$btnOnce.Text = "Run OCR Once"
$btnOnce.Location = New-Object System.Drawing.Point(220, 104)
$btnOnce.Size = New-Object System.Drawing.Size(140, 34)
$btnOnce.FlatStyle = "Flat"
$btnOnce.ForeColor = [System.Drawing.Color]::White
$btnOnce.BackColor = [System.Drawing.Color]::FromArgb(20, 95, 62)
$form.Controls.Add($btnOnce)

$lblAuto = New-Object System.Windows.Forms.Label
$lblAuto.Text = "Auto OCR interval (sec)"
$lblAuto.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblAuto.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblAuto.Location = New-Object System.Drawing.Point(380, 111)
$lblAuto.AutoSize = $true
$form.Controls.Add($lblAuto)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(520, 108)
$numInterval.Size = New-Object System.Drawing.Size(70, 30)
$numInterval.Minimum = 1
$numInterval.Maximum = 60
$numInterval.Value = 5
$numInterval.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($numInterval)

$btnAutoStart = New-Object System.Windows.Forms.Button
$btnAutoStart.Text = "Start Auto"
$btnAutoStart.Location = New-Object System.Drawing.Point(610, 104)
$btnAutoStart.Size = New-Object System.Drawing.Size(120, 34)
$btnAutoStart.FlatStyle = "Flat"
$btnAutoStart.ForeColor = [System.Drawing.Color]::White
$btnAutoStart.BackColor = [System.Drawing.Color]::FromArgb(30, 105, 68)
$form.Controls.Add($btnAutoStart)

$btnAutoStop = New-Object System.Windows.Forms.Button
$btnAutoStop.Text = "Stop Auto"
$btnAutoStop.Location = New-Object System.Drawing.Point(740, 104)
$btnAutoStop.Size = New-Object System.Drawing.Size(120, 34)
$btnAutoStop.FlatStyle = "Flat"
$btnAutoStop.ForeColor = [System.Drawing.Color]::White
$btnAutoStop.BackColor = [System.Drawing.Color]::FromArgb(110, 30, 30)
$btnAutoStop.Enabled = $false
$form.Controls.Add($btnAutoStop)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Pick rectangle with left-drag. Fallback: right-click first corner, then right-click second corner. Auto mode samples every N seconds."
$hint.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hint.Location = New-Object System.Drawing.Point(20, 148)
$hint.AutoSize = $true
$form.Controls.Add($hint)

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
  if ($selectedRegion -eq [System.Drawing.Rectangle]::Empty) {
    Write-Log "OCR skipped: select a region first."
    return
  }
  if ($isBusy) {
    return
  }
  $script:isBusy = $true
  try {
    $tmpDir = Join-Path $env:TEMP "pokebot_ocr_region"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
    $imgPath = Join-Path $tmpDir ("capture_{0}.png" -f $stamp)
    $outBase = Join-Path $tmpDir ("capture_{0}" -f $stamp)
    Capture-RegionImage -Region $selectedRegion -Path $imgPath
    $null = & $tesseractExe $imgPath $outBase --psm 6 2>&1
    $txtPath = "$outBase.txt"
    if (Test-Path $txtPath) {
      $text = Get-Content $txtPath -Raw -ErrorAction SilentlyContinue
      $txtLatest.Text = $text
      $preview = ($text -replace "\r?\n", " ").Trim()
      if ($preview.Length -gt 120) {
        $preview = $preview.Substring(0, 120) + "..."
      }
      Write-Log ("OCR OK: {0}" -f $preview)
    }
    else {
      Write-Log "OCR finished but no output text file was generated."
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
    $script:selectedRegion = $rect
    $regionLabel.Text = Format-RegionText -Rect $selectedRegion
    Write-Log $regionLabel.Text
  }
  else {
    Write-Log "Rectangle selection canceled."
  }
})

$btnOnce.Add_Click({
  Run-Ocr
})

$btnAutoStart.Add_Click({
  if ($selectedRegion -eq [System.Drawing.Rectangle]::Empty) {
    [void][System.Windows.Forms.MessageBox]::Show(
      "Pick an OCR rectangle first.",
      "No Region",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  if (-not $tesseractExe) {
    [void][System.Windows.Forms.MessageBox]::Show(
      "Tesseract not found. Set TESSERACT_PATH or add tesseract to PATH first.",
      "Missing Tesseract",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  $timer.Interval = [int]([int]$numInterval.Value * 1000)
  $script:autoEnabled = $true
  $btnAutoStart.Enabled = $false
  $btnAutoStop.Enabled = $true
  Write-Log ("Auto OCR started (every {0}s)." -f [int]$numInterval.Value)
})

$btnAutoStop.Add_Click({
  $script:autoEnabled = $false
  $btnAutoStart.Enabled = $true
  $btnAutoStop.Enabled = $false
  Write-Log "Auto OCR stopped."
})

$form.Add_Shown({
  $regionLabel.Text = Format-RegionText -Rect $selectedRegion
  Write-Log "Ready. Pick a rectangle and run OCR."
  $timer.Start()
})

$form.Add_FormClosing({
  $script:autoEnabled = $false
  $timer.Stop()
})

[void]$form.ShowDialog()
