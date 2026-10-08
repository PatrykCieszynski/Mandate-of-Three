# Mandate of Three

A multiplayer 3D game inspired by Metin 2, built in Godot on
[Godot Tiny MMO](https://github.com/SlayHorizon/godot-tiny-mmo) infrastructure.
This repository contains a working technical vertical slice, not a game alpha.

## Current scope

- Gateway, master and world: login, sessions, character creation and instance entry.
- 3D spike: server-side movement and physics, collisions and remote-character interpolation.
- ItemDefinition and persistent ItemInstance: UID, owner, bonuses, equipping a specific
  instance and transactional SQLite persistence.
- Initial loot progression: weapon attack shown on the ground, comparison with the
  equipped instance, attack preview after swapping and persistent sword equipment.
- Four Wild Dogs with navigation and server-side AI; directional melee hitting multiple
  targets, a three-hit combo, hit reactions and final-hit knockback.
- Player and mob death/respawn, ground loot, reservation and persistent pickup.
  Two-client tests cover combat, death and competition for the same loot.
- XP for killing dogs, levels, progress bar and level-up; persistence across relog,
  dirty progression checkpoints approximately every 60 seconds and session-end saves.
- Yang wallet, ground currency with loot rights and auto-pickup; a separate dirty
  delta checkpoint every 30 seconds and an atomic test spend including pending income.
- Active-character combat stats in RAM; swings do not query SQLite inventory.
  Item pickup and equipment retain immediate DB transactions.
- An opt-in [Web UI foundation](docs/web-ui.md): protocol v1, explicit commands,
  domain snapshots and region-based input routing. CEF and mock inventory remain
  in the isolated test project; existing gameplay UI is unchanged.

Controls: **WASD** to move, **I** for inventory, **hold Space** for a combo in front
of the character, **E** to pick up nearby loot. **Left click** selects an optional
target; **F** toggles autoattack, interrupted by manual movement. Nearby Yang is
picked up automatically; **G** picks up the nearest stack. A HUD test button spends
50 Yang.

AI routes around obstacles on the arena navmesh. Unclaimed loot, HP and position
are runtime state; items become persistent on pickup. AOI, local prediction and
final models/animations remain future work. Optional local development visuals
are described below. Upstream modules still present do not imply available 3D features.

## Local setup

Verified engine: **Godot 4.7.2**, installed locally in `.godot/`.
Godot and godot-sqlite native binaries are not versioned; a fresh checkout needs
local installation. `.godot/` contains local cache, the engine and test results.

Start the three roles in separate PowerShell terminals from the project directory:

```powershell
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=master-server
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=gateway-server
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server
```

Then start a client, or two clients for multiplayer testing:

```powershell
& .\.godot\Godot_v4.7.2-stable_win64.exe --path . --mode=client
```

Alternatively, use Godot **Debug -> Customize Run Instances** with separate feature
tags `master-server`, `gateway-server`, `world-server` and `client`. Place `--mode`
before the `--` separator. Default configurations are in `data/config/`.
Accounts and world databases are local runtime data excluded from Git.

## Tests and workflow

```powershell
& .\tests\run-items.ps1
& .\tests\run-spike3d.ps1
& .\tests\run-pve.ps1
& .\tests\run-combat.ps1
& .\tests\run-progression.ps1
& .\tests\run-xp.ps1
& .\tests\run-yang.ps1
```

Tests use test databases. PvE, combat, progression, XP and Yang share port 18098;
run them sequentially. Full login/relog through normal servers is covered in the
item and PvE documents; these scenarios create local test accounts.
Work on `codex/<topic>` branches, review and verify changes, then merge locally
with `--no-ff`. See [AGENTS.md](AGENTS.md).

## Documentation

- [Project direction and priorities](docs/project-direction.md)
- [Persistence policy](docs/persistence-policy.md)
- [3D spike and movement transport](docs/spike3d.md)
- [Item instances and persistence](docs/item-instances.md)
- [PvE, ground loot and pickup](docs/pve-ground-loot.md)
- [Combat Feel Pass and controls](docs/combat-feel.md)
- [Item progression: comparison, equipment and damage](docs/item-progression.md)
- [Character XP and levels](docs/character-xp.md)
- [Yang wallet and ground currency](docs/yang-wallet.md)
- [Optional local development visuals](docs/local-dev-visuals.md)
- [Warrior compatibility](docs/warrior-compatibility.md)
- [External legacy asset pipeline history](docs/legacy-asset-pipeline.md)
- [Web UI foundation](docs/web-ui.md)
- [Historical CEF UI spike](docs/cef-ui-spike.md)
- [CI](docs/ci.md)
- [Cleanup and remaining dependencies](docs/repository-cleanup.md)
- [Open-MT2 reference analysis](docs/open-mt2-analysis.md)
- [Original spike plan](docs/Mandate-of-Three_TinyMMO_Spike_Plan.pdf)
- [Design decisions](docs/Mandate_of_Three_Design_Decisions.pdf)

## Upstream and credits

The fork retains Godot Tiny MMO infrastructure by **slayhorizon**:
[upstream repository](https://github.com/SlayHorizon/godot-tiny-mmo) and
[infrastructure documentation](https://slayhorizon.github.io/godot-tiny-mmo/).
Upstream maps were created by **higaslk**; some remaining assets are from
**Anokolisa / Dungeon Crawler Pixel Art Asset Pack**. Upstream acknowledgements
also include Jackiefrost, d-Cadrius and other contributors.

Open-MT2 is a behavioral reference for Metin, without importing its code, assets
or runtime. Upstream code uses the [MIT license](LICENSE), with its copyright notice retained.
