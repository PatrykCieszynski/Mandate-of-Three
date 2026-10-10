$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
$taskLog = Join-Path $taskLogs 'camera-v1.log'
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=world-server res://tests/camera_v1.tscn --quit-after 600 *> $taskLog
$taskExit = $LASTEXITCODE
$taskOutput = Get-Content -LiteralPath $taskLog -Raw
if ($taskExit -ne 0 -or $taskOutput -notmatch 'CAMERA_V1_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Assertion failed') { throw "Camera check failed: $taskLog" }
Write-Output 'Camera v1: PASS (headless collision/picking contracts; visual feel remains manual)'
