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
$watchFolder = ""
$outputFolder = ""
$isRunning = $false
$lastProcessedUtc = @{}
$queuedPaths = New-Object System.Collections.Generic.HashSet[string]
$fsw = $null
$eventCreated = $null
$eventChanged = $null
$eventRenamed = $null

function Write-Log {
  param([string]$Message)
  $stamp = (Get-Date).ToString("HH:mm:ss")
  $logBox.AppendText("[$stamp] $Message`r`n")
}

function Is-ImageFile {
  param([string]$Path)
  $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  return $ext -in @(".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp")
}

function Invoke-OcrOnFile {
  param([string]$FilePath)
  if (-not (Test-Path $FilePath)) {
    return
  }
  if (-not (Is-ImageFile -Path $FilePath)) {
    return
  }
  $item = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
  if (-not $item) {
    return
  }

  $pathKey = $item.FullName.ToLowerInvariant()
  $writeUtc = $item.LastWriteTimeUtc
  if ($lastProcessedUtc.ContainsKey($pathKey) -and $lastProcessedUtc[$pathKey] -ge $writeUtc) {
    return
  }

  $safeBase = [IO.Path]::GetFileNameWithoutExtension($item.Name)
  $safeBase = $safeBase -replace "[^a-zA-Z0-9_\-\.]", "_"
  $outBase = Join-Path $outputFolder ("{0}.{1}" -f $safeBase, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

  try {
    $null = & $tesseractExe $item.FullName $outBase --psm 6 2>&1
    $txtPath = "$outBase.txt"
    if (Test-Path $txtPath) {
      $preview = (Get-Content $txtPath -Raw -ErrorAction SilentlyContinue)
      if ($preview.Length -gt 120) {
        $preview = $preview.Substring(0, 120) + "..."
      }
      $preview = $preview -replace "\r?\n", " "
      Write-Log ("OCR OK: {0} -> {1}" -f $item.Name, $preview.Trim())
    }
    else {
      Write-Log ("OCR done but no text output for: {0}" -f $item.Name)
    }
    $lastProcessedUtc[$pathKey] = $writeUtc
  }
  catch {
    Write-Log ("OCR ERROR: {0} :: {1}" -f $item.Name, $_.Exception.Message)
  }
}

function Stop-Watcher {
  if ($eventCreated) { Unregister-Event -SourceIdentifier $eventCreated.Name -ErrorAction SilentlyContinue; $eventCreated = $null }
  if ($eventChanged) { Unregister-Event -SourceIdentifier $eventChanged.Name -ErrorAction SilentlyContinue; $eventChanged = $null }
  if ($eventRenamed) { Unregister-Event -SourceIdentifier $eventRenamed.Name -ErrorAction SilentlyContinue; $eventRenamed = $null }
  if ($fsw) {
    $fsw.EnableRaisingEvents = $false
    $fsw.Dispose()
    $fsw = $null
  }
}

function Start-Watcher {
  Stop-Watcher
  $script:fsw = New-Object IO.FileSystemWatcher
  $script:fsw.Path = $watchFolder
  $script:fsw.Filter = "*.*"
  $script:fsw.IncludeSubdirectories = $false
  $script:fsw.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, CreationTime, Size'
  $script:fsw.EnableRaisingEvents = $true

  $script:eventCreated = Register-ObjectEvent -InputObject $script:fsw -EventName Created -Action {
    if ($Event.SourceEventArgs -and $Event.SourceEventArgs.FullPath) {
      [void]$script:queuedPaths.Add($Event.SourceEventArgs.FullPath)
    }
  }
  $script:eventChanged = Register-ObjectEvent -InputObject $script:fsw -EventName Changed -Action {
    if ($Event.SourceEventArgs -and $Event.SourceEventArgs.FullPath) {
      [void]$script:queuedPaths.Add($Event.SourceEventArgs.FullPath)
    }
  }
  $script:eventRenamed = Register-ObjectEvent -InputObject $script:fsw -EventName Renamed -Action {
    if ($Event.SourceEventArgs -and $Event.SourceEventArgs.FullPath) {
      [void]$script:queuedPaths.Add($Event.SourceEventArgs.FullPath)
    }
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Tesseract Test Runner"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 660)
$form.MinimumSize = New-Object System.Drawing.Size(980, 660)
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 30)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Tesseract OCR Folder Watch Test"
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$tessStatus = New-Object System.Windows.Forms.Label
$tessStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tessStatus.Location = New-Object System.Drawing.Point(20, 44)
$tessStatus.AutoSize = $true
if ($tesseractExe) {
  $tessStatus.Text = "Tesseract: $tesseractExe"
  $tessStatus.ForeColor = [System.Drawing.Color]::FromArgb(140, 220, 170)
}
else {
  $tessStatus.Text = "Tesseract: NOT FOUND (set TESSERACT_PATH or add to PATH)"
  $tessStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 180, 120)
}
$form.Controls.Add($tessStatus)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = "Watch Folder"
$lblFolder.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblFolder.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblFolder.Location = New-Object System.Drawing.Point(20, 78)
$lblFolder.AutoSize = $true
$form.Controls.Add($lblFolder)

$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(20, 98)
$txtFolder.Size = New-Object System.Drawing.Size(720, 28)
$txtFolder.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtFolder.BackColor = [System.Drawing.Color]::FromArgb(30, 36, 44)
$txtFolder.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($txtFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Select Folder"
$btnBrowse.Location = New-Object System.Drawing.Point(750, 96)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 32)
$btnBrowse.FlatStyle = "Flat"
$btnBrowse.ForeColor = [System.Drawing.Color]::White
$btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(46, 56, 68)
$form.Controls.Add($btnBrowse)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = "Open Folder"
$btnOpen.Location = New-Object System.Drawing.Point(856, 96)
$btnOpen.Size = New-Object System.Drawing.Size(100, 32)
$btnOpen.FlatStyle = "Flat"
$btnOpen.ForeColor = [System.Drawing.Color]::White
$btnOpen.BackColor = [System.Drawing.Color]::FromArgb(46, 56, 68)
$form.Controls.Add($btnOpen)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = "Trigger Mode"
$lblMode.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblMode.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblMode.Location = New-Object System.Drawing.Point(20, 140)
$lblMode.AutoSize = $true
$form.Controls.Add($lblMode)

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = "DropDownList"
$cmbMode.Location = New-Object System.Drawing.Point(20, 160)
$cmbMode.Size = New-Object System.Drawing.Size(280, 30)
$cmbMode.Font = New-Object System.Drawing.Font("Segoe UI", 10)
[void]$cmbMode.Items.Add("Every 5 seconds (polling)")
[void]$cmbMode.Items.Add("On file movement (watcher)")
$cmbMode.SelectedIndex = 1
$form.Controls.Add($cmbMode)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Text = "Polling Interval (seconds)"
$lblInterval.ForeColor = [System.Drawing.Color]::FromArgb(220, 225, 235)
$lblInterval.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblInterval.Location = New-Object System.Drawing.Point(320, 140)
$lblInterval.AutoSize = $true
$form.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(320, 160)
$numInterval.Size = New-Object System.Drawing.Size(120, 30)
$numInterval.Minimum = 1
$numInterval.Maximum = 60
$numInterval.Value = 5
$numInterval.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($numInterval)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Start"
$btnStart.Location = New-Object System.Drawing.Point(460, 158)
$btnStart.Size = New-Object System.Drawing.Size(120, 34)
$btnStart.FlatStyle = "Flat"
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(20, 110, 72)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop"
$btnStop.Location = New-Object System.Drawing.Point(590, 158)
$btnStop.Size = New-Object System.Drawing.Size(120, 34)
$btnStop.FlatStyle = "Flat"
$btnStop.ForeColor = [System.Drawing.Color]::White
$btnStop.BackColor = [System.Drawing.Color]::FromArgb(110, 30, 30)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Recommendation: use 'On file movement' for real-time snapshots; use polling only if watcher misses events."
$hint.ForeColor = [System.Drawing.Color]::FromArgb(175, 185, 200)
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hint.Location = New-Object System.Drawing.Point(20, 200)
$hint.AutoSize = $true
$form.Controls.Add($hint)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 230)
$logBox.Size = New-Object System.Drawing.Size(936, 370)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(14, 18, 23)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 245)
$form.Controls.Add($logBox)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.ShowNewFolderButton = $true

