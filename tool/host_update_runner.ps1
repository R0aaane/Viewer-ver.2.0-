param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$Remote = 'origin',
    [string]$Branch = '',
    [int]$ServerPort = 8000,
    [string]$Python = 'python',
    [switch]$BuildAndroidApk,
    [int]$InitialDelaySeconds = 2
)

$ErrorActionPreference = 'Stop'

function Write-UpdateStatus {
    param(
        [string]$State,
        [string]$Message,
        [int]$PidValue = 0
    )

    $dataDir = Join-Path $ProjectRoot 'data'
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $payload = [ordered]@{
        state = $State
        message = $Message
    }
    if ($PidValue -gt 0) {
        $payload.pid = $PidValue
    }
    if ($State -eq 'running') {
        $payload.startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    } else {
        $payload.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $statusPath = Join-Path $dataDir 'host_update_status.json'
    $tempPath = "$statusPath.tmp"
    $payload | ConvertTo-Json | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $statusPath -Force
}

try {
    Start-Sleep -Seconds $InitialDelaySeconds
    Set-Location -LiteralPath $ProjectRoot
    if (-not (Test-Path -LiteralPath 'pubspec.yaml' -PathType Leaf)) {
        throw "pubspec.yaml was not found. Run this runner from the Flutter project root."
    }

    Write-UpdateStatus -State 'running' -Message 'host update is running' -PidValue $PID

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $ProjectRoot 'tool\host_auto_update.ps1'),
        '-ProjectRoot',
        $ProjectRoot,
        '-Remote',
        $Remote,
        '-ServerPort',
        [string]$ServerPort,
        '-Python',
        $Python,
        '-Once'
    )
    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        $arguments += @('-Branch', $Branch)
    }
    if ($BuildAndroidApk) {
        $arguments += '-BuildAndroidApk'
    }

    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "host_auto_update.ps1 failed with exit code $LASTEXITCODE"
    }

    Write-UpdateStatus -State 'succeeded' -Message 'host update completed'
    exit 0
} catch {
    Write-UpdateStatus -State 'failed' -Message $_.Exception.Message
    exit 1
}
