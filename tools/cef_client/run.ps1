param([switch]$SetupOnly)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$taskProject = $taskRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
python (Join-Path $PSScriptRoot 'setup.py')
if ($LASTEXITCODE -ne 0) { throw 'CEF client setup failed' }
$taskImportLog = Join-Path $taskRoot '.godot/cef-client/import.log'
& $taskExe --headless --path $taskProject --editor --import --quit *> $taskImportLog
if ($LASTEXITCODE -ne 0 -or (Get-Content -LiteralPath $taskImportLog -Raw) -match 'SCRIPT ERROR|Parse Error') { throw "CEF client import failed: $taskImportLog" }
if (-not $SetupOnly) { & $taskExe --path $taskProject --rendering-method mobile --rendering-driver vulkan --mode=client }
