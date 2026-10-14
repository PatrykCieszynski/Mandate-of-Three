param([string]$GodotExecutable = '', [switch]$InstallAddon, [switch]$NativeRelease)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (!$GodotExecutable) { $GodotExecutable = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64.exe' }
$taskProfile = if ($NativeRelease) { 'release' } else { 'debug' }
$taskDirectory = Join-Path $taskRoot ('.godot/verification/auction-soci-s0-windows-' + $taskProfile)
$taskPrepare = @((Join-Path $PSScriptRoot 'prepare-auction-soci-s0.py'), '--fixture-directory', $taskDirectory)
if ($InstallAddon) { $taskPrepare += '--install' }
& python @taskPrepare
if ($LASTEXITCODE -ne 0) { throw 'S0 pinned release verification failed' }
New-Item -ItemType Directory -Force -Path $taskDirectory | Out-Null
$taskOut = $taskDirectory + '.out.log'
$taskErr = $taskDirectory + '.err.log'
$taskPreviousAppData = $env:APPDATA
$taskProcess = $null
try {
    $env:APPDATA = Join-Path $taskDirectory 'appdata'
    $taskArguments = '--headless --path "' + $taskRoot + '" --mode=world-server res://tests/auction_soci_s0.tscn --s0-project-root="' + $taskRoot + '" --s0-directory="' + $taskDirectory + '"'
    if ($NativeRelease) { $taskArguments += ' --s0-native-profile=release' }
    $taskProcess = Start-Process -FilePath $GodotExecutable -ArgumentList $taskArguments -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr
    $taskExpected = Join-Path $taskRoot ('.godot/verification/soci-release/package/addons/godot_soci/bin/windows/godot_soci.windows.template_' + $taskProfile + '.x86_64.dll')
    $taskLibrary = ''
    $taskDeadline = (Get-Date).AddSeconds(10)
    while (!$taskLibrary -and (Get-Date) -lt $taskDeadline -and !$taskProcess.HasExited) {
        # Use the engine directly by default, avoiding the console-launcher child
        # and privileged process/WMI enumeration. The module's exact path is checked.
        $taskCandidates = @($taskProcess.Id)
        foreach ($taskId in $taskCandidates) {
            $taskModules = @((Get-Process -Id $taskId -ErrorAction SilentlyContinue).Modules | Where-Object { $_.FileName -eq $taskExpected })
            if ($taskModules.Count) { $taskLibrary = $taskModules[0].FileName; break }
        }
        if (!$taskLibrary) { Start-Sleep -Milliseconds 100 }
    }
    # Whole-run watchdog allows collecting all benchmark samples after a query
    # has FAILED the unchanged 2-second budget. It is not a query timeout/retry.
    if (!$taskProcess.WaitForExit(300000)) { throw 'S0 fixture process deadline; no safe backup/acceptance claimed' }
    $taskProcess.Refresh()
    if ($taskLibrary) { Write-Output "AUCTION_S0_LIBRARY $taskLibrary SHA256=$((Get-FileHash -LiteralPath $taskLibrary -Algorithm SHA256).Hash)" }
    $taskOutput = (Get-Content -LiteralPath $taskOut -Raw) + (Get-Content -LiteralPath $taskErr -Raw)
    Get-Content -LiteralPath $taskOut | Where-Object { $_ -match 'AUCTION_S0_' }
    if ($taskLibrary -ne $taskExpected -or $taskProcess.ExitCode -ne 0 -or $taskOutput -notmatch 'AUCTION_S0_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Caller thread|database is locked|database table is locked|Object is being used by another thread') {
        throw "S0 failed: $taskOut / $taskErr; report.json retains measured deadline failures"
    }
    Write-Output "Auction SOCI S0 Windows native $taskProfile (Debug engine): PASS"
} finally {
    # No native cancellation in v0.4.0: do not force-destroy an active SQL session
    # on watchdog failure. The fixture can continue its diagnostic drain.
    if ($taskProcess -and !$taskProcess.HasExited) { Write-Warning "S0 process $($taskProcess.Id) remains alive for diagnostic drain; no completed/backup-safe result is claimed" }
    $env:APPDATA = $taskPreviousAppData
}
