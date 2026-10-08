param([switch]$WithExport)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
$taskDev = Join-Path $taskRoot 'dev_assets/metin2'
$taskStash = Join-Path $taskLogs 'visual-dev-stash'
$taskFinal = Join-Path $taskRoot 'assets/final/mobs/stray_dog.tscn'
$taskMoved = $false
$taskCreatedFinal = $false
function Invoke-VisualTest([string]$Mode, [string[]]$ExtraArgs=@()) {
    $taskLog = Join-Path $taskLogs "visual-$Mode.log"
    $taskErrorLog = Join-Path $taskLogs "visual-$Mode.err.log"
    $taskArgs = '--headless --path "' + $taskRoot + '" --mode=client res://tests/optional_dog_visual.tscn -- --visual-expect=' + $Mode + ' ' + ($ExtraArgs -join ' ')
    $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskLog -RedirectStandardError $taskErrorLog
    try {
        if (-not $taskProcess.WaitForExit(30000)) { throw "Visual test timeout: $Mode" }
        $taskProcess.Refresh()
        if ($taskProcess.ExitCode -ne 0 -or (Get-Content $taskLog -Raw) -notmatch "OPTIONAL_DOG_VISUAL_OK $Mode") {
            throw "Visual test failed: $Mode. See $taskLog and $taskErrorLog"
        }
    } finally {
        if (-not $taskProcess.HasExited) { $taskProcess.Kill() }
    }
    Write-Output "visual $($Mode): PASS"
}
try {
    if (Test-Path -LiteralPath $taskStash) { throw "Existing verification stash: $taskStash" }
    if (Test-Path -LiteralPath $taskFinal) { throw 'Priority test requires no existing final stray_dog scene; preserve it and run the scene test with --visual-expect=final.' }
    if (Test-Path -LiteralPath (Join-Path $taskDev 'mobs/stray_dog/stray_dog.glb')) {
        Invoke-VisualTest 'dev' @('--visual-remove-live')
        Invoke-VisualTest 'placeholder' @('--no-dev-visuals')
    }
    New-Item -ItemType Directory -Path (Split-Path $taskFinal) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $taskRoot 'assets/placeholders/mobs/stray_dog_placeholder.tscn') -Destination $taskFinal
    $taskCreatedFinal = $true
    Invoke-VisualTest 'final'
    Remove-Item -LiteralPath $taskFinal
    $taskCreatedFinal = $false
    if (Test-Path -LiteralPath $taskDev) {
        Move-Item -LiteralPath $taskDev -Destination $taskStash
        $taskMoved = $true
    }
    Invoke-VisualTest 'placeholder'
} finally {
    $taskHotStash = Join-Path $taskLogs 'visual-hot-stash.glb'
    if (Test-Path -LiteralPath $taskHotStash) {
        Move-Item -LiteralPath $taskHotStash -Destination (Join-Path $taskDev 'mobs/stray_dog/stray_dog.glb')
    }
    if ($taskCreatedFinal) { Remove-Item -LiteralPath $taskFinal }
    if ($taskMoved) { Move-Item -LiteralPath $taskStash -Destination $taskDev }
}

if ($WithExport) {
    $taskPack = Join-Path $taskLogs 'optional-visuals.pck'
    & $taskExe --headless --path $taskRoot --export-pack Windows $taskPack *> (Join-Path $taskLogs 'visual-export.log')
    if ($LASTEXITCODE -ne 0) { throw 'Windows PCK export failed' }
    $taskProbe = Join-Path $taskLogs 'visual-export-probe'
    if (Test-Path -LiteralPath (Join-Path $taskProbe 'project.godot')) {
        if ((Get-Content -LiteralPath (Join-Path $taskProbe 'project.godot') -Raw).Trim() -ne '[application]') {
            throw 'Refusing to overwrite an existing export probe project'
        }
    }
    New-Item -ItemType Directory -Path $taskProbe -Force | Out-Null
    '[application]' | Set-Content -LiteralPath (Join-Path $taskProbe 'project.godot')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'probe_visual_export.gd') -Destination (Join-Path $taskProbe 'probe.gd')
    $taskProbeLog = Join-Path $taskLogs 'visual-export-inspect.log'
    & $taskExe --headless --path $taskProbe --script probe.gd -- $taskPack *> $taskProbeLog
    if ($LASTEXITCODE -ne 0 -or (Get-Content $taskProbeLog -Raw) -notmatch 'VISUAL_EXPORT_OK') { throw "Export content check failed: $taskProbeLog" }
    Write-Output 'visual export contents: PASS'
}
