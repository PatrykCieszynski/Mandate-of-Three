param([string]$NodeExecutable = 'node')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
& $NodeExecutable --test (Join-Path $PSScriptRoot 'web_bridge.test.mjs') (Join-Path $PSScriptRoot 'core_ui.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Web bridge tests failed' }
$taskLog = Join-Path $taskLogs 'web-ui.log'
& (Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe') --headless --path $taskRoot --mode=world-server res://tests/web_ui_bridge.tscn --quit-after 120 *> $taskLog
if ($LASTEXITCODE -ne 0 -or (Get-Content $taskLog -Raw) -notmatch 'WEB_UI_PROTOCOL_OK' -or (Get-Content $taskLog -Raw) -match 'SCRIPT ERROR|Assertion failed') { throw "Web UI contract failed: $taskLog" }
Write-Output 'Web UI contracts: PASS (root headless, no CEF setup or window)'
