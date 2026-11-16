# Registers (or removes) the Task Scheduler job that runs start-window.ps1
# at 06:00 Monday to Friday, the Windows equivalent of the launchd plist.
#
#   powershell -ExecutionPolicy Bypass -File install-task.ps1
#   powershell -ExecutionPolicy Bypass -File install-task.ps1 -Uninstall
#   powershell -ExecutionPolicy Bypass -File install-task.ps1 -At 07:30

param(
    [switch]$Uninstall,
    [string]$At = '06:00'
)

$TaskName = 'Claude window anchor'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "Removed scheduled task '$TaskName'."
    exit 0
}

$Script = Join-Path $PSScriptRoot 'start-window.ps1'
if (-not (Test-Path $Script)) { throw "Not found: $Script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""

$trigger = New-ScheduledTaskTrigger -Weekly -At $At `
    -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday

# StartWhenAvailable: if the PC was off or asleep at the set time, run as soon
# as it can (like launchd does). The script itself waits for the network.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -MultipleInstances IgnoreNew

# Runs as you, only while you are signed in, so it uses your claude install and token.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Sends Claude a one-word prompt to start the usage window early.' -Force | Out-Null

Write-Output "Registered '$TaskName' for $At, Monday to Friday."
Write-Output "Test now:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Output "Log:       $env:LOCALAPPDATA\claude-window\claude-window.log"
