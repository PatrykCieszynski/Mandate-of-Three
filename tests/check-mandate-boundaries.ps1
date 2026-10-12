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
[IO.File]::WriteAllText($taskProbe,"func local(): self._send_state(1); self._camera; _store(); inventory_changed.emit(1); self.wallet_changed.emit(1); services.item_store().inventory(1); services.economy().upgrade_candidate(1)")
[IO.File]::WriteAllText($taskCombat,"extends Node")
& $taskGuard -RootDirectory $taskFixture | Out-Null
$taskCases = @(
    "func bad(): return WorldServer.curr.database",
    ("func bad(): return WorldServer" + [Environment]::NewLine + " .curr"),
    "func bad(): return other._store()",
    "func bad(): other._send_state(1)",
    "func bad(): other._send_snapshot(1)",
    "func bad(): services._server()",
    "func bad(): world.inventory_endpoint.inventory_changed.emit(1)",
    "func bad(): currency.wallet_changed.emit(1)",
    ("func bad(): world.currency_endpoint.wallet_changed" + [Environment]::NewLine + " .emit(1)"),
    "func bad(): services.economy().db",
    ("func bad(): store" + [Environment]::NewLine + " .db"),
    "func bad(): services.progression().dirty_progression",
    "func bad(): services.economy().item_store.inventory(1)",
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
# Even the adapter cannot expose raw SQL or inspect the progression dirty set.
foreach ($taskSource in @("func bad(): return economy().db", "func bad(): return progression().dirty_progression")) {
    [IO.File]::WriteAllText($taskAdapter,$taskSource)
    [IO.File]::WriteAllText($taskProbe,"extends Node")
    $taskRejected = $false
    try { & $taskGuard -RootDirectory $taskFixture | Out-Null } catch { $taskRejected = $true }
    if (-not $taskRejected) { throw "Boundary guard missed adapter internals: $taskSource" }
}
[IO.File]::WriteAllText($taskAdapter,"func adapter(): return WorldServer.curr.database.item_store")
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
