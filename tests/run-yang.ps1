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
    foreach ($taskRole in @('wallet', 'server', 'client1', 'client2')) {
        $taskMode = if ($taskRole -in @('wallet', 'server')) { 'world-server' } else { 'client' }
        $taskIndex = if ($taskRole -eq 'client1') { 1 } else { 2 }
        $taskScene = if ($taskRole -eq 'wallet') { 'yang_wallet' } else { 'yang_network' }
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskMode + ' res://tests/' + $taskScene + '.tscn --test-client=' + $taskIndex
        if ($Preview -and $taskRole -in @('client1', 'client2')) { $taskArgs = $taskArgs.Replace('--headless ', '') + ' --preview' }
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "yang-test-$taskRole.out.log") -RedirectStandardError (Join-Path $taskLogs "yang-test-$taskRole.err.log")
        $taskProcesses += [pscustomobject]@{ Role = $taskRole; Process = $taskProcess }
        if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(50000)) {
            throw "Timeout: $($taskEntry.Role)"
        }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "yang-test-$($taskEntry.Role).out.log") -Raw
        if ($taskOutput -match 'YANG_PREVIEW_OK') { $taskSawPreview = $true }
        $taskMarker = if ($taskEntry.Role -eq 'wallet') { 'WALLET_OK' } elseif ($taskEntry.Role -eq 'server') { 'YANG_SERVER_OK' } else { 'YANG_CLIENT_OK' }
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker) {
            throw "Failed: $($taskEntry.Role). Logs: $taskLogs"
        }
        Write-Output "$($taskEntry.Role): PASS"
    }
    if ($Preview -and -not $taskSawPreview) { throw 'Missing Yang render preview' }
} finally {
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.HasExited) { $taskEntry.Process.Kill() }
    }
    $env:APPDATA = $taskPreviousAppData
    $env:LOCALAPPDATA = $taskPreviousLocalAppData
}
