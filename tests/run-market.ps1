param([string]$Scene='market_custody', [string]$Marker='MARKET_CUSTODY_OK')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskLogs=Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Force $taskLogs | Out-Null
$taskLog=Join-Path $taskLogs "$Scene.log"
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=world-server "res://tests/$Scene.tscn" --quit-after 1200 *> $taskLog
$taskExit=$LASTEXITCODE
$taskOutput=Get-Content -LiteralPath $taskLog -Raw
if ($taskExit -ne 0 -or $taskOutput -notmatch $Marker -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Assertion failed') { throw "Market check failed: $taskLog" }
Write-Output "$Scene`: PASS"
