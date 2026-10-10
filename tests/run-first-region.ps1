$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
$taskLog = Join-Path $taskLogs 'first-region.log'
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=world-server res://tests/first_region.tscn --quit-after 600 *> $taskLog
$taskExit = $LASTEXITCODE
$taskOutput = Get-Content -LiteralPath $taskLog -Raw
if ($taskExit -ne 0 -or $taskOutput -notmatch 'FIRST_REGION_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Assertion failed') { throw "First region check failed: $taskLog" }
Write-Output 'First region: PASS (headless production content/navigation; visual pacing remains manual)'
