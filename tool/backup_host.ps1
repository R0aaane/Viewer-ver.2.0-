param(
    [Parameter(Mandatory = $true)][ValidateSet('create', 'restore', 'repair')][string]$Action,
    [string]$Destination,
    [string]$Source,
    [string]$DataDir
)

$ErrorActionPreference = 'Stop'
Write-Output (Get-Location)
if (-not (Test-Path -LiteralPath (Join-Path (Get-Location) 'pubspec.yaml'))) {
    throw 'Run from the Flutter project root.'
}
if (-not $DataDir) { $DataDir = $env:MEDIA_SERVER_DATA_DIR }
if (-not $DataDir) {
    $DataDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PDF_Viewer\host_api'
}
$python = Join-Path (Split-Path -Parent $PSScriptRoot) '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'python' }
$arguments = @('-m', 'server.backup_host', '--data-dir', $DataDir, $Action)
if ($Action -eq 'restore') {
    if (-not $Source -or -not $Destination) { throw 'Provide -Source and a new -Destination.' }
    $arguments += @($Source, $Destination)
} elseif ($Action -eq 'create') {
    if (-not $Destination) { throw 'Provide a new -Destination.' }
    $arguments += $Destination
}
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Host maintenance failed. Keep the host stopped and inspect the reported error.' }
