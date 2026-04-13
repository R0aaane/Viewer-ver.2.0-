[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

Write-Host "Project root: $(Get-Location)"

if (-not (Test-Path pubspec.yaml)) {
  throw "pubspec.yaml was not found. Run this script from the project root."
}

$sourceIcon = 'assets/icons/app_icon.png'
if (-not (Test-Path $sourceIcon)) {
  throw "Source icon was not found: $sourceIcon"
}

flutter pub get
if ($LASTEXITCODE -ne 0) {
  throw "flutter pub get failed."
}

dart run flutter_launcher_icons
if ($LASTEXITCODE -ne 0) {
  throw "flutter_launcher_icons failed."
}

Write-Host "Launcher icons updated from $sourceIcon"
