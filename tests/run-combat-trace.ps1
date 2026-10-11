$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Force -Path $taskLogs | Out-Null
$taskLog = Join-Path $taskLogs 'trace-test.log'
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=world-server res://tests/combat_trace.tscn --quit-after 300 *> $taskLog
$taskOutput = Get-Content -LiteralPath $taskLog -Raw
if ($LASTEXITCODE -ne 0 -or $taskOutput -notmatch 'COMBAT_TRACE_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error') { throw "Trace contract failed: $taskLog" }
Write-Output 'trace geometry/broadphase: PASS'
& (Join-Path $PSScriptRoot 'run-combat.ps1') -Scene combat_trace_network -MarkerPrefix TRACE
