param([switch]$Preview)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
function Invoke-WarriorTest([string]$Mode,[string]$Options) {
    $taskOut = Join-Path $taskLogs "warrior-$Mode.log"
    $taskErr = Join-Path $taskLogs "warrior-$Mode.err.log"
    $taskArgs = '--headless --path "' + $taskRoot + '" --mode=client res://tests/warrior_compatibility.tscn -- ' + $Options
    $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr
    try {
        if (-not $taskProcess.WaitForExit(30000)) { throw "Warrior test timeout: $Mode" }
        $taskProcess.Refresh()
        if ($taskProcess.ExitCode -ne 0 -or (Get-Content $taskOut -Raw) -notmatch 'WARRIOR_COMPATIBILITY_OK') { throw "Warrior test failed: $Mode. See $taskOut and $taskErr" }
        Write-Output "warrior $($Mode): PASS"
    } finally {
        if (-not $taskProcess.HasExited) { $taskProcess.Kill() }
    }
}
try {
    $taskAvailable = (Test-Path -LiteralPath (Join-Path $taskRoot 'dev_assets/metin2/players/warrior/warrior.glb')) -and (Test-Path -LiteralPath (Join-Path $taskRoot 'dev_assets/metin2/players/warrior/warrior_armor.glb')) -and (Test-Path -LiteralPath (Join-Path $taskRoot 'dev_assets/metin2/weapons/iron_sword/iron_sword.glb'))
    if ($taskAvailable) { Invoke-WarriorTest 'dev' '--require-dev --remove-live' }
    Invoke-WarriorTest 'placeholder' '--no-dev-visuals'
} finally {
    foreach ($taskEntry in @(@('warrior-hot-body.glb','dev_assets/metin2/players/warrior/warrior.glb'),@('warrior-hot-sword.glb','dev_assets/metin2/weapons/iron_sword/iron_sword.glb'))) {
        $taskStash = Join-Path $taskLogs $taskEntry[0]
        if (Test-Path -LiteralPath $taskStash) { Move-Item -LiteralPath $taskStash -Destination (Join-Path $taskRoot $taskEntry[1]) }
    }
}
if ($Preview) {
    $taskArgs = '--path "' + $taskRoot + '" --mode=client res://tests/warrior_compatibility.tscn --resolution 1280x800 -- --preview'
    Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WindowStyle Hidden
}
