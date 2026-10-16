# PvE P1: mob classification and spawn-frozen drop count

Five canonical categories: `beast`, `humanoid`, `undead`, `demon`, `construct`.
Each `MobDefinition` has independent `category`, `family` and `rank` (`normal`, `strong`, `elite`, `boss`) fields. These do not change combat, aggro or client snapshot serialization.

A mob definition authors inclusive `min_loot_rolls..max_loot_rolls` in 1..4. `MobSystem.spawn_mob` draws **the number of ordinary item attempts**, once per new runtime mob, through the pack RNG. Its count is kept on the server actor and frozen in `MobDeathResult`; the new actor receives a new random count on respawn. Loot item IDs, quality, quantities and Luck are **not** resolved at spawn. Current prototype sword/Yang rewards are intentionally unchanged pending P2/P3.

Existing four dogs are explicitly classified. No visual assets, network protocol, map density or AI changed. An invalid classification/range is rejected before creating packs. Prototype models can be loaded by existing `VisualResolver` from ignored `dev_assets`; no third-party assets belong in Git.

Run `./tests/run-smoke.ps1`, `./tests/run-first-region.ps1`, `./tests/run-metin.ps1`.
