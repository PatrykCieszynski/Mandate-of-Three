$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskFixture = [IO.Path]::GetFullPath((Join-Path $taskRoot '.godot/verification/boundary-contracts'))
$taskProbe = Join-Path $taskFixture 'source/common/gameplay/spike3d/probe.gd'
$taskAdapter = Join-Path $taskFixture 'source/common/gameplay/mandate/mandate_world_services.gd'
$taskCombat = Join-Path $taskFixture 'source/common/gameplay/spike3d/combat_endpoint_3d.gd'
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

# Completed Package B/C boundaries: dependency checks, not private-field coverage.
$taskBoundaryCases = @(
    @{ Path='source/client/ui_web/ui_command_session.gd'; Good='func wait(id, tree: SceneTree): return {}'; Bad=@('var bridge: WebUiBridge','func wait(): return bridge.generation()') },
    @{ Path='source/client/ui_web/npc_drop_target_projector.gd'; Good='func project(camera: Camera3D): return {}'; Bad=@('var world: GameWorld3D','func drop(): begin_npc_approach()') },
    @{ Path='source/client/ui_web/item_ui_adapter.gd'; Good='var endpoint: InventoryEndpoint3D'; Bad=@('var world: GameWorld3D','var host: WebUiHost') },
    @{ Path='source/client/ui_web/npc_ui_adapter.gd'; Good='var endpoint: NpcInteraction3D'; Bad=@('var upgrade: UpgradeUiAdapter','func flow(): endpoint.request_upgrade()') },
    @{ Path='source/client/ui_web/upgrade_ui_adapter.gd'; Good='func valid(p): return ItemUiAdapter.valid_item_identity(p)'; Bad=@('var world: GameWorld3D','var db: WorldDatabase') },
    @{ Path='source/client/ui_web/shop_ui_adapter.gd'; Good='var endpoint: Shop3D'; Bad=@('var host: WebUiHost','var store: ItemStoreSqlite') },
    @{ Path='source/client/ui_web/core_ui_controller.gd'; Good='func setup(): var items = ItemUiAdapter.new()'; Bad=@('func move(): endpoint.request_move_item.rpc_id(1)','func model(): return ItemDefinitions.get_definition(id)') },
    @{ Path='source/common/gameplay/spike3d/player_combat_runtime.gd'; Good='var combo: BasicAttackComboState'; Bad=@('var world: GameWorld3D','@rpc("authority")') },
    @{ Path='source/common/gameplay/spike3d/basic_attack_service.gd'; Good='func hit(): return HitReactionResolver.resolve()'; Bad=@('func reward(): progression.award_experience()','func hit(): mob.hp -= 1') },
    @{ Path='source/common/gameplay/mobs/mob_system.gd'; Good='signal mob_died(result: MobDeathResult)'; Bad=@('func hit(): HitReactionResolver.resolve()','func reward(): currency.spawn_currency()') },
    @{ Path='source/common/gameplay/spike3d/client_combat_controller.gd'; Good='var feedback: CombatFeedback3D'; Bad=@('var loot: GroundLootSystem','var bar: ProgressBar') },
    @{ Path='source/common/gameplay/spike3d/actor_3d.gd'; Good='var reaction: HitReactionState'; Bad=@('var visual: WarriorVisual3D','var respawn_at: int') },
    @{ Path='source/common/gameplay/mobs/mob_death_result.gd'; Good='var position: Vector3'; Bad=@('var actor: MobActor3D','func capture(): result.actor = mob') }
)
foreach ($taskBoundaryCase in $taskBoundaryCases) {
    $taskPath = Join-Path $taskFixture $taskBoundaryCase.Path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $taskPath)) | Out-Null
    [IO.File]::WriteAllText($taskPath,$taskBoundaryCase.Good)
    & $taskGuard -RootDirectory $taskFixture | Out-Null
    foreach ($taskSource in $taskBoundaryCase.Bad) {
        [IO.File]::WriteAllText($taskPath,$taskSource)
        $taskRejected = $false
        try { & $taskGuard -RootDirectory $taskFixture | Out-Null } catch { $taskRejected = $true }
        if (-not $taskRejected) { throw "Boundary guard missed $($taskBoundaryCase.Path) : $taskSource" }
    }
    [IO.File]::WriteAllText($taskPath,$taskBoundaryCase.Good)
}

Write-Output 'Architecture guard contracts: PASS (adapter/local calls allowed; dependency regressions rejected)'
