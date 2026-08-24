param(
    [int]$TtlMinutes = 60,
    [int]$PruneTtlMinutes = 1440
)
$bash = (Get-Command bash -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot "bin\orb-cleanup.sh"
$action = New-ScheduledTaskAction -Execute $bash `
    -Argument "`"$script`" --ttl $TtlMinutes --prune --prune-ttl $PruneTtlMinutes --yes"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "OrbsCleanup" -Action $action -Trigger $trigger `
    -Settings $settings -Description "Stops and prunes idle OpenCode orbs" -Force
Write-Host "Scheduled task OrbsCleanup registered (cleanup every 15 min, ttl ${TtlMinutes} min, prune ${PruneTtlMinutes} min)."
