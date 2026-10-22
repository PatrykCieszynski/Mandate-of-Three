# Mandate of Three

A multiplayer 3D game inspired by Metin2, built with Godot on
[Godot Tiny MMO](https://github.com/SlayHorizon/godot-tiny-mmo) infrastructure.
This is a working technical prototype, not a public game alpha.

**Start with [the documentation index](docs/README.md)** for current contracts,
runbooks, accepted designs and historical evidence.

## Running baseline

- Godot 4.7.2; Gateway, Master and one World Process.
- PostgreSQL for accounts, character profiles and Economy. SQLite remains a
  reference/legacy fixture backend, without automatic fallback.
- Server-authoritative movement, Warrior combat, mob packs, Metin encounters,
  ground loot, XP/levels and Yang checkpoints.
- Persistent Inventory/Equipment, Storage, NPC Shop/Upgrade and
  Marketplace/Auction/Exchange, with atomic economic transactions and recovery.
- TypeScript/CEF screen-space UI, targeting Vulkan Forward+; Mobile remains a
  launcher comparison option. Compatibility/OpenGL is unsupported / best-effort.
- First Region is a graybox. Terrain3D authoring and the client visual stack are
  available; the authored world and final artwork are unfinished.

See [implemented systems](docs/implemented/README.md) and
[project direction](docs/decisions/project-direction.md). AOI, local prediction,
multi-World hosting and a distributed Economy Service are not shipped features.
Synthetic profiling results do not establish connected-player capacity.

## Local setup and launch

Install **Godot 4.7.2** locally under `.godot/`, **Node 20.19+**, PostgreSQL and
pinned native addons. Binaries, runtime stores and credentials are not versioned.
Follow [full-state PostgreSQL setup](docs/development/postgres-full-state.md) and
[CEF addon setup](docs/ui/cef-addon-integration.md) before first launch. A missing
or failed PostgreSQL deployment does not fall back to SQLite.

From the repository root, use the scripts in `package.json` or the shared
WebStorm `.run` configurations:

```powershell
npm run servers:start
& ./tools/cef_client/run.ps1
```

The client launcher installs/imports the pinned CEF addon and runs the actual
checkout with Forward+ / Vulkan. For setup without a game window:

```powershell
& ./tools/cef_client/run.ps1 -SetupOnly
```

`servers:restart` restarts Master + World; `world:restart` restarts only World.
`servers:status` reports owned local processes/listeners; `servers:stop` stops all
roles. They run hidden with logs under `.godot/runtime` and preserve runtime
stores. Stop/restart requests a final save and refuses to force-kill an unsaved
World. Direct entry: `./tools/servers.ps1 -Action restart -Target game`.
See [process startup](docs/development/postgres-process-startup.md) and
[backup/restore](docs/development/postgres-backup-restore.md).

Controls: **WASD** movement, **RMB** camera orbit, mouse wheel zoom, **I** Inventory,
**hold Space** directional combo, **E** nearby item pickup. **Left click** selects
an optional target; **F** toggles autoattack, interrupted by manual movement.
Nearby Yang is picked up automatically; **G** picks up a nearby currency stack.
Optional local models use [development asset staging](docs/development/local-dev-visuals.md).
Map authors can use the [offline editor playtest](docs/world/map-playtest.md).
Inherited resources still have startup dependencies; see the
[legacy removal boundary](docs/development/inherited-runtime.md#resource-removal-boundary)
before deleting asset trees.

## Verification and contributions

```powershell
git diff --check
& ./tests/run-smoke.ps1
```

Smoke is headless. Select additional suites for the changed boundary using the
[testing policy](docs/development/testing.md); run port-18098 network suites
sequentially and use disposable databases. Native client/export checks are
separate from smoke and do not prove physical input or Linux readiness.
Follow [repository workflow](AGENTS.md). Keep local diagnostics in
`.godot/verification`; `tools/clean-dev-artifacts.ps1` removes disposable outputs
while preserving binaries, imports, references, CEF and runtime data.

## Upstream and credits

Godot Tiny MMO infrastructure is by **slayhorizon**:
[repository](https://github.com/SlayHorizon/godot-tiny-mmo) and
[upstream documentation](https://slayhorizon.github.io/godot-tiny-mmo/).
Upstream maps were created by **higaslk**; retained assets include work by
**Anokolisa / Dungeon Crawler Pixel Art Asset Pack**. Upstream acknowledgements
also include Jackiefrost, d-Cadrius and other contributors.

Open-MT2 is a behavior reference, not a runtime dependency. Optional legacy
reference/conversion assets stay local and are not part of versioned artwork.
Upstream code uses the [MIT license](LICENSE), with its copyright notice retained.
