param(
    [Parameter(Mandatory = $true)][ValidateSet('issue', 'list', 'revoke')][string]$Action,
    [string]$Value,
    [string]$DataDir
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Write-Output (Get-Location)
if (-not (Test-Path -LiteralPath (Join-Path (Get-Location) 'pubspec.yaml'))) {
    throw 'Run from the Flutter project root.'
}
if (-not $DataDir) { $DataDir = $env:MEDIA_SERVER_DATA_DIR }
if (-not $DataDir) {
    $DataDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PDF_Viewer\host_api'
}
$python = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'python' }
$arguments = @('-m', 'server.manage_devices', '--data-dir', $DataDir, $Action)
if ($Action -ne 'list') {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Provide a device name or device ID with -Value.' }
    $arguments += $Value
}
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Device token management failed.' }
