param(
    [Parameter(Mandatory=$true)][string]$PlaywrightModule,
    [Parameter(Mandatory=$true)][string]$BrowserExecutable,
    [string]$NodeExecutable = 'node'
)
$ErrorActionPreference = 'Stop'
& $NodeExecutable (Join-Path $PSScriptRoot 'core_ui_browser.cjs') $PlaywrightModule $BrowserExecutable
if ($LASTEXITCODE -ne 0) { throw 'Core UI browser milestone check failed' }
