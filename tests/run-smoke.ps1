param([string]$NodeExecutable = 'node')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
# Isolated databases. No servers, game windows, balances, exact DOM or geometry.
$taskCases = [ordered]@{
    upgrade_transaction = 'UPGRADE_TRANSACTION_OK'
    shop_purchase = 'SHOP_PURCHASE_OK'
    npc_foundation = 'NPC_FOUNDATION_OK'
    item_instances = 'ITEM_INSTANCES_OK'
    inventory_grid = 'INVENTORY_GRID_OK'
    ground_items = 'GROUND_ITEMS_OK'
    progression_checkpoint = 'CHECKPOINT_OK'
    yang_wallet = 'WALLET_OK'
    mob_packs = 'MOB_PACKS_OK'
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
