param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$TaskName = 'PdfViewerHostAutoUpdate',
    [string]$Remote = 'origin',
    [string]$Branch = '',
    [int]$PollSeconds = 60,
    [string]$Python = 'python',
    [string]$ServerHost = '0.0.0.0',
    [int]$ServerPort = 8000,
    [string]$AppExePath = 'build\windows\x64\runner\Release\pdf_viewer.exe',
    [switch]$SkipWindowsBuild,
    [switch]$SkipHostAppRestart,
    [switch]$BuildAndroidApk
)

$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath $ProjectRoot
Write-Host "cwd: $(Get-Location)"
if (-not (Test-Path -LiteralPath 'pubspec.yaml' -PathType Leaf)) {
    throw "pubspec.yaml was not found. Run this script from the Flutter project root."
}
Write-Host "pubspec.yaml: found"
if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw "Branch was not specified and the current branch could not be detected."
    }
}

$updateScript = Join-Path $ProjectRoot 'tool\host_auto_update.ps1'
if (-not (Test-Path -LiteralPath $updateScript -PathType Leaf)) {
    throw "host_auto_update.ps1 was not found."
}

$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', "`"$updateScript`"",
    '-ProjectRoot', "`"$ProjectRoot`"",
    '-Remote', $Remote,
    '-Branch', $Branch,
    '-PollSeconds', [string]$PollSeconds,
    '-Python', "`"$Python`"",
    '-ServerHost', $ServerHost,
    '-ServerPort', [string]$ServerPort,
    '-AppExePath', "`"$AppExePath`""
) -join ' '

if ($SkipWindowsBuild) {
    $arguments = "$arguments -SkipWindowsBuild"
}

if ($SkipHostAppRestart) {
    $arguments = "$arguments -SkipHostAppRestart"
}

if ($BuildAndroidApk) {
    $arguments = "$arguments -BuildAndroidApk"
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description 'Auto-pull, build, and restart the PDF Viewer host server.' `
    -Force | Out-Null

Write-Host "scheduled task: registered $TaskName"
Write-Host "start now: Start-ScheduledTask -TaskName $TaskName"
