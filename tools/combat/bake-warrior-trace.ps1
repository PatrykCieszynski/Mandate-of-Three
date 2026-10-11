$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$taskLogDirectory = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Force -Path $taskLogDirectory | Out-Null
$taskLog = Join-Path $taskLogDirectory 'trace-bake.log'
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --quit-after 600 --path $taskRoot --mode=client --script res://tools/combat/bake_warrior_trace.gd *> $taskLog
$taskOutput = Get-Content -LiteralPath $taskLog -Raw
if ($LASTEXITCODE -ne 0 -or $taskOutput -notmatch 'WARRIOR_TRACE_BAKE_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error') { throw "Warrior trace bake failed: $taskLog" }
Write-Output 'Warrior traces: baked and placement-invariance checks passed'
