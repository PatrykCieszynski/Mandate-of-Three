param(
    [Parameter(Mandatory=$true)][string]$PlaywrightModule,
    [Parameter(Mandatory=$true)][string]$BrowserExecutable,
    [string]$NodeExecutable = 'node',
    [string]$ScreenshotDirectory
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $taskRoot 'tools/build-web-ui.ps1') -NodeExecutable $NodeExecutable -Tests
$taskArgs = @((Join-Path $taskRoot 'source/client/ui_web/.tests/shop_browser.mjs'),$PlaywrightModule,$BrowserExecutable)
if ($ScreenshotDirectory) { $taskArgs += $ScreenshotDirectory }
& $NodeExecutable @taskArgs
if ($LASTEXITCODE -ne 0) { throw 'Shop browser milestone check failed' }
