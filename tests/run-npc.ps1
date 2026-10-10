param([ValidateSet('npc','shop')][string]$Scenario = 'npc')
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
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskMode + ' res://tests/' + $Scenario + '_network.tscn --test-client=' + $taskIndex
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "$Scenario-test-$taskRole.out.log") -RedirectStandardError (Join-Path $taskLogs "$Scenario-test-$taskRole.err.log")
        $taskProcesses += [pscustomobject]@{ Role = $taskRole; Process = $taskProcess }
        if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(50000)) {
            throw "Timeout: $($taskEntry.Role)"
        }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "$Scenario-test-$($taskEntry.Role).out.log") -Raw
        $taskMarker = if ($taskEntry.Role -eq 'server') { ($Scenario.ToUpper() + '_SERVER_OK') } else { ($Scenario.ToUpper() + '_CLIENT_OK') }
        $taskErrors = Get-Content -LiteralPath (Join-Path $taskLogs "$Scenario-test-$($taskEntry.Role).err.log") -Raw
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker -or $taskErrors -match 'SCRIPT ERROR|Parse Error') {
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
