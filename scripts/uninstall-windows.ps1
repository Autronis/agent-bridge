# uninstall-windows.ps1
# Verwijdert de AutronisPlanAvond en AutronisWeekrapport Scheduled Tasks.

param(
    [string]$TaskName     = "AutronisPlanAvond",
    [string]$WeekTaskName = "AutronisWeekrapport"
)

$ErrorActionPreference = "Stop"

foreach ($name in @($TaskName, $WeekTaskName)) {
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "[OK] Taak '$name' verwijderd."
    } else {
        Write-Host "Geen taak met naam '$name' gevonden — niets te doen."
    }
}
