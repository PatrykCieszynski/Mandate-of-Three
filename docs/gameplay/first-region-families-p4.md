# P4 preview: Wolf and Bandit mob packs on the first region

This is a **content-only dependency** of the [P1 mob classification PR #45](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/45). P1 must be merged before P4 can be rebased onto main.

New canonical 3D mob profiles:
- Beasts/wolves: Forest Wolf (normal), Dire Wolf (strong), Wolf Alpha (elite).
- Humanoids/bandits: Road Bandit (normal), Bandit Raider (strong), Bandit Captain (elite).

All definitions are `.tres` and refer to the pre-existing `VisualResolver` IDs `wolf`, `barbarian_infantry` and `barbarian_soldier`. They load optional local GLBs from ignored `dev_assets/legacy/mobs/<visual_id>/<visual_id>.glb` and otherwise the repo-owned generic mob placeholder. There are **zero third-party model files in this change**.

First-region allocation (same six spawn points, same 104 active mob actors):
- Outskirts West: 10 Forest Wolves.
- Outskirts Bend: 10 Forest Wolves, 3 Dire Wolves, 1 Wolf Alpha.
- Old Road West: 10 Road Bandits and 6 Bandit Raiders.
- Old Road Coast: 10 Road Bandits, 7 Bandit Raiders and 1 Bandit Captain.
- Stone Hollow West/Shrine: previous 46 Feral Dogs and Hollow Hounds unchanged.

No change to pack AI, aggro rules, run-through-props, respawn times, collision, XP formula, world snapshot protocol, or economic rewards. Current hardcoded prototype sword/Yang drops remain until the separate Loot V2 P3 integration; this PR intentionally does **not** claim content-specific loot works yet.

Check `./tests/run-smoke.ps1` and `./tests/run-first-region.ps1`. Manually play 10-15 minutes once local visuals are available to tune mob scale, density and difficulty. Do not merge binary prototype assets.
