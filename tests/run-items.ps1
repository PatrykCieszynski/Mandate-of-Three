param([switch]$WithSession)
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
    $taskCases = @([pscustomobject]@{ Name = 'items-unit'; Scene = 'item_instances'; Mode = 'world-server'; Index = 0; Marker = 'ITEM_INSTANCES_OK' })
    if ($WithSession) {
        foreach ($taskIndex in @(1, 2)) {
            $taskCases += [pscustomobject]@{ Name = "items-session-$taskIndex"; Scene = 'items_session'; Mode = 'client'; Index = $taskIndex; Marker = 'ITEM_SESSION_OK' }
        }
    }
    foreach ($taskCase in $taskCases) {
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskCase.Mode + ' res://tests/' + $taskCase.Scene + '.tscn --test-client=' + $taskCase.Index
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "$($taskCase.Name).out.log") -RedirectStandardError (Join-Path $taskLogs "$($taskCase.Name).err.log")
        $taskProcesses += [pscustomobject]@{ Case = $taskCase; Process = $taskProcess }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(40000)) { throw "Timeout: $($taskEntry.Case.Name)" }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "$($taskEntry.Case.Name).out.log") -Raw
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskEntry.Case.Marker) {
            throw "Failed: $($taskEntry.Case.Name). Logs: $taskLogs"
        }
        Write-Output "$($taskEntry.Case.Name): PASS"
    }
} finally {
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.HasExited) { $taskEntry.Process.Kill() }
    }
    $env:APPDATA = $taskPreviousAppData
    $env:LOCALAPPDATA = $taskPreviousLocalAppData
}
