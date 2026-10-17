# Hotbar V1 — foundational bindings

This PR introduces only **eight quick-slot bindings**. Slots point to an item UID or a skill ID, never own item instances or skill state. Missing inventory items and unlearned skills resolve to an unusable binding. Persisting preferences and rendering the CEF bar are deferred to UI integration.

The current horn PR (#54) still exposes its provisional H key, default/basic tier, and server cooldown. Before integrating with the hotbar, implement an authoritative item USE path checking equipped/owned horn UID and tier on each invocation. Never trust a client's claimed tier, inventory slot or cooldown. Do not ship a hotbar that calls a free/unowned horn skill as an item shortcut.

Also deferred: drag/drop UX, action feedback and cooldown overlays, HP/MP projection and layout, binding save/load via account settings and reconnect, keyboard focus rules.

This is intentionally separate from modifying CoreUiController and its CEF front end: use the existing web UI architecture, not a second Godot HUD.

## Bottom CEF preview

The same PR now mounts a persistent bottom-center 8-slot bar in the existing `web/inventory/game.html` CEF page. Its CSS uses the shared `--skin-slot-normal`, `--frame`, `--ink`, and `--muted` values already used by the Metin-inspired inventory skin. The bar is deliberately pointer-transparent and displays empty reference slots, because actual item UID activation, assignment, skill activation and cooldown sync have not yet been wired. It contains no hardcoded health/mana figures.

Before enabling interactions, integrate slot binding state through existing `UiCommandDispatcher` domains and validate item USE authorization on the server. Keep the CEF pointer-region lease accurate once the bar becomes interactive.
