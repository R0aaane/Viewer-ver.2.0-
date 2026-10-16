param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$EnvFile,
    [Parameter(Mandatory)][string]$Repository,
    [string]$Python = 'python',
    [string]$TaskName = 'PdfViewerHostRelease',
    [string]$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
)
$ErrorActionPreference = 'Stop'
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'Run from the project root' }
if (![IO.Path]::IsPathRooted($InstallRoot) -or ![IO.Path]::IsPathRooted($EnvFile)) {
    throw 'InstallRoot and EnvFile must be absolute paths'
}
$envPath = (Resolve-Path -LiteralPath $EnvFile).Path
$pythonPath = (Get-Command $Python).Source
& $pythonPath -c "import sys,struct; assert sys.version_info[:2] == (3,10) and struct.calcsize('P') == 8, 'Python 3.10 x64 required'"
if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python' }
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$installPath = (Resolve-Path -LiteralPath $InstallRoot).Path
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask -and $existingTask.State -eq 'Running') { throw 'Stop the agent and API before updating bootstrap files' }
Copy-Item -LiteralPath 'tool/host_release_agent.py','tool/host_runtime.py' -Destination $installPath
$config = @{ repository = $Repository; envFile = $envPath; pollSeconds = 60; healthTimeoutSeconds = 120; tokenEnv = 'GITHUB_TOKEN' }
$configPath = Join-Path $installPath 'agent.json'
if (!(Test-Path -LiteralPath $configPath)) {
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
} else {
    $currentConfig = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($currentConfig.repository -ne $Repository -or $currentConfig.envFile -ne $envPath) {
        throw 'Existing configuration differs; review agent.json before changing repository or data settings'
    }
}
# Validate paths/settings before installing anything that starts automatically.
& $pythonPath -c "import sys; sys.path.insert(0, sys.argv[1]); from host_release_agent import Agent; Agent(sys.argv[2])" $installPath $configPath
if ($LASTEXITCODE -ne 0) { throw 'Configuration validation failed; correct agent.json and envFile before registering the task' }
$agentPath = Join-Path $installPath 'host_release_agent.py'
$action = New-ScheduledTaskAction -Execute $pythonPath -Argument "`"$agentPath`" --config `"$configPath`"" -WorkingDirectory $installPath
$trigger = New-ScheduledTaskTrigger -AtStartup
# Password logon allows network access and operation without an interactive login.
$credential = Get-Credential -UserName $User -Message 'Host task account (requires access to PDF and database paths)'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $credential.UserName -Password $credential.GetNetworkCredential().Password `
    -Description 'Download verified host releases; no Git or Flutter builds on this host.' | Out-Null
Write-Host "Registered $TaskName. Stop the legacy updater and server, then Start-ScheduledTask -TaskName $TaskName"