$btnBrowse.Add_Click({
  if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $txtFolder.Text = $folderDialog.SelectedPath
    Write-Log ("Folder selected: {0}" -f $txtFolder.Text)
  }
})

$btnOpen.Add_Click({
  if ($txtFolder.Text -and (Test-Path $txtFolder.Text)) {
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($txtFolder.Text)`""
  }
})

$timer.Add_Tick({
  if (-not $isRunning) {
    return
  }
  if (-not $watchFolder -or -not (Test-Path $watchFolder)) {
    return
  }

  if ($cmbMode.SelectedIndex -eq 0) {
    # Polling mode.
    $files = Get-ChildItem -Path $watchFolder -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
      Invoke-OcrOnFile -FilePath $f.FullName
    }
    return
  }

  # Watcher mode: process queued changed paths.
  $currentQueue = @($queuedPaths)
  foreach ($p in $currentQueue) {
    [void]$queuedPaths.Remove($p)
    Invoke-OcrOnFile -FilePath $p
  }
})

$btnStart.Add_Click({
  if (-not $tesseractExe) {
    [void][System.Windows.Forms.MessageBox]::Show(
      "Tesseract not found. Set TESSERACT_PATH or add tesseract to PATH first.",
      "Missing Tesseract",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  if (-not $txtFolder.Text -or -not (Test-Path $txtFolder.Text)) {
    [void][System.Windows.Forms.MessageBox]::Show(
      "Select a valid watch folder first.",
      "Missing Folder",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }

  $script:watchFolder = $txtFolder.Text
  $script:outputFolder = Join-Path $watchFolder "_ocr_out"
  New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
  $lastProcessedUtc.Clear()
  $queuedPaths.Clear()

  if ($cmbMode.SelectedIndex -eq 1) {
    Start-Watcher
    Write-Log "Watcher mode enabled (Created/Changed/Renamed events)."
  }
  else {
    Stop-Watcher
    Write-Log ("Polling mode enabled (every {0}s)." -f [int]$numInterval.Value)
  }

  $timer.Interval = [int]([int]$numInterval.Value * 1000)
  $script:isRunning = $true
  $btnStart.Enabled = $false
  $btnStop.Enabled = $true
  Write-Log ("Started OCR test. Watch={0} Output={1}" -f $watchFolder, $outputFolder)
})

$btnStop.Add_Click({
  $script:isRunning = $false
  $timer.Stop()
  Stop-Watcher
  $btnStart.Enabled = $true
  $btnStop.Enabled = $false
  Write-Log "Stopped OCR test."
})

$form.Add_Shown({
  Write-Log "Ready. Select a folder and click Start."
  $timer.Start()
})

$form.Add_FormClosing({
  $script:isRunning = $false
  $timer.Stop()
  Stop-Watcher
})

[void]$form.ShowDialog()
