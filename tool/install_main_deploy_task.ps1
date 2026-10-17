param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$Python = 'python',
    [string]$TaskName = 'PdfViewerMainDeploy',
    [string]$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
)
$ErrorActionPreference = 'Stop'
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'Run from the project root' }
if (![IO.Path]::IsPathRooted($InstallRoot)) { throw 'InstallRoot must be absolute' }
$pythonPath = (Get-Command $Python).Source
& $pythonPath -c "import sys; assert sys.version_info >= (3,10), 'Python 3.10+ required'"
if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python' }
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask -and $existingTask.State -eq 'Running') { throw 'Stop the main deployment task before updating it' }
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$installPath = (Resolve-Path -LiteralPath $InstallRoot).Path
$sourceConfig = (Resolve-Path -LiteralPath $ConfigFile).Path
$configPath = Join-Path $installPath 'main-deploy.json'
if ($sourceConfig -ne $configPath) {
    if (Test-Path -LiteralPath $configPath) { throw 'Existing main-deploy.json is preserved; pass it as ConfigFile to re-register' }
    Copy-Item -LiteralPath $sourceConfig -Destination $configPath
}
Copy-Item -LiteralPath 'tool/main_pc_deploy.py','tool/deploy_transport.py','tool/package_host_release.py','tool/host_release_agent.py','tool/windows_process_job.py' -Destination $installPath
& $pythonPath (Join-Path $installPath 'main_pc_deploy.py') --config $configPath --check
if ($LASTEXITCODE -ne 0) { throw 'Configuration validation failed' }
$credential = Get-Credential -UserName $User -Message 'Build account with Flutter, GitHub SSH and host SFTP access'
$scriptPath = Join-Path $installPath 'main_pc_deploy.py'
$action = New-ScheduledTaskAction -Execute $pythonPath -Argument "`"$scriptPath`" --config `"$configPath`"" -WorkingDirectory $installPath
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Settings $settings -User $credential.UserName -Password $credential.GetNetworkCredential().Password `
    -Description 'Watch pushed commits, build locally and deliver host bundles over SFTP.' -Force | Out-Null
Write-Host "Registered $TaskName. Start-ScheduledTask -TaskName $TaskName"
