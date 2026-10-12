[CmdletBinding()]
param([string]$RootDirectory = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath($RootDirectory)
# Production Mandate scopes; upstream TinyMMO and test fixtures are separate.
$taskScopes = @(
    'source/common/gameplay/spike3d', 'source/common/gameplay/mandate',
    'source/common/gameplay/loot', 'source/common/gameplay/mobs',
    'source/common/gameplay/npcs', 'source/common/gameplay/shops',
    'source/common/gameplay/upgrades', 'source/common/gameplay/encounters/metin',
    'source/client/ui_web'
)
$taskAdapter = 'source/common/gameplay/mandate/mandate_world_services.gd'
if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'source/common/gameplay/spike3d')) -or
    -not (Test-Path -LiteralPath (Join-Path $taskRoot $taskAdapter) -PathType Leaf)) {
    throw 'Architecture boundaries: missing production scope or adapter'
}
$taskFailures = [Collections.Generic.List[string]]::new()
foreach ($taskScope in $taskScopes) {
    $taskDirectory = Join-Path $taskRoot $taskScope
    if (-not (Test-Path -LiteralPath $taskDirectory)) { continue }
    foreach ($taskFile in Get-ChildItem -LiteralPath $taskDirectory -Recurse -File -Filter '*.gd') {
        $taskRelative = [IO.Path]::GetRelativePath($taskRoot,$taskFile.FullName).Replace('\','/')
        $taskCode = [regex]::Replace([IO.File]::ReadAllText($taskFile.FullName),'(?m)#.*$','')
        if ($taskRelative -ne $taskAdapter -and $taskCode -match '\bWorldServer\s*\.\s*curr\b') {
            $taskFailures.Add("$taskRelative : direct WorldServer.curr outside the adapter")
        }
        if ($taskCode -match '\.\s*db\b|\bdirty_progression\b') {
            $taskFailures.Add("$taskRelative : raw database/dirty progression internals")
        }
        if ($taskRelative -ne $taskAdapter -and $taskCode -match '\.\s*item_store\b(?!\s*\()') {
            $taskFailures.Add("$taskRelative : item store field instead of the adapter query")
        }
        foreach ($taskMatch in [regex]::Matches($taskCode,'(?<receiver>\b[A-Za-z_][A-Za-z_0-9]*(?:\s*\.\s*[A-Za-z_][A-Za-z_0-9]*)*)\s*\.\s*(?:inventory_changed|wallet_changed)\s*\.\s*emit\s*\(')) {
            if ($taskMatch.Groups['receiver'].Value.Trim() -ne 'self') {
                $taskFailures.Add("$taskRelative : foreign endpoint change fact $($taskMatch.Value)")
            }
        }
        foreach ($taskMatch in [regex]::Matches($taskCode,'(?<receiver>\b[A-Za-z_][A-Za-z_0-9]*(?:\s*\.\s*[A-Za-z_][A-Za-z_0-9]*)*)\s*\.\s*_(?:store|send_state|send_snapshot|living|visible_between|owner|server)\s*\(')) {
            if ($taskMatch.Groups['receiver'].Value.Trim() -ne 'self') {
                $taskFailures.Add("$taskRelative : private cross-call $($taskMatch.Value)")
            }
        }
        foreach ($taskMatch in [regex]::Matches($taskCode,'(?<receiver>\b[A-Za-z_][A-Za-z_0-9]*(?:\s*\.\s*[A-Za-z_][A-Za-z_0-9]*)*)\s*\.\s*_(?:camera|npc_approach)\b')) {
            if ($taskMatch.Groups['receiver'].Value.Trim() -ne 'self') {
                $taskFailures.Add("$taskRelative : private world presentation field $($taskMatch.Value)")
            }
        }
        if ($taskRelative -eq 'source/common/gameplay/spike3d/spike_combat_3d.gd' -and
            $taskCode -match '\b(?:SQLite|ItemStoreSqlite|claim_ground_item|dirty_progression|add_experience|spawn_currency)\b|func\s+(?:drop_reward|_award_experience)\b|var\s+ground\b|ground_loot\s*\.\s*drops\b|services\s*\.\s*(?:item_store|economy|progression)\s*\(') {
            $taskFailures.Add("$taskRelative : combat owns persistence/rewards/ground state")
        }
    }
}
if ($taskFailures.Count -gt 0) {
    throw ("Architecture boundaries: FAIL" + [Environment]::NewLine + ($taskFailures -join [Environment]::NewLine))
}
Write-Output 'Architecture boundaries: PASS'
