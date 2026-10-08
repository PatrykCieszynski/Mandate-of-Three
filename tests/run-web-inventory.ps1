param([switch]$WithBrowser)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskPreviousAppData = $env:APPDATA
$taskPreviousLocalAppData = $env:LOCALAPPDATA
$taskProcesses = @()
$taskOwnedPids = @{}

New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
try {
    $env:APPDATA = Join-Path $taskLogs 'appdata'
    $env:LOCALAPPDATA = Join-Path $taskLogs 'localappdata'
    foreach ($taskRole in @('server', 'client1', 'client2')) {
        $taskMode = if ($taskRole -eq 'server') { 'world-server' } else { 'client' }
        $taskIndex = if ($taskRole -eq 'client1') { 1 } else { 2 }
        $taskArgs = '--headless --path "' + $taskRoot + '" --mode=' + $taskMode + ' res://tests/web_inventory.tscn --test-client=' + $taskIndex
        if ($WithBrowser -and $taskRole -eq 'client1') {
            $taskClientProject = Join-Path $taskRoot '.godot/cef-client/project'
            $taskArgs = '--path "' + $taskClientProject + '" --rendering-method mobile --rendering-driver vulkan --mode=client res://tests/web_inventory.tscn --test-client=1'
        }
        $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskLogs "web-inventory-test-$taskRole.out.log") -RedirectStandardError (Join-Path $taskLogs "web-inventory-test-$taskRole.err.log")
        $taskProcesses += [pscustomobject]@{ Role = $taskRole; Process = $taskProcess }
        if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
    }
    if ($WithBrowser) {
        foreach ($taskEntry in $taskProcesses) { $taskOwnedPids[$taskEntry.Process.Id] = $true }
        $taskDeadline = [DateTime]::UtcNow.AddSeconds(50)
        while (@($taskProcesses | Where-Object { -not $_.Process.HasExited }).Count -and [DateTime]::UtcNow -lt $taskDeadline) {
            $taskInventory = Get-CimInstance Win32_Process
            do {
                $taskAdded = $false
                foreach ($taskInfo in $taskInventory) {
                    if ($taskOwnedPids.ContainsKey([int]$taskInfo.ParentProcessId) -and -not $taskOwnedPids.ContainsKey([int]$taskInfo.ProcessId)) {
                        $taskOwnedPids[[int]$taskInfo.ProcessId] = $true
                        $taskAdded = $true
                    }
                }
            } while ($taskAdded)
            Start-Sleep -Milliseconds 500
        }
    }
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.WaitForExit(50000)) {
            throw "Timeout: $($taskEntry.Role)"
        }
        $taskEntry.Process.Refresh()
        $taskOutput = Get-Content -LiteralPath (Join-Path $taskLogs "web-inventory-test-$($taskEntry.Role).out.log") -Raw
        $taskMarker = if ($taskEntry.Role -eq 'server') { 'WEB_INVENTORY_SERVER_OK' } else { 'WEB_INVENTORY_CLIENT_OK' }
        $taskErrors = Get-Content -LiteralPath (Join-Path $taskLogs "web-inventory-test-$($taskEntry.Role).err.log") -Raw
        if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker -or $taskErrors -match 'SCRIPT ERROR|Parse Error' -or $taskOutput -match 'CEF_GAME: Uncaught') {
            throw "Failed: $($taskEntry.Role). Logs: $taskLogs"
        }
        Write-Output "$($taskEntry.Role): PASS"
    }
    if ($WithBrowser) {
        Start-Sleep -Seconds 2
        $taskSurvivors = @($taskOwnedPids.Keys | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($taskSurvivors.Count) { throw "Owned CEF process survivors: $taskSurvivors" }
        $taskBrowserLog = Get-Content -LiteralPath (Join-Path $taskLogs 'web-inventory-test-client1.out.log') -Raw
        if ($taskBrowserLog -notmatch 'rendered=true' -or $taskBrowserLog -notmatch 'GAME_INVENTORY_DOM') { throw 'Missing rendered gameplay/DOM evidence' }
        Write-Output 'CEF gameplay DOM/IPC + shutdown: PASS, zero owned survivors'
    }
} finally {
    foreach ($taskEntry in $taskProcesses) {
        if (-not $taskEntry.Process.HasExited) { $taskEntry.Process.Kill() }
    }
    foreach ($taskId in $taskOwnedPids.Keys) {
        $taskOwnedProcess = Get-Process -Id $taskId -ErrorAction SilentlyContinue
        if ($null -ne $taskOwnedProcess -and $taskOwnedProcess.ProcessName -eq 'gdcef_helper') { Stop-Process -Id $taskId -ErrorAction SilentlyContinue }
    }
    $env:APPDATA = $taskPreviousAppData
    $env:LOCALAPPDATA = $taskPreviousLocalAppData
}
