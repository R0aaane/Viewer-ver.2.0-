param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$Remote = 'origin',
    [string]$Branch = '',
    [int]$PollSeconds = 60,
    [string]$Python = 'python',
    [string]$ServerHost = '0.0.0.0',
    [int]$ServerPort = 8000,
    [string]$EnvFile = 'server\.env',
    [string]$ServerLog = 'data\host_server.log',
    [switch]$SkipFlutterBuild,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

function Enter-ProjectRoot {
    Set-Location -LiteralPath $ProjectRoot
    Write-Host "cwd: $(Get-Location)"
    if (-not (Test-Path -LiteralPath 'pubspec.yaml' -PathType Leaf)) {
        throw "pubspec.yaml was not found. Run this script from the Flutter project root."
    }
    Write-Host "pubspec.yaml: found"
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            return
        }

        $parts = $line.Split('=', 2)
        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        if ($name.Length -gt 0) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Stop-HostServer {
    $pidFile = Join-Path 'data' 'host_server.pid'
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        return
    }

    $serverPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($serverPid -match '^\d+$') {
        $process = Get-Process -Id ([int]$serverPid) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force
            Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

function Start-HostServer {
    New-Item -ItemType Directory -Force -Path 'data' | Out-Null
    Import-DotEnv -Path $EnvFile

    Stop-HostServer

    $arguments = @(
        '-m', 'uvicorn', 'server.main:app',
        '--host', $ServerHost,
        '--port', [string]$ServerPort
    )
    $process = Start-Process `
        -FilePath $Python `
        -ArgumentList $arguments `
        -WorkingDirectory (Get-Location).Path `
        -RedirectStandardOutput $ServerLog `
        -RedirectStandardError "$ServerLog.err" `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -LiteralPath (Join-Path 'data' 'host_server.pid') -Value $process.Id
    Write-Host "server: started pid=$($process.Id)"
}

function Build-And-Restart {
    Write-Host "dependencies: pip install -r requirements.txt"
    Invoke-Checked -FilePath $Python -Arguments @('-m', 'pip', 'install', '-r', 'requirements.txt')

    if (-not $SkipFlutterBuild) {
        Write-Host "build: flutter build web"
        Invoke-Checked -FilePath 'flutter' -Arguments @('build', 'web')
    }

    Start-HostServer
}

function Get-Revision {
    param([string]$Ref)
    return (& git rev-parse $Ref).Trim()
}

Enter-ProjectRoot
if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw "Branch was not specified and the current branch could not be detected."
    }
}
Invoke-Checked -FilePath 'git' -Arguments @('fetch', $Remote, $Branch)
$remoteRef = "$Remote/$Branch"
$currentRevision = Get-Revision -Ref 'HEAD'
$remoteRevision = Get-Revision -Ref $remoteRef

if ($currentRevision -ne $remoteRevision) {
    Write-Host "update: $currentRevision -> $remoteRevision"
    Invoke-Checked -FilePath 'git' -Arguments @('pull', '--ff-only', $Remote, $Branch)
    Build-And-Restart
} else {
    Write-Host "update: none"
    Start-HostServer
}

while (-not $Once) {
    Start-Sleep -Seconds $PollSeconds
    Invoke-Checked -FilePath 'git' -Arguments @('fetch', $Remote, $Branch)
    $latestRevision = Get-Revision -Ref $remoteRef
    if ($latestRevision -eq $remoteRevision) {
        continue
    }

    Write-Host "update: $remoteRevision -> $latestRevision"
    Invoke-Checked -FilePath 'git' -Arguments @('pull', '--ff-only', $Remote, $Branch)
    $remoteRevision = $latestRevision
    Build-And-Restart
}
