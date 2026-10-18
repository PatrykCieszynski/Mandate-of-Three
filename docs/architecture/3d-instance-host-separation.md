# 3D instance host separation (PR #82)

## Runtime inheritance after extraction

```
ServerInstance : SubViewport
  - authoritative instance identity, admission, peers, lifecycle and shared admin state
  - RPC/data-only compatibility surface for old server handlers
  ├── WorldInstance3D (production)
  │     └── GameWorld3D (authoritative 3D movement and gameplay)
  └── LegacyServerInstance2D (fixture-only)
        - Player and Map2D instantiation, old synchronizers and status ticks
        - legacy warper, spawn and despawn implementation

WorldInstanceClient3D : Node (production client container)
  └── GameWorld3D (client projection and input)
InstanceClient : Node (dormant old 2D client)
```

The 3D client and server **do not inherit 2D Player, Map, synchronizer, warp or stat regeneration implementations**. Authenticated node paths and the inert legacy host RPC method signatures remain stable, so new 3D GameWorld3D RPCs still use the existing network location.

## Remaining migration boundary

The neutral server host deliberately retains two data-only compatibility members, `players_by_peer_id` and `instance_map`, plus an inert legacy despawn RPC. Old request handlers and test fixtures still reference those names; they do not cause any 2D gameplay initialization in the production host. Moving or deleting them safely requires retiring/replacing those request handlers, rather than changing 3D movement/economy code.

The 2D implementation is intentionally retained in `LegacyServerInstance2D` for parser and admission fixtures, not constructed by the production instance manager. `InstanceClient` and old 2D content remain in the repository until the separate legacy-deletion review. `PlayerResource`, store/SQLite, economy, social commands and active export tooling are shared or independently owned and must be kept.

## Verification

The PR's GitHub workflow runs Godot clean import, boundary checks, prototype smoke and real two-client `run-spike3d.ps1` plus `run-pve.ps1` networking regressions. The separate `local_map_instances.gd` fixture was strengthened to reject a 2D adapter in production, but it does not have a dedicated runner in the default workflow. Packaged client/server exports remain a distinct validation requirement inherited from PR #67.
