param([switch]$Preview)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskPreviousAppData = $env:APPDATA
$taskPreviousLocalAppData = $env:LOCALAPPDATA
$taskProcesses = @()
$taskSawPreview = $false
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
try {
    $env:APPDATA = Join-Path $taskLogs 'appdata'
    $env:LOCALAPPDATA = Join-Path $taskLogs 'localappdata'
    foreach ($taskRole in @('server', 'client1', 'client2')) {
        $taskMode = if ($taskRole -eq 'server') { 'world-server' } else { 'client' }
        $taskIndex = if ($taskRole -eq 'client1') { 1 } else { 2 }
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskMode + ' res://tests/item_progression.tscn --test-client=' + $taskIndex
        if ($Preview -and $taskRole -ne 'server') { $taskArgs = $taskArgs.Replace('--headless ', '') + ' --preview' }
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "progression-test-$taskRole.out.log") -RedirectStandardError (Join-Path $taskLogs "progression-test-$taskRole.err.log")
        $taskProcesses += [pscustomobject]@{ Role = $taskRole; Process = $taskProcess }
        if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(50000)) {
            throw "Timeout: $($taskEntry.Role)"
        }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "progression-test-$($taskEntry.Role).out.log") -Raw
        if ($taskOutput -match 'PROGRESSION_PREVIEW_OK') { $taskSawPreview = $true }
        $taskMarker = if ($taskEntry.Role -eq 'server') { 'PROGRESSION_SERVER_OK' } else { 'PROGRESSION_CLIENT_OK' }
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker) {
            throw "Failed: $($taskEntry.Role). Logs: $taskLogs"
        }
        Write-Output "$($taskEntry.Role): PASS"
    }
    if ($Preview -and -not $taskSawPreview) { throw 'Missing progression render preview' }
} finally {
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.HasExited) { $taskEntry.Process.Kill() }
    }
    $env:APPDATA = $taskPreviousAppData
    $env:LOCALAPPDATA = $taskPreviousLocalAppData
}
