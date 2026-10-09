param(
    [Parameter(Mandatory=$true)][string]$PlaywrightModule,
    [Parameter(Mandatory=$true)][string]$BrowserExecutable,
    [string]$NodeExecutable = 'node'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $taskRoot 'tools/build-web-ui.ps1') -NodeExecutable $NodeExecutable -Tests
& $NodeExecutable (Join-Path $taskRoot 'source/client/ui_web/.tests/core_ui_browser.mjs') $PlaywrightModule $BrowserExecutable
if ($LASTEXITCODE -ne 0) { throw 'Core UI browser milestone check failed' }
& $NodeExecutable (Join-Path $taskRoot 'source/client/ui_web/node_modules/typescript/bin/tsc') -p (Join-Path $taskRoot 'source/client/ui_web/tsconfig.dev.json')
if ($LASTEXITCODE -ne 0) { throw 'Browser preview TypeScript build failed' }
& $NodeExecutable (Join-Path $taskRoot 'source/client/ui_web/.tests/ui_preview_browser.mjs') $PlaywrightModule $BrowserExecutable
if ($LASTEXITCODE -ne 0) { throw 'Browser development preview check failed' }
