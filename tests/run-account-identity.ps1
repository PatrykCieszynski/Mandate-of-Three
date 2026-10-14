param([switch]$WithSession)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Force $taskLogs | Out-Null
$taskCases = @('account_identity')
if ($WithSession) { $taskCases += 'account_identity_session' }
foreach ($taskCase in $taskCases) {
    $taskMode = if ($taskCase -eq 'account_identity') { 'world-server' } else { 'client' }
    $taskMarker = if ($taskCase -eq 'account_identity') { 'ACCOUNT_IDENTITY_OK' } else { 'ACCOUNT_IDENTITY_SESSION_OK' }
    $taskLog = Join-Path $taskLogs "$taskCase.log"
    & (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=$taskMode "res://tests/$taskCase.tscn" --quit-after 4000 *> $taskLog
    $taskExit = $LASTEXITCODE
    $taskOutput = Get-Content -LiteralPath $taskLog -Raw
    if ($taskExit -ne 0 -or $taskOutput -notmatch $taskMarker -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Assertion failed') { throw "Identity check failed: $taskLog" }
    Write-Output "$taskCase`: PASS"
}
