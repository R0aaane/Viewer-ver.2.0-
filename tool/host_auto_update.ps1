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
    [string]$AppExePath = 'build\windows\x64\runner\Release\pdf_viewer.exe',
    [switch]$BuildAndroidApk,
    [switch]$SkipFlutterBuild,
    [switch]$SkipWindowsBuild,
    [switch]$SkipHostAppRestart,
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

function Add-ArgumentPair {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [string]$Value
    )

    $Arguments.Add($Name)
    $Arguments.Add($Value)
}

function Invoke-ScriptRelaunch {
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add($PSCommandPath)
    Add-ArgumentPair -Arguments $arguments -Name '-ProjectRoot' -Value $ProjectRoot
    Add-ArgumentPair -Arguments $arguments -Name '-Remote' -Value $Remote
    Add-ArgumentPair -Arguments $arguments -Name '-Branch' -Value $Branch
    Add-ArgumentPair -Arguments $arguments -Name '-PollSeconds' -Value ([string]$PollSeconds)
    Add-ArgumentPair -Arguments $arguments -Name '-Python' -Value $Python
    Add-ArgumentPair -Arguments $arguments -Name '-ServerHost' -Value $ServerHost
    Add-ArgumentPair -Arguments $arguments -Name '-ServerPort' -Value ([string]$ServerPort)
    Add-ArgumentPair -Arguments $arguments -Name '-EnvFile' -Value $EnvFile
    Add-ArgumentPair -Arguments $arguments -Name '-ServerLog' -Value $ServerLog
    Add-ArgumentPair -Arguments $arguments -Name '-AppExePath' -Value $AppExePath

    if ($BuildAndroidApk) { $arguments.Add('-BuildAndroidApk') }
    if ($SkipFlutterBuild) { $arguments.Add('-SkipFlutterBuild') }
    if ($SkipWindowsBuild) { $arguments.Add('-SkipWindowsBuild') }
    if ($SkipHostAppRestart) { $arguments.Add('-SkipHostAppRestart') }
    if ($Once) { $arguments.Add('-Once') }

    Write-Host "script: updated; relaunching"
    & powershell.exe @arguments
    exit $LASTEXITCODE
}

function Restart-IfUpdateScriptChanged {
    param(
        [string]$FromRevision,
        [string]$ToRevision
    )

    $changedFiles = & git diff --name-only $FromRevision $ToRevision -- tool/host_auto_update.ps1 tool/install_host_auto_update_task.ps1
    if ($changedFiles) {
        Invoke-ScriptRelaunch
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
    $processIds = @()

    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        $serverPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($serverPid -match '^\d+$') {
            $processIds += [int]$serverPid
        }
    }

    $listeners = Get-NetTCPConnection -LocalPort $ServerPort -State Listen -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        if ($listener.OwningProcess -gt 0) {
            $processIds += [int]$listener.OwningProcess
        }
    }

    foreach ($processId in ($processIds | Select-Object -Unique)) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force
            Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
            Write-Host "server: stopped pid=$($process.Id)"
        }
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

function Resolve-AppExePath {
    if ([System.IO.Path]::IsPathRooted($AppExePath)) {
        return $AppExePath
    }
    return (Join-Path (Get-Location).Path $AppExePath)
}

function Stop-HostApp {
    if ($SkipHostAppRestart) {
        return
    }

    $pidFile = Join-Path 'data' 'host_app.pid'
    $processIds = @()
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        $appPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($appPid -match '^\d+$') {
            $processIds += [int]$appPid
        }
    }

    $resolvedAppExe = Resolve-AppExePath
    $escapedAppExe = $resolvedAppExe.Replace('\', '\\').Replace("'", "''")
    $matchingApps = Get-CimInstance Win32_Process -Filter "ExecutablePath = '$escapedAppExe'" -ErrorAction SilentlyContinue
    foreach ($app in $matchingApps) {
        $processIds += [int]$app.ProcessId
    }

    foreach ($processId in ($processIds | Select-Object -Unique)) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force
            Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
            Write-Host "app: stopped pid=$($process.Id)"
        }
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

function Start-HostApp {
    if ($SkipHostAppRestart) {
        return
    }

    $resolvedAppExe = Resolve-AppExePath
    if (-not (Test-Path -LiteralPath $resolvedAppExe -PathType Leaf)) {
        Write-Warning "app: executable was not found: $resolvedAppExe"
        return
    }

    Stop-HostApp
    $process = Start-Process `
        -FilePath $resolvedAppExe `
        -WorkingDirectory (Split-Path -Parent $resolvedAppExe) `
        -PassThru

    Set-Content -LiteralPath (Join-Path 'data' 'host_app.pid') -Value $process.Id
    Write-Host "app: started pid=$($process.Id)"
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

        if (-not $SkipWindowsBuild) {
            Stop-HostApp
            Write-Host "build: flutter build windows"
            Invoke-Checked -FilePath 'flutter' -Arguments @('build', 'windows')
        }

        if ($BuildAndroidApk) {
            Publish-AndroidApkUpdate
        }
    }

    Start-HostServer
    Start-HostApp
}

function Get-PubspecVersion {
    $line = Get-Content -LiteralPath 'pubspec.yaml' |
        Where-Object { $_ -match '^version:\s*(.+)$' } |
        Select-Object -First 1
    if (-not $line) {
        throw "pubspec.yaml version was not found."
    }
    return ($line -replace '^version:\s*', '').Trim()
}

function Publish-AndroidApkUpdate {
    $version = Get-PubspecVersion
    Write-Host "build: flutter build apk"
    Invoke-Checked -FilePath 'flutter' -Arguments @('build', 'apk', '--release')

    $source = Join-Path 'build' 'app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "APK was not found: $source"
    }

    $updatesDir = Join-Path 'data' 'app_updates'
    New-Item -ItemType Directory -Force -Path $updatesDir | Out-Null

    $safeVersion = $version -replace '[^0-9A-Za-z._+-]+', '_'
    $fileName = "pdf_viewer_${safeVersion}_android.apk"
    $target = Join-Path $updatesDir $fileName
    Copy-Item -LiteralPath $source -Destination $target -Force

    $item = Get-Item -LiteralPath $target
    $manifest = [ordered]@{
        version = $version
        fileName = $fileName
        originalFileName = 'pdf_viewer_android.apk'
        sizeBytes = $item.Length
        uploadedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $manifest |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $updatesDir 'latest.json') -Encoding UTF8
    Write-Host "app-update: published $fileName version=$version"
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
    Restart-IfUpdateScriptChanged -FromRevision $currentRevision -ToRevision $remoteRevision
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
    Restart-IfUpdateScriptChanged -FromRevision $remoteRevision -ToRevision $latestRevision
    $remoteRevision = $latestRevision
    Build-And-Restart
}
