$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
$taskLog = Join-Path $taskLogs 'metin-encounter.log'
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=world-server res://tests/metin_encounter.tscn --quit-after 600 *> $taskLog
$taskExit = $LASTEXITCODE
$taskOutput = Get-Content -LiteralPath $taskLog -Raw
if ($taskExit -ne 0 -or $taskOutput -notmatch 'METIN_ENCOUNTER_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Assertion failed') { throw "Metin check failed: $taskLog" }
Write-Output 'Metin encounter: PASS (headless threshold/contribution/reward/respawn contracts)'
