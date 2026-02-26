[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Header {
  Clear-Host
  Write-Host "==========================================" -ForegroundColor Cyan
  Write-Host " PokerBotV1 - Manual Play Helper (Preview)" -ForegroundColor Cyan
  Write-Host "==========================================" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "Status: UI shell only (no live advice actions yet)." -ForegroundColor Yellow
  Write-Host "Purpose: prepare the user-facing flow before solver hookup." -ForegroundColor Yellow
  Write-Host ""
}

function Show-Menu {
  Write-Host "Choose an option:" -ForegroundColor Green
  Write-Host "  1) Start New Hand (placeholder)"
  Write-Host "  2) Enter Spot Snapshot (placeholder)"
  Write-Host "  3) Review Last Advice (placeholder)"
  Write-Host "  4) Settings (placeholder)"
  Write-Host "  Q) Quit"
  Write-Host ""
}

function Show-Placeholder {
  param(
    [Parameter(Mandatory = $true)][string]$Title
  )
  Write-Host ""
  Write-Host "[$Title]" -ForegroundColor Magenta
  Write-Host "This section is not wired yet." -ForegroundColor DarkYellow
  Write-Host "Next milestone: connect this flow to bridge + solver calls." -ForegroundColor DarkYellow
  Write-Host ""
  Write-Host "Press Enter to return to menu..." -NoNewline
  [void](Read-Host)
}

while ($true) {
  Show-Header
  Show-Menu
  $choice = (Read-Host "Selection").Trim().ToLowerInvariant()

  switch ($choice) {
    "1" { Show-Placeholder -Title "Start New Hand" }
    "2" { Show-Placeholder -Title "Enter Spot Snapshot" }
    "3" { Show-Placeholder -Title "Review Last Advice" }
    "4" { Show-Placeholder -Title "Settings" }
    "q" { break }
    default {
      Write-Host ""
      Write-Host "Invalid selection: $choice" -ForegroundColor Red
      Start-Sleep -Milliseconds 900
    }
  }
}

Write-Host ""
Write-Host "Manual helper closed." -ForegroundColor Cyan
