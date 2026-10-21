param([string]$Scene = "combat_feel", [string]$MarkerPrefix = "COMBAT", [switch]$LegacyMelee, [switch]$NativeClient1, [switch]$LightMobMovement)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskPreviousAppData = $env:APPDATA
$taskPreviousLocalAppData = $env:LOCALAPPDATA
$taskProcesses = @()
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
try {
    $env:APPDATA = Join-Path $taskLogs 'appdata'
    $env:LOCALAPPDATA = Join-Path $taskLogs 'localappdata'
    foreach ($taskRole in @('server', 'client1', 'client2')) {
        $taskMode = if ($taskRole -eq 'server') { 'world-server' } else { 'client' }
        $taskIndex = if ($taskRole -eq 'client1') { 1 } else { 2 }
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskMode + ' res://tests/' + $Scene + '.tscn --test-client=' + $taskIndex
        if ($NativeClient1 -and $taskRole -eq 'server') { $taskArgs += ' --native-market-server' }
        if ($NativeClient1 -and $taskRole -eq 'client1') { $taskArgs = $taskArgs.Replace('--headless ', '--rendering-method mobile --rendering-driver vulkan --resolution 1280x720 --position -2000,-2000 '); $taskArgs += ' --native-market-check' }
        if ($NativeClient1 -and $taskRole -eq 'client2') { $taskArgs += ' --native-market-peer' }
        if ($LegacyMelee) { $taskArgs += ' -- --dev-legacy-melee' }
        if ($LightMobMovement -and $taskRole -eq 'server') { $taskArgs += ' --dev-light-mob-movement' }
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "combat-test-$taskRole.out.log") -RedirectStandardError (Join-Path $taskLogs "combat-test-$taskRole.err.log")
        $taskProcesses += [pscustomobject]@{ Role = $taskRole; Process = $taskProcess }
        if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(65000)) {
            throw "Timeout: $($taskEntry.Role)"
        }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "combat-test-$($taskEntry.Role).out.log") -Raw
        $taskErrors = Get-Content -LiteralPath (Join-Path $taskLogs "combat-test-$($taskEntry.Role).err.log") -Raw
        $taskMarker = if ($taskEntry.Role -eq 'server') { $MarkerPrefix + '_SERVER_OK' } else { $MarkerPrefix + '_CLIENT_OK' }
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker -or ($taskOutput + $taskErrors) -match 'SCRIPT ERROR|Parse Error') {
            throw "Failed: $($taskEntry.Role). Logs: $taskLogs"
        }
        Write-Output "$($taskEntry.Role): PASS"
    }
} finally {
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.HasExited) { $taskEntry.Process.Kill() }
    }
    $env:APPDATA = $taskPreviousAppData
    $env:LOCALAPPDATA = $taskPreviousLocalAppData
}
