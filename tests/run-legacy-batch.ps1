param([switch]$Capture)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
$taskDev = Join-Path $taskRoot 'dev_assets/legacy'
$taskStash = Join-Path $taskLogs 'pre-batch-dev'
$taskConfig = Get-Content (Join-Path $taskRoot 'tools/legacy_assets/local.json') -Raw | ConvertFrom-Json
$taskGenerated = if ([IO.Path]::IsPathRooted($taskConfig.generated_root)) { [IO.Path]::GetFullPath($taskConfig.generated_root) } else { [IO.Path]::GetFullPath((Join-Path $taskRoot $taskConfig.generated_root)) }
$taskReport = Get-Content (Join-Path $taskGenerated '.pipeline/reports/first_batch.json') -Raw | ConvertFrom-Json
$taskSuccessful = @($taskReport.results | Where-Object status -In @('SUCCESS','SKIPPED'))
$taskFailed = @($taskReport.results | Where-Object status -NotIn @('SUCCESS','SKIPPED'))
if ($taskSuccessful.Count -lt 20 -or $taskReport.results.Count -ne 23) { throw 'Expected a representative 23-asset batch with at least 20 successes' }
$taskAllowed = ($taskFailed.id -join ',')
function Invoke-BatchCheck([string]$Name, [string]$Extra, [switch]$Gpu) {
    $taskArgs = '--path "' + $taskRoot + '" --mode=client res://tests/legacy_batch_visual.tscn --resolution 1600x1000 -- ' + $Extra
    if (-not $Gpu) { $taskArgs = '--headless ' + $taskArgs }
    $taskOut = Join-Path $taskLogs "batch-$Name.log"
    $taskErr = Join-Path $taskLogs "batch-$Name.err.log"
    $taskProcess = Start-Process $taskExe -ArgumentList $taskArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr
    try {
        if (-not $taskProcess.WaitForExit(45000)) { throw "Batch check timeout: $Name" }
        $taskProcess.Refresh()
        if ($taskProcess.ExitCode -ne 0 -or (Get-Content $taskOut -Raw) -notmatch 'LEGACY_BATCH_VISUAL_OK 23') { throw "Batch check failed: $Name. See $taskOut and $taskErr" }
        Write-Output "batch $($Name): PASS"
        Copy-Item -LiteralPath (Join-Path $taskLogs 'batch-godot-report.json') -Destination (Join-Path $taskLogs "batch-godot-$Name.json")
    } finally {
        if (-not $taskProcess.HasExited) { $taskProcess.Kill() }
    }
}
if (Test-Path -LiteralPath $taskStash) { throw "Existing staging backup: $taskStash" }
$taskMoved = $false
$taskStagingStarted = $false
try {
    if (Test-Path -LiteralPath $taskDev) {
        Move-Item -LiteralPath $taskDev -Destination $taskStash
        $taskMoved = $true
    }
    $taskStagingStarted = $true
    python (Join-Path $taskRoot 'tools/legacy_assets/pipeline.py') stage_group first_batch --skip-failed
    if ($LASTEXITCODE -ne 0) { throw 'Batch staging failed' }
    & $taskExe --headless --path $taskRoot --import *> (Join-Path $taskLogs 'batch-staged-import.log')
    Invoke-BatchCheck 'dev' "--require-batch-dev --batch-allow-missing=$taskAllowed"
    if ($Capture) { Invoke-BatchCheck 'gallery' "--require-batch-dev --batch-allow-missing=$taskAllowed --batch-preview --batch-capture" -Gpu }
    Invoke-BatchCheck 'disabled' '--no-dev-visuals'
    $taskRemoved = Join-Path $taskLogs 'removed-batch-dev'
    if (Test-Path -LiteralPath $taskRemoved) { throw 'Existing removed batch staging backup' }
    Move-Item -LiteralPath $taskDev -Destination $taskRemoved
    try { Invoke-BatchCheck 'removed' '' }
    finally { Move-Item -LiteralPath $taskRemoved -Destination $taskDev }
} finally {
    # Only the temporary selected staging is removed. Verify the resolved target
    # before recursively removing it, then restore the developer's complete tree.
    $taskResolved = [IO.Path]::GetFullPath($taskDev)
    $taskExpected = [IO.Path]::GetFullPath((Join-Path $taskRoot 'dev_assets/legacy'))
    if ($taskResolved -ne $taskExpected -or -not $taskResolved.StartsWith($taskRoot + [IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe temporary staging target' }
    if ($taskStagingStarted -and (Test-Path -LiteralPath $taskDev)) { Remove-Item -LiteralPath $taskDev -Recurse -Force }
    if ($taskMoved) { Move-Item -LiteralPath $taskStash -Destination $taskDev }
}
Write-Output "Restored pre-test staging; $($taskSuccessful.Count) converted and $($taskFailed.Count) reported failures."
