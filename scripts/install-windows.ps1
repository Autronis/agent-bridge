# install-windows.ps1
# Registreert een Windows Scheduled Task die elke dag op $time
# `plan-avond.sh` aanroept via bash.exe (git-bash).
#
# Leest ~/.config/autronis/agent-bridge.json voor:
#   - user (sem|syb) -> bepaalt tijd
#   - atlas_start_time / autro_start_time
#
# Usage (vanuit PowerShell):
#   pwsh -ExecutionPolicy Bypass -File scripts\install-windows.ps1
# Of via bash:
#   bash scripts/install.sh   (detecteert Windows en delegeert hierheen)

param(
    [string]$TaskName        = "AutronisPlanAvond",
    [string]$WeekTaskName    = "AutronisWeekrapport"
)

$ErrorActionPreference = "Stop"

# -------- Resolve paths --------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $HOME ".config\autronis\agent-bridge.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config niet gevonden: $ConfigPath`nKopieer config/settings.example.json ernaartoe en pas aan."
    exit 1
}

# -------- Parse config --------
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$UserName = $Config.user
if ($UserName -ne "sem" -and $UserName -ne "syb") {
    Write-Error "Fout: 'user' in $ConfigPath moet 'sem' of 'syb' zijn (kreeg: '$UserName')"
    exit 1
}

$Time = if ($UserName -eq "sem") { $Config.atlas_start_time } else { $Config.autro_start_time }
if (-not $Time) {
    Write-Error "Fout: geen start-tijd gevonden voor user=$UserName"
    exit 1
}

# Validate HH:MM
if ($Time -notmatch '^\d{1,2}:\d{2}$') {
    Write-Error "Fout: tijd '$Time' is niet in HH:MM formaat"
    exit 1
}

# -------- Find bash.exe --------
$BashCandidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
$BashPath = $null
foreach ($cand in $BashCandidates) {
    if (Test-Path $cand) { $BashPath = $cand; break }
}
if (-not $BashPath) {
    $which = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($which) { $BashPath = $which.Source }
}
if (-not $BashPath) {
    Write-Error "Fout: bash.exe niet gevonden. Installeer Git for Windows (https://git-scm.com/download/win)."
    exit 1
}
Write-Host "Bash gevonden op: $BashPath"

# -------- Translate POSIX path in plan-avond.sh to Windows path (we hand it to bash.exe) --------
# bash.exe -c accepteert zowel Windows als POSIX paden; we gebruiken Windows path voor duidelijkheid.
$PlanScriptWin = Join-Path $ProjectDir "scripts\plan-avond.sh"
if (-not (Test-Path $PlanScriptWin)) {
    Write-Error "Fout: plan-avond.sh niet gevonden: $PlanScriptWin"
    exit 1
}

$WeekScriptWin = Join-Path $ProjectDir "scripts\weekrapport.sh"
if (-not (Test-Path $WeekScriptWin)) {
    Write-Error "Fout: weekrapport.sh niet gevonden: $WeekScriptWin"
    exit 1
}

# bash.exe wil forward-slashes of zonder-drive. Converteer backslashes.
$PlanScriptBash = $PlanScriptWin -replace '\\', '/'
$WeekScriptBash = $WeekScriptWin -replace '\\', '/'

# Ensure logs dir bestaat (plan-avond.sh doet dit ook, maar veilig om nu vast te maken).
$LogsDir = Join-Path $ProjectDir "logs"
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir | Out-Null
}

# -------- Shared settings/principal --------
# Draai alleen bij ingelogde interactieve sessie — komt overeen met macOS
# LimitLoadToSessionType=Aqua. Geen wachtwoord nodig, gebruiker doet het zelf.
$TaskUser = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
$Principal = New-ScheduledTaskPrincipal `
    -UserId $TaskUser `
    -LogonType Interactive `
    -RunLevel Limited

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# -------- Build plan-avond task --------
# Gebruik login-shell (-l) zodat ~/.bashrc en PATH additions (python3, curl, claude.exe) geladen worden.
# Task Scheduler geeft de -Argument string door aan bash.exe met Windows-argument-parsing.
# Dubbele quotes beschermen het script-pad als het spaties bevat.
$PlanBashCmd = '-l -c "' + $PlanScriptBash + '"'

$PlanAction = New-ScheduledTaskAction `
    -Execute $BashPath `
    -Argument $PlanBashCmd `
    -WorkingDirectory $ProjectDir

$PlanTrigger = New-ScheduledTaskTrigger -Daily -At $Time

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Bestaande taak '$TaskName' gevonden — wordt overschreven..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $PlanAction `
    -Trigger $PlanTrigger `
    -Principal $Principal `
    -Settings $Settings `
    -Description "Autronis Agent Bridge — dagelijks avondplan (Atlas/Autro)" | Out-Null

# -------- Build weekrapport task (zondag 19:00) --------
$WeekBashCmd = '-l -c "' + $WeekScriptBash + '"'

$WeekAction = New-ScheduledTaskAction `
    -Execute $BashPath `
    -Argument $WeekBashCmd `
    -WorkingDirectory $ProjectDir

# Wekelijks, elke zondag om 19:00.
$WeekTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "19:00"

$existingWeek = Get-ScheduledTask -TaskName $WeekTaskName -ErrorAction SilentlyContinue
if ($existingWeek) {
    Write-Host "Bestaande taak '$WeekTaskName' gevonden — wordt overschreven..."
    Unregister-ScheduledTask -TaskName $WeekTaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $WeekTaskName `
    -Action $WeekAction `
    -Trigger $WeekTrigger `
    -Principal $Principal `
    -Settings $Settings `
    -Description "Autronis Agent Bridge — wekelijks screen-time rapport (zondag 19:00)" | Out-Null

Write-Host ""
Write-Host "[OK] Taken geregistreerd voor user=$UserName:"
Write-Host "     - $TaskName (plan-avond, dagelijks om $Time)"
Write-Host "     - $WeekTaskName (weekrapport, zondag 19:00)"
Write-Host ""
Write-Host "Verifieer:"
Write-Host "  Get-ScheduledTask -TaskName $TaskName, $WeekTaskName"
Write-Host ""
Write-Host "Handmatig direct uitvoeren (test):"
Write-Host "  Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Start-ScheduledTask -TaskName $WeekTaskName"
Write-Host ""
Write-Host "Log na run (in bash):"
Write-Host "  tail -100 $($LogsDir -replace '\\', '/')/plan-avond_*.log"
Write-Host "  tail -100 $($LogsDir -replace '\\', '/')/weekrapport_*.log"
