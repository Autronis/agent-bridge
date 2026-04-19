# uninstall-windows.ps1
# Verwijdert de AutronisPlanAvond Scheduled Task.

param(
    [string]$TaskName = "AutronisPlanAvond"
)

$ErrorActionPreference = "Stop"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] Taak '$TaskName' verwijderd."
} else {
    Write-Host "Geen taak met naam '$TaskName' gevonden — niets te doen."
}
