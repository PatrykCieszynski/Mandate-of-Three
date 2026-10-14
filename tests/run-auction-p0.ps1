param([ValidatePattern('^(debug|release|release041|diag-(351|353)-(o2|od)-(debug|nodebug))$')][string]$Profile = 'release041', [ValidateSet('all','baseline','lookup','baseline_analyzed','lookup_analyzed','migrated','migrated_analyzed')][string]$State = 'all', [ValidateSet('all','default','broad','medium','selective','rare','empty','descending','pagination','tie_pagination')][string]$Case = 'all', [ValidateSet('frame','signal')][string]$WaitMode='signal', [switch]$Seed, [switch]$Probe, [switch]$SkipInstalled, [string]$GodotExecutable = '')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (!$GodotExecutable) { $GodotExecutable = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64.exe' }
$taskDirectory = Join-Path $taskRoot ('.godot/verification/auction-p0/' + $Profile + '-' + $State)
if ($Case -ne 'all') { $taskDirectory+='-'+$Case }
if ($WaitMode -ne 'frame') { $taskDirectory+='-'+$WaitMode }
$taskPreparer=if ($Profile -eq 'release041') {'prepare-auction-soci-041.py'} else {'prepare-auction-soci-s0.py'}
& python (Join-Path $PSScriptRoot $taskPreparer) --fixture-directory $taskDirectory *> (Join-Path $taskRoot '.godot/verification/auction-p0-pin.log')
if ($LASTEXITCODE -ne 0) { throw 'P0 release provenance/path guard failed' }
New-Item -ItemType Directory -Force -Path $taskDirectory | Out-Null
$taskPreviousAppData=$env:APPDATA
$taskProcess=$null
try {
    $env:APPDATA=Join-Path $taskDirectory 'appdata'
    $taskExtension = 'res://.godot/verification/soci-release/soci-release-library.gdextension'
    $taskLibrary = Join-Path $taskRoot '.godot/verification/soci-release/package/addons/godot_soci/bin/windows/godot_soci.windows.template_release.x86_64.dll'
    if ($Profile -eq 'release041') {
        $taskExtension='res://.godot/verification/soci-release-041/soci-release-library.gdextension'
        $taskLibrary=Join-Path $taskRoot '.godot/verification/soci-release-041/package/addons/godot_soci/bin/windows/godot_soci.windows.template_release.x86_64.dll'
    } elseif ($Profile -eq 'debug') {
        $taskExtension='res://.godot/verification/soci-release/package/addons/godot_soci/soci.gdextension'
        $taskLibrary=Join-Path $taskRoot '.godot/verification/soci-release/package/addons/godot_soci/bin/windows/godot_soci.windows.template_debug.x86_64.dll'
    } elseif ($Profile.StartsWith('diag-')) {
        $taskVariant=$Profile.Substring(5)
        $taskBuildLog=Join-Path $taskRoot ('.godot/verification/auction-p0/native/variants/'+$taskVariant+'/build.log')
        if (Select-String -LiteralPath $taskBuildLog -Pattern 'D9002|ignoring unknown option') { throw 'P0 rejects invalid native experiment flags before launch' }
        $taskExtension='res://.godot/verification/auction-p0/native/variants/'+$taskVariant+'/soci-p0.gdextension'
        $taskLibrary=Join-Path $taskRoot ('.godot/verification/auction-p0/native/variants/'+$taskVariant+'/p0_soci.dll')
    }
    $taskArgs='--headless --path "'+$taskRoot+'" --mode=world-server res://tests/auction_soci_p0.tscn --p0-profile='+$Profile+' --p0-state='+$State+' --p0-wait='+$WaitMode+' --p0-extension='+$taskExtension+' --p0-directory="'+$taskDirectory+'"'
    if ($Seed) { $taskArgs+=' --p0-seed=1' }
    if ($Probe) { $taskArgs+=' --p0-probe=1' }
    if ($SkipInstalled) { $taskArgs+=' --p0-skip-installed=1' }
    if ($Case -ne 'all') { $taskArgs+=' --p0-case='+$Case }
    $taskOut=$taskDirectory+'.out.log';$taskErr=$taskDirectory+'.err.log'
    $taskProcess=Start-Process -FilePath $GodotExecutable -ArgumentList $taskArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr -WorkingDirectory $taskRoot
    $taskLoaded=$false
    $taskDeadline=(Get-Date).AddSeconds(10)
    while (!$Seed -and !$taskLoaded -and !$taskProcess.HasExited -and (Get-Date) -lt $taskDeadline) {
        # A Process instance caches Modules; obtain a fresh snapshot on each poll.
        $taskLoaded=@((Get-Process -Id $taskProcess.Id -ErrorAction SilentlyContinue).Modules | Where-Object FileName -eq $taskLibrary).Count -gt 0
        if (!$taskLoaded) { Start-Sleep -Milliseconds 100 }
    }
    # Same whole-process watchdog as S0. Split the matrix by State for slow builds;
    # each individual measured SQL/result delivery always retains its 2s gate.
    if (!$taskProcess.WaitForExit(300000)) { throw 'P0 watchdog failed; process left alive for diagnostic drain' }
    $taskProcess.Refresh()
    $taskText=(Get-Content -LiteralPath $taskOut -Raw)+(Get-Content -LiteralPath $taskErr -Raw)
    $taskMarker=if ($Seed) {'AUCTION_P0_SEED_OK'} else {'AUCTION_P0_FINISHED'}
    if (!$Seed) { Write-Output "AUCTION_P0_LIBRARY loaded=$taskLoaded path=$taskLibrary SHA256=$((Get-FileHash -LiteralPath $taskLibrary).Hash)" }
    Get-Content -LiteralPath $taskOut | Where-Object { $_ -match 'AUCTION_P0_' }
    if ((!$Seed -and !$taskLoaded) -or $taskText -notmatch $taskMarker -or $taskText -match 'SCRIPT ERROR|Parse Error|Caller thread|database is locked|Object is being used by another thread') { throw "P0 invalid execution: $taskOut / $taskErr" }
    if ($taskProcess.ExitCode -ne 0) { throw "P0 measured FAIL (2-second gate): $taskDirectory/raw.json" }
    Write-Output "Auction P0 $Profile/$State : PASS"
} finally {
    if ($taskProcess -and !$taskProcess.HasExited) { Write-Warning "P0 process $($taskProcess.Id) remains alive; never force-destroy an active native session" }
    $env:APPDATA=$taskPreviousAppData
}
