param(
    [string]$NodeExecutable = "node",
    [switch]$WithBrowser,
    [ValidateSet('Compatibility','Vulkan','Software')][string]$Mode = 'Vulkan'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskBaseline = Join-Path $taskRoot '.godot/cef-spike/baseline'
if(-not (Test-Path (Join-Path $taskBaseline 'project.godot'))){throw 'Run tools/cef_ui_spike/setup.py first'}
$taskLog = Join-Path $taskRoot '.godot/cef-spike/protocol.log'
$taskImportLog = Join-Path $taskRoot '.godot/cef-spike/protocol-import.log'
& $NodeExecutable --test (Join-Path $taskRoot 'tests/cef_ui/web_bridge.test.mjs')
if($LASTEXITCODE -ne 0){throw 'Web bridge tests failed'}
& $taskExe --headless --path $taskBaseline --editor --import --quit *> $taskImportLog
if($LASTEXITCODE -ne 0 -or (Get-Content $taskImportLog -Raw) -match 'SCRIPT ERROR|Parse Error'){throw 'Protocol import failed'}
& $taskExe --headless --path $taskBaseline --script res://tests/cef_ui/router.gd --quit-after 600 *> $taskLog
$taskText = Get-Content $taskLog -Raw
if($LASTEXITCODE -ne 0 -or $taskText -notmatch 'WEB_UI_PROTOCOL_OK' -or $taskText -notmatch 'WEB_UI_POINTER_OK' -or $taskText -match 'SCRIPT ERROR|Assertion failed'){throw 'Godot protocol tests failed'}
Write-Output 'Web UI protocol/application tests: PASS (no CEF runtime, no window)'
if($WithBrowser){& (Join-Path $PSScriptRoot 'run-cef-ui.ps1') -Mode $Mode}
