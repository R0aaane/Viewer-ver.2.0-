param([string]$InstallRoot = 'D:\PdfViewerHost')
$ErrorActionPreference = 'Stop'
Get-Location
if (!(Test-Path pubspec.yaml)) { throw 'Run from the project root' }
$root = (Resolve-Path -LiteralPath $InstallRoot).Path
$releaseTask = Get-ScheduledTask -TaskName PdfViewerHostRelease
$existing = Get-ScheduledTask -TaskName PdfViewerHostConsole -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') { throw 'Console is already running; leave production API unchanged' }
$pythonPath = $releaseTask.Actions[0].Execute
Copy-Item -LiteralPath 'tool/host_console.py','tool/host_console.html' -Destination $root
$action = New-ScheduledTaskAction -Execute $pythonPath -Argument "`"$root\host_console.py`" --root `"$root`"" -WorkingDirectory $root
$principal = New-ScheduledTaskPrincipal -UserId $releaseTask.Principal.UserId -LogonType S4U -RunLevel Limited
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName PdfViewerHostConsole -Action $action -Principal $principal -Trigger $trigger `
    -Settings $settings -Description 'Local host console on 127.0.0.1:18091; bounded graceful API recovery.' -Force | Out-Null
Start-ScheduledTask -TaskName PdfViewerHostConsole
$desktop = [Environment]::GetFolderPath('Desktop')
[IO.File]::WriteAllText((Join-Path $desktop 'PDF Viewer Console.url'), "[InternetShortcut]`r`nURL=http://127.0.0.1:18091/`r`n", [Text.UTF8Encoding]::new($false))
Write-Host 'Console task started: http://127.0.0.1:18091/'
