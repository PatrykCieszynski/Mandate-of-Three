$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskFixture = [IO.Path]::GetFullPath((Join-Path $taskRoot '.godot/verification/boundary-contracts'))
$taskProbe = Join-Path $taskFixture 'source/common/gameplay/spike3d/probe.gd'
$taskAdapter = Join-Path $taskFixture 'source/common/gameplay/mandate/mandate_world_services.gd'
$taskCombat = Join-Path $taskFixture 'source/common/gameplay/spike3d/spike_combat_3d.gd'
$taskGuard = Join-Path $taskRoot 'tools/check-mandate-boundaries.ps1'
[IO.Directory]::CreateDirectory((Split-Path -Parent $taskProbe)) | Out-Null
[IO.Directory]::CreateDirectory((Split-Path -Parent $taskAdapter)) | Out-Null
[IO.File]::WriteAllText($taskAdapter,"func adapter(): return WorldServer.curr")
[IO.File]::WriteAllText($taskProbe,"func local(): self._send_state(1); self._camera; _store()")
[IO.File]::WriteAllText($taskCombat,"extends Node")
& $taskGuard -RootDirectory $taskFixture | Out-Null
$taskCases = @(
    "func bad(): return WorldServer.curr.database",
    ("func bad(): return WorldServer" + [Environment]::NewLine + " .curr"),
    "func bad(): return other._store()",
    "func bad(): other._send_state(1)",
    "func bad(): other._send_snapshot(1)",
    "func bad(): services._server()",
    "func bad(): return world._camera",
    "func bad(): world._npc_approach.cancel()",
    ("class_name MandateWorldServices" + [Environment]::NewLine + "func bad(): return WorldServer.curr")
)
foreach ($taskSource in $taskCases) {
    [IO.File]::WriteAllText($taskProbe,$taskSource)
    $taskRejected = $false
    try { & $taskGuard -RootDirectory $taskFixture | Out-Null } catch { $taskRejected = $true }
    if (-not $taskRejected) { throw "Boundary guard missed: $taskSource" }
}
[IO.File]::WriteAllText($taskProbe,"extends Node")
[IO.File]::WriteAllText($taskCombat,"var ground = {}")
$taskRejected = $false
try { & $taskGuard -RootDirectory $taskFixture | Out-Null } catch { $taskRejected = $true }
if (-not $taskRejected) { throw 'Boundary guard missed combat ground-state ownership' }
[IO.File]::WriteAllText($taskCombat,"extends Node")
& $taskGuard -RootDirectory $taskFixture | Out-Null

$taskRejected = $false
try { & $taskGuard -RootDirectory (Join-Path $taskFixture 'missing') | Out-Null } catch { $taskRejected = $true }
if (-not $taskRejected) { throw 'Boundary guard silently accepted a missing scope' }
Write-Output 'Architecture guard contracts: PASS (adapter/local calls allowed; dependency regressions rejected)'
