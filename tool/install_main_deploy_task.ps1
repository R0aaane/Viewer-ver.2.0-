param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$Python = 'python',
    [string]$TaskName = 'PdfViewerMainDeploy',
    [string]$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
    [ValidateSet('Password', 'S4U')][string]$LogonType = 'Password'
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
$scriptPath = Join-Path $installPath 'main_pc_deploy.py'
$action = New-ScheduledTaskAction -Execute $pythonPath -Argument "`"$scriptPath`" --config `"$configPath`"" -WorkingDirectory $installPath
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$registration = @{
    TaskName = $TaskName
    Action = $action
    Trigger = New-ScheduledTaskTrigger -AtStartup
    Settings = $settings
    Description = 'Watch pushed commits, build locally and deliver host bundles over SFTP.'
    Force = $true
}
if ($LogonType -eq 'S4U') {
    # Verify GitHub/SFTP signing and Flutter in a real S4U task before choosing this mode.
    $registration.Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
} else {
    $credential = Get-Credential -UserName $User -Message 'Build account with Flutter, GitHub SSH and host SFTP access'
    $registration.User = $credential.UserName
    $registration.Password = $credential.GetNetworkCredential().Password
}
Register-ScheduledTask @registration | Out-Null
Write-Host "Registered $TaskName. Start-ScheduledTask -TaskName $TaskName"
