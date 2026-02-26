[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-StaSession {
  if ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA) {
    return $true
  }

  if (-not $PSCommandPath) {
    throw "PLAY_MANUAL.ps1 must run in STA mode. Re-run with: pwsh -STA -File .\\PLAY_MANUAL.ps1"
  }

  $hostExe = "powershell.exe"
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $hostExe = "pwsh"
  }

  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-STA",
    "-File", "`"$PSCommandPath`""
  )
  Start-Process -FilePath $hostExe -ArgumentList $args | Out-Null
  return $false
}

if (-not (Ensure-StaSession)) {
  return
}

function Resolve-TesseractExecutable {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($env:TESSERACT_PATH) {
    $candidates.Add($env:TESSERACT_PATH)
  }
  $candidates.Add("tesseract")
  $candidates.Add("C:\Program Files\Tesseract-OCR\tesseract.exe")
  $candidates.Add("C:\Program Files (x86)\Tesseract-OCR\tesseract.exe")

  foreach ($candidate in $candidates) {
    try {
      if ($candidate -eq "tesseract") {
        $cmd = Get-Command tesseract -ErrorAction Stop
        if ($cmd -and $cmd.Source) {
          $ver = & $cmd.Source --version 2>$null | Select-Object -First 1
          return @{
            available = $true
            path = $cmd.Source
            source = "PATH"
            version = [string]$ver
          }
        }
      }
      elseif (Test-Path $candidate) {
        $ver = & $candidate --version 2>$null | Select-Object -First 1
        return @{
          available = $true
          path = $candidate
          source = "fallback"
          version = [string]$ver
        }
      }
    }
    catch {
      continue
    }
  }

  return @{
    available = $false
    path = ""
    source = "none"
    version = ""
  }
}

$tesseract = Resolve-TesseractExecutable

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "PokerBotV1 - Manual Play Helper (Preview)"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 640)
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)
$form.BackColor = [System.Drawing.Color]::FromArgb(18, 22, 28)

$header = New-Object System.Windows.Forms.Label
$header.Text = "PokerBotV1 Manual Assistant"
$header.ForeColor = [System.Drawing.Color]::White
$header.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(20, 15)
$header.AutoSize = $true
$form.Controls.Add($header)

$subHeader = New-Object System.Windows.Forms.Label
$subHeader.Text = "Clickable interface preview. Solver/advice actions are placeholders for now."
$subHeader.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 205)
$subHeader.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$subHeader.Location = New-Object System.Drawing.Point(22, 50)
$subHeader.AutoSize = $true
$form.Controls.Add($subHeader)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Status: Ready (preview mode)"
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 170)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.Location = New-Object System.Drawing.Point(22, 78)
$statusLabel.AutoSize = $true
$form.Controls.Add($statusLabel)

$ocrStatusLabel = New-Object System.Windows.Forms.Label
if ($tesseract.available) {
  $ocrStatusLabel.Text = "OCR: Tesseract detected ($($tesseract.path))"
  $ocrStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 170)
}
else {
  $ocrStatusLabel.Text = "OCR: Tesseract not found (set TESSERACT_PATH or install to Program Files)"
  $ocrStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 180, 120)
}
$ocrStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$ocrStatusLabel.Location = New-Object System.Drawing.Point(22, 99)
$ocrStatusLabel.AutoSize = $true
$form.Controls.Add($ocrStatusLabel)

$actionsBox = New-Object System.Windows.Forms.GroupBox
$actionsBox.Text = "Actions"
$actionsBox.ForeColor = [System.Drawing.Color]::White
$actionsBox.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$actionsBox.Location = New-Object System.Drawing.Point(20, 128)
$actionsBox.Size = New-Object System.Drawing.Size(280, 470)
$form.Controls.Add($actionsBox)

$snapshotBox = New-Object System.Windows.Forms.GroupBox
$snapshotBox.Text = "Spot Snapshot (Preview)"
$snapshotBox.ForeColor = [System.Drawing.Color]::White
$snapshotBox.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$snapshotBox.Location = New-Object System.Drawing.Point(320, 128)
$snapshotBox.Size = New-Object System.Drawing.Size(640, 470)
$form.Controls.Add($snapshotBox)

function Set-UiStatus {
  param([string]$Text)
  $statusLabel.Text = "Status: $Text"
}

function New-ActionButton {
  param(
    [string]$Text,
    [int]$Top,
    [scriptblock]$OnClick
  )
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $Text
  $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
  $btn.Size = New-Object System.Drawing.Size(240, 42)
  $btn.Location = New-Object System.Drawing.Point(18, $Top)
  $btn.BackColor = [System.Drawing.Color]::FromArgb(40, 48, 58)
  $btn.ForeColor = [System.Drawing.Color]::White
  $btn.FlatStyle = "Flat"
  $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(65, 80, 100)
  $btn.Add_Click($OnClick)
  return $btn
}

$actionsBox.Controls.Add((New-ActionButton -Text "Start New Hand" -Top 35 -OnClick {
  Set-UiStatus "Start New Hand clicked (placeholder)"
  [void][System.Windows.Forms.MessageBox]::Show(
    "Start New Hand is not wired yet.",
    "Preview",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
}))
$actionsBox.Controls.Add((New-ActionButton -Text "Enter Spot Snapshot" -Top 90 -OnClick {
  Set-UiStatus "Enter Spot Snapshot clicked (placeholder)"
  [void][System.Windows.Forms.MessageBox]::Show(
    "Spot snapshot entry flow is placeholder only.",
    "Preview",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
}))
$actionsBox.Controls.Add((New-ActionButton -Text "Review Last Advice" -Top 145 -OnClick {
  Set-UiStatus "Review Last Advice clicked (placeholder)"
  [void][System.Windows.Forms.MessageBox]::Show(
    "Advice history is not wired yet.",
    "Preview",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
}))
$actionsBox.Controls.Add((New-ActionButton -Text "Settings" -Top 200 -OnClick {
  Set-UiStatus "Settings clicked (placeholder)"
  [void][System.Windows.Forms.MessageBox]::Show(
    "Settings are placeholder only.",
    "Preview",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
}))
$actionsBox.Controls.Add((New-ActionButton -Text "OCR Check" -Top 255 -OnClick {
  if (-not $tesseract.available) {
    Set-UiStatus "OCR check failed (tesseract not found)"
    [void][System.Windows.Forms.MessageBox]::Show(
      "Tesseract binary not found. Set TESSERACT_PATH or install in C:\Program Files\Tesseract-OCR.",
      "OCR Check",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  try {
    $ver = & $tesseract.path --version 2>$null | Select-Object -First 1
    Set-UiStatus "OCR check passed"
    [void][System.Windows.Forms.MessageBox]::Show(
      "Detected: $($tesseract.path)`n$ver",
      "OCR Check",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
  }
  catch {
    Set-UiStatus "OCR check failed to execute binary"
    [void][System.Windows.Forms.MessageBox]::Show(
      "Tesseract found but failed to execute.",
      "OCR Check",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    )
  }
}))
$actionsBox.Controls.Add((New-ActionButton -Text "Exit" -Top 310 -OnClick {
  $form.Close()
}))

