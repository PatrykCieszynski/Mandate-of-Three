param([string]$NodeExecutable = 'node')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $taskRoot 'tools/check-mandate-boundaries.ps1')
& (Join-Path $PSScriptRoot 'check-mandate-boundaries.ps1')
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
# Isolated databases. No servers, game windows, balances, exact DOM or geometry.
$taskCases = [ordered]@{
    content_catalog = 'CONTENT_CATALOG_OK'
    stats_v1 = 'STATS_V1_OK'
    upgrade_transaction = 'UPGRADE_TRANSACTION_OK'
    shop_purchase = 'SHOP_PURCHASE_OK'
    npc_foundation = 'NPC_FOUNDATION_OK'
    item_instances = 'ITEM_INSTANCES_OK'
    inventory_grid = 'INVENTORY_GRID_OK'
    ground_items = 'GROUND_ITEMS_OK'
    progression_checkpoint = 'CHECKPOINT_OK'
    yang_wallet = 'WALLET_OK'
    exchange_ledger = 'EXCHANGE_LEDGER_OK'
    market_search = 'MARKET_SEARCH_OK'
    loot_resolver = 'LOOT_RESOLVER_OK'
    hotbar_bindings = 'HOTBAR_BINDINGS_OK'
    world_event_drops = 'WORLD_EVENT_DROPS_OK'
    mob_packs = 'MOB_PACKS_OK'
    horn_taunt = 'HORN_TAUNT_OK'
    party_v1 = 'PARTY_V1_OK'
    chat_v1 = 'CHAT_V1_OK'
    mob_interest = 'MOB_INTEREST_OK'
    hit_reactions = 'HIT_REACTIONS_OK'
}
foreach ($taskCase in $taskCases.GetEnumerator()) {
    $taskLog = Join-Path $taskLogs "$($taskCase.Key).smoke.log"
    & $taskExe --headless --path $taskRoot --mode=world-server "res://tests/$($taskCase.Key).tscn" --quit-after 300 *> $taskLog
    $taskOutput = Get-Content -LiteralPath $taskLog -Raw
    if ($LASTEXITCODE -ne 0 -or $taskOutput -notmatch $taskCase.Value -or $taskOutput -match 'SCRIPT ERROR|Parse Error') { throw "Smoke failed: $($taskCase.Key); $taskLog" }
    Write-Output "$($taskCase.Key): PASS"
}
# Successful runs keep fixed-name logs, not a new database per invocation.
foreach ($taskPattern in @('upgrade-*.db*','shop-purchase-*.db*','items-unit-*.db*','grid-*.db*','ground-items-*.db*','checkpoint-*.db*','yang-wallet-*.db*')) {
    foreach ($taskFile in Get-ChildItem -LiteralPath $taskLogs -File -Filter $taskPattern) {
        if (-not $taskFile.FullName.StartsWith([IO.Path]::GetFullPath($taskLogs) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test DB cleanup path' }
        Remove-Item -LiteralPath $taskFile.FullName -Force
    }
}
& (Join-Path $PSScriptRoot 'run-web-ui.ps1') -NodeExecutable $NodeExecutable
Write-Output 'Prototype smoke: PASS'
