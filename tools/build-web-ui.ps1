param([string]$NodeExecutable = 'node', [switch]$Tests)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskUi = Join-Path $taskRoot 'source/client/ui_web'
$taskCompiler = Join-Path $taskUi 'node_modules/typescript/bin/tsc'
if (-not (Test-Path -LiteralPath $taskCompiler)) { throw 'Install Web UI development dependencies first: cd source/client/ui_web; npm ci' }
& $NodeExecutable $taskCompiler -p (Join-Path $taskUi 'tsconfig.json')
if ($LASTEXITCODE -ne 0) { throw 'Production Web UI TypeScript build failed' }
if ($Tests) {
    & $NodeExecutable $taskCompiler -p (Join-Path $taskUi 'tsconfig.tests.json')
    if ($LASTEXITCODE -ne 0) { throw 'Web UI TypeScript test build failed' }
}
Write-Output 'Web UI TypeScript build: PASS (static ES modules)'