function Add-Field {
  param(
    [string]$Label,
    [int]$Y,
    [int]$Height = 30,
    [bool]$Multiline = $false
  )

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = $Label
  $lbl.ForeColor = [System.Drawing.Color]::FromArgb(215, 220, 230)
  $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
  $lbl.Location = New-Object System.Drawing.Point(18, $Y)
  $lbl.AutoSize = $true
  $snapshotBox.Controls.Add($lbl)

  $txt = New-Object System.Windows.Forms.TextBox
  $txt.Location = New-Object System.Drawing.Point(18, ($Y + 18))
  $txt.Size = New-Object System.Drawing.Size(600, $Height)
  $txt.Font = New-Object System.Drawing.Font("Consolas", 10)
  $txt.BackColor = [System.Drawing.Color]::FromArgb(29, 35, 43)
  $txt.ForeColor = [System.Drawing.Color]::White
  $txt.Multiline = $Multiline
  $txt.ReadOnly = $false
  $snapshotBox.Controls.Add($txt)
  return $txt
}

$txtBoard = Add-Field -Label "Board Cards (example: As Kh Td)" -Y 30
$txtPot = Add-Field -Label "Pot Size" -Y 90
$txtStack = Add-Field -Label "Effective Stack" -Y 150
$txtPosition = Add-Field -Label "Position (IP/OOP)" -Y 210
$txtHistory = Add-Field -Label "Action History (one line for now)" -Y 270 -Height 90 -Multiline $true

$btnRow = New-Object System.Windows.Forms.Panel
$btnRow.Location = New-Object System.Drawing.Point(18, 390)
$btnRow.Size = New-Object System.Drawing.Size(600, 52)
$snapshotBox.Controls.Add($btnRow)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Save Snapshot (placeholder)"
$btnSave.Size = New-Object System.Drawing.Size(280, 40)
$btnSave.Location = New-Object System.Drawing.Point(0, 5)
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(40, 48, 58)
$btnSave.ForeColor = [System.Drawing.Color]::White
$btnSave.FlatStyle = "Flat"
$btnSave.Add_Click({
  Set-UiStatus "Save Snapshot clicked (placeholder)"
  [void][System.Windows.Forms.MessageBox]::Show(
    "Snapshot save is not wired yet.",
    "Preview",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
})
$btnRow.Controls.Add($btnSave)

$btnAdvice = New-Object System.Windows.Forms.Button
$btnAdvice.Text = "Request Advice (placeholder)"
$btnAdvice.Size = New-Object System.Drawing.Size(280, 40)
$btnAdvice.Location = New-Object System.Drawing.Point(305, 5)
$btnAdvice.BackColor = [System.Drawing.Color]::FromArgb(20, 95, 62)
$btnAdvice.ForeColor = [System.Drawing.Color]::White
$btnAdvice.FlatStyle = "Flat"
$btnAdvice.Add_Click({
  Set-UiStatus "Request Advice clicked (placeholder)"
  [void][System.Windows.Forms.MessageBox]::Show(
    "Solver advice call is not wired yet.",
    "Preview",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
})
$btnRow.Controls.Add($btnAdvice)

[void]$form.ShowDialog()
