[CmdletBinding()]
param(
    [ValidateSet('start','stop','restart','status')][string]$Action = 'status',
    [ValidateSet('all','game','world','gateway')][string]$Target = 'all',
    [string]$DashboardToken = $env:MANDATE_DASHBOARD_TOKEN
)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$taskRoles = switch ($Target) { 'all' { @('master','gateway','world') } 'game' { @('master','world') } default { @($Target) } }
$taskPorts = @{master=8064; gateway=8088; world=8087}
function Get-RoleProcesses([string]$Role) {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -like 'Godot*' -and $_.CommandLine -and
        $_.CommandLine.Contains('"' + $taskRoot + '"') -and
        $_.CommandLine -match ('--mode=' + $Role + '-server(?:\s|$)')
    })
}
function Wait-Role([string]$Role, [bool]$Running) {
    $taskDeadline = (Get-Date).AddSeconds(30)
    do {
        $taskProcesses = @(Get-RoleProcesses $Role)
        $taskListeners = @(Get-NetTCPConnection -State Listen -LocalPort $taskPorts[$Role] -ErrorAction SilentlyContinue)
        $taskReady = if ($Running) { @($taskListeners | Where-Object { $_.OwningProcess -in $taskProcesses.ProcessId }).Count -gt 0 } else { $taskProcesses.Count -eq 0 }
        if ($taskReady) { return }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $taskDeadline)
    throw "$Role did not reach requested state. Check .godot/runtime logs."
}
function Stop-Role([string]$Role) {
    $taskProcesses = @(Get-RoleProcesses $Role)
    if (!$taskProcesses.Count) { return }
    if ($Role -eq 'world') {
        if (!(Get-RoleProcesses 'master').Count) { throw 'Cannot gracefully stop World without its Master. No processes were killed.' }
        $taskHeaders = @{}
        if ($DashboardToken) { $taskHeaders.Authorization = 'Bearer ' + $DashboardToken }
        $taskWorlds = Invoke-RestMethod 'http://127.0.0.1:8080/v1/worlds' -Headers $taskHeaders -TimeoutSec 5
        if (!$taskWorlds.ok) { throw 'Master dashboard rejected world lookup.' }
        $taskWorld = @($taskWorlds.worlds | Where-Object { $_.port -eq $taskPorts.world })
        if ($taskWorld.Count -ne 1) { throw 'Expected one registered local World; refusing forced shutdown.' }
        $taskReply = Invoke-RestMethod 'http://127.0.0.1:8080/v1/worlds/shutdown' -Method Post -Headers $taskHeaders -ContentType 'application/json' -Body (@{world_id=$taskWorld[0].world_id} | ConvertTo-Json) -TimeoutSec 5
        if (!$taskReply.ok) { throw 'Master rejected graceful World shutdown.' }
    } else {
        foreach ($taskProcess in $taskProcesses) { Stop-Process -Id $taskProcess.ProcessId -Force }
    }
    Wait-Role $Role $false
    Write-Output "$Role stopped."
}
function Start-Role([string]$Role) {
    if ((Get-RoleProcesses $Role).Count) { Wait-Role $Role $true; Write-Output "$Role already running."; return }
    $taskEngine = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
    if (!(Test-Path -LiteralPath $taskEngine)) { throw "Missing engine: $taskEngine" }
    if (Get-NetTCPConnection -State Listen -LocalPort $taskPorts[$Role] -ErrorAction SilentlyContinue) { throw "$Role port is occupied by another process." }
    $taskLogs = Join-Path $taskRoot '.godot/runtime'
    New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
    Start-Process -FilePath $taskEngine -ArgumentList @('--headless','--path',('"' + $taskRoot + '"'),('--mode=' + $Role + '-server')) -WorkingDirectory $taskRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskLogs "$Role-server.out.log") -RedirectStandardError (Join-Path $taskLogs "$Role-server.err.log") | Out-Null
    Wait-Role $Role $true
    Write-Output "$Role started."
}
if ($Action -in @('stop','restart')) {
    foreach ($taskRole in @('world','gateway','master')) { if ($taskRole -in $taskRoles) { Stop-Role $taskRole } }
}
if ($Action -in @('start','restart')) {
    foreach ($taskRole in @('master','gateway','world')) { if ($taskRole -in $taskRoles) { Start-Role $taskRole } }
}
foreach ($taskRole in $taskRoles) {
    $taskProcesses = @(Get-RoleProcesses $taskRole)
    $taskListeners = @(Get-NetTCPConnection -State Listen -LocalPort $taskPorts[$taskRole] -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $taskProcesses.ProcessId })
    [PSCustomObject]@{Role=$taskRole; State=$(if ($taskListeners.Count) {'listening'} elseif ($taskProcesses.Count) {'starting'} else {'stopped'}); Port=$taskPorts[$taskRole]; PID=($taskProcesses.ProcessId -join ',')}
}
