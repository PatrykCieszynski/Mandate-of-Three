# Hotbar V1 — foundational bindings

This PR introduces only **eight quick-slot bindings**. Slots point to an item UID or a skill ID, never own item instances or skill state. Missing inventory items and unlearned skills resolve to an unusable binding. Persisting preferences and rendering the CEF bar are deferred to UI integration.

The current horn PR (#54) still exposes its provisional H key, default/basic tier, and server cooldown. Before integrating with the hotbar, implement an authoritative item USE path checking equipped/owned horn UID and tier on each invocation. Never trust a client's claimed tier, inventory slot or cooldown. Do not ship a hotbar that calls a free/unowned horn skill as an item shortcut.

Also deferred: drag/drop UX, action feedback and cooldown overlays, HP/MP projection and layout, binding save/load via account settings and reconnect, keyboard focus rules.

This is intentionally separate from modifying CoreUiController and its CEF front end: use the existing web UI architecture, not a second Godot HUD.
