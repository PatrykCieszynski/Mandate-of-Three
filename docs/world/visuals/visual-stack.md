# Current visual stack — consolidated V0–V3

The early V0–V3 work was **implemented**, not an ongoing list of tasks. The original detailed notes are available in [Git history](https://github.com/PatrykCieszynski/Mandate-of-Three/tree/88b448a4fcf2476e43a7cce504df4987e5371d2b/docs/world/visuals). For current Terrain3D usage, see [V4 terrain](visual-upgrade-v4-terrain3d.md) and [authoring guide](../terrain3d-authoring-guide.md).

## Renderer and CEF (V0)
Desktop client uses Forward+ / Vulkan; historical Windows native verification used Godot 4.7.2, CEF v2.0.0 and an RTX 4070. Do not infer Linux or mobile parity from that check. See [CEF integration](../../ui/cef-addon-integration.md).

## Lighting and sky (V1–V2)
Sky3D and the authored WorldVisualEnvironment provide clouds, atmosphere, sun/moon and the day/night cycle. V1's static summer 15:30 reference was superseded by V2's server-derived WorldTime calendar. The client renders/interpolates the visual profile; server time remains authoritative. This is not yet a full weather or dynamic-events framework.

## Water (V3)
First Region's old solid water box was replaced with a client-only custom ShaderMaterial water surface using three Gerstner waves. Water and its visual bed are omitted in headless World. This is **presentation**, not server swimming/navigation/collision. Map water authoring remains a separate concern.

## Status
V0–V3 original benchmark values, node paths and detailed acceptance matrices are historic snapshots, not current operating instructions. Update this single guide when changing the accepted client visual stack; do not add a new per-PR visual summary.
