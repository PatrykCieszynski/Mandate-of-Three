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
    foreach ($taskRole in @('ground', 'server', 'client1', 'client2')) {
        $taskMode = if ($taskRole -in @('ground', 'server')) { 'world-server' } else { 'client' }
        $taskIndex = if ($taskRole -eq 'client1') { 1 } else { 2 }
        $taskScene = if ($taskRole -eq 'ground') { 'ground_items' } else { 'pve_network' }
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskMode + ' res://tests/' + $taskScene + '.tscn --test-client=' + $taskIndex
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "pve-test-$taskRole.out.log") -RedirectStandardError (Join-Path $taskLogs "pve-test-$taskRole.err.log")
        $taskProcesses += [pscustomobject]@{ Role = $taskRole; Process = $taskProcess }
        if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(45000)) {
            throw "Timeout: $($taskEntry.Role)"
        }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "pve-test-$($taskEntry.Role).out.log") -Raw
        $taskMarker = switch ($taskEntry.Role) { 'ground' { 'GROUND_ITEMS_OK' } 'server' { 'PVE_SERVER_OK' } default { 'PVE_CLIENT_OK' } }
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker) {
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
