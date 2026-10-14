param([string]$CmakeExecutable = 'cmake', [string]$Generator = 'Visual Studio 18 2026', [string[]]$Variants = @('353-o2-nodebug','353-od-debug','353-o2-debug','353-od-nodebug','351-o2-nodebug'))
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskNative = Join-Path $taskRoot '.godot/verification/auction-p0/native'
$taskBuild = Join-Path $taskNative 'build'
if (!(Test-Path -LiteralPath (Join-Path $taskNative 'source-provenance.json'))) { throw 'Run python tests/prepare-auction-p0.py --download explicitly first' }
foreach ($taskVariant in $Variants) {
    if ($taskVariant -notmatch '^(351|353)-(o2|od)-(debug|nodebug)$') { throw 'Invalid controlled P0 variant' }
    $taskSource = if ($Matches[1] -eq '351') { 'gdsqlite/src/sqlite' } else { 'sqlite3534' }
    $taskOpt = $Matches[2].ToUpperInvariant()
    $taskDebug = if ($Matches[3] -eq 'debug') { 'ON' } else { 'OFF' }
    $taskDestination = Join-Path $taskNative ('variants/' + $taskVariant)
    New-Item -ItemType Directory -Force -Path $taskDestination | Out-Null
    & $CmakeExecutable -S $taskNative -B $taskBuild -G $Generator -A x64 "-DP0_SQLITE_SOURCE=$taskSource" "-DP0_SQLITE_OPT=$taskOpt" "-DP0_SQLITE_DEBUG=$taskDebug" *> (Join-Path $taskDestination 'configure.log')
    if ($LASTEXITCODE -ne 0) { throw "P0 configure failed: $taskVariant" }
    & $CmakeExecutable --build $taskBuild --config Release --parallel 4 *> (Join-Path $taskDestination 'build.log')
    if ($LASTEXITCODE -ne 0) { throw "P0 build failed: $taskVariant" }
    if (Select-String -LiteralPath (Join-Path $taskDestination 'build.log') -Pattern 'D9002|ignoring unknown option') { throw "P0 rejected compiler flags: $taskVariant" }
    Copy-Item -LiteralPath (Join-Path $taskBuild 'bin/Release/p0_soci.dll') -Destination (Join-Path $taskDestination 'p0_soci.dll')
    Copy-Item -LiteralPath (Join-Path $taskBuild 'Release/p0_sqlite.lib') -Destination (Join-Path $taskDestination 'sqlite3.lib')
    Copy-Item -LiteralPath (Join-Path $taskBuild 'configuration.json') -Destination $taskDestination
    Copy-Item -LiteralPath (Join-Path $taskBuild 'p0_sqlite.vcxproj') -Destination $taskDestination
    Copy-Item -LiteralPath (Join-Path $taskBuild 'p0_soci.vcxproj') -Destination $taskDestination
    $taskDescriptor = "[configuration]`nentry_symbol=`"godot_soci_library_init`"`ncompatibility_minimum=`"4.7`"`n[libraries]`nwindows.x86_64.single.debug=`"./p0_soci.dll`"`n"
    [IO.File]::WriteAllText((Join-Path $taskDestination 'soci-p0.gdextension'),$taskDescriptor,[Text.UTF8Encoding]::new($false))
    Write-Output "AUCTION_P0_BUILD $taskVariant SHA256=$((Get-FileHash -LiteralPath (Join-Path $taskDestination 'p0_soci.dll')).Hash)"
}
