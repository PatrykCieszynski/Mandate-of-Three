param([switch]$WithSession)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Force $taskLogs | Out-Null
$taskCases = @('account_identity', 'gateway_lifecycle', 'gateway_menu_lifecycle', 'world_session_admission')
if ($WithSession) { $taskCases += 'account_identity_session' }
foreach ($taskCase in $taskCases) {
    $taskMode = if ($taskCase -notin @('account_identity_session','gateway_menu_lifecycle')) { 'world-server' } else { 'client' }
    $taskMarker = if ($taskCase -eq 'gateway_menu_lifecycle') { 'GATEWAY_MENU_LIFECYCLE_OK' } elseif ($taskCase -eq 'gateway_lifecycle') { 'GATEWAY_LIFECYCLE_OK' } elseif ($taskCase -eq 'account_identity') { 'ACCOUNT_IDENTITY_OK' } else { 'ACCOUNT_IDENTITY_SESSION_OK' }
    if ($taskCase -eq 'world_session_admission') { $taskMarker = 'WORLD_SESSION_ADMISSION_OK' }
    $taskLog = Join-Path $taskLogs "$taskCase.log"
    $taskAppData = $env:APPDATA
    $taskLocalAppData = $env:LOCALAPPDATA
    try {
        if ($taskCase -eq 'gateway_menu_lifecycle') {
            $taskProfile = Join-Path $taskLogs 'gateway-menu-profile'
            New-Item -ItemType Directory -Force $taskProfile | Out-Null
            $env:APPDATA = $taskProfile
            $env:LOCALAPPDATA = $taskProfile
        }
        & (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --max-fps 120 --path $taskRoot --mode=$taskMode "res://tests/$taskCase.tscn" --quit-after 4000 *> $taskLog
    } finally {
        $env:APPDATA = $taskAppData
        $env:LOCALAPPDATA = $taskLocalAppData
    }
    $taskExit = $LASTEXITCODE
    $taskOutput = Get-Content -LiteralPath $taskLog -Raw
    if ($taskExit -ne 0 -or $taskOutput -notmatch $taskMarker -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Assertion failed') { throw "Identity check failed: $taskLog" }
    Write-Output "$taskCase`: PASS"
    if ($taskCase -eq 'gateway_menu_lifecycle') {
        & (Join-Path $taskRoot 'tools/clean-dev-artifacts.ps1') -VerificationPaths @('gateway-menu-profile')
    }
}
