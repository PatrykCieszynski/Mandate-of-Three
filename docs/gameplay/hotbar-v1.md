# Hotbar and world HUD

The client owns sixteen shortcut preferences, in two banks: **1–8** and **F1–F8**.
The bottom CEF HUD shares the existing window/slot skin and UI scale. Banks wrap
as intact groups on narrow viewports; key labels and icons keep their logical size.
HP/MP bars use owner combat snapshots and authoritative maximum values, including
Stats V1 changes. No hardcoded health or mana is presented as gameplay data.
The system bar opens Inventory/Equipment, Character · V and the existing native
Options menu. Browser preview can exercise the two CEF windows; native Options
requires Godot and produces explicit preview-only feedback in the browser host.

## Assignment and activation

Drag an Inventory item with primary action **USE** onto any slot to assign its UID. This never moves custody,
changes its bag position or creates/copies an item. Storage, Equipment and shop
subjects cannot be assigned through this drop target. Right click clears the
preference. Reassign by dropping another Inventory item onto the same slot.
There is no skill use or hotbar-to-hotbar gesture in this slice.

Click or the corresponding key calls the existing receipt-backed Inventory
activation path, resolving the item's **current** bag UID/revision. Native input
ignores repeats and modifier combinations; chat/text/menu ownership suppresses
shortcut activation. Server authorization, ownership, revision and receipts remain
unchanged. Missing/equipped/stored items retain an unavailable preference; returning
the same UID to Inventory reactivates it only if its current action is USE. There is no automatic substitution by
item definition, no new ownership authority and no saved obsolete revision.
An unavailable binding cannot activate an item in account Storage or Equipment.

Hotbar rejects EQUIP, NONE and unknown definitions both at assignment and activation.
Browser drop validation uses projected definition metadata; the native adapter independently
checks canonical content, including shortcuts restored from older preference files.
Old non-USE preferences remain visible but unavailable and can be cleared/replaced.
No canonical USE content or new USE effects are introduced here. USE remains unsupported
by the current server; existing Inventory EQUIP behavior is unchanged. Skill references
remain a model seam, with no active skill assignment/use in this slice.

Inventory activation reuses the existing stable operation journal/recovery.
A lost response is never treated as proof of failure; pending Inventory operations
must be resolved through Inventory recovery before another action. The HUD does
not introduce a second mutation queue or change server transactions.

## Preferences and lifetime

`HotbarBindings` holds references only; no item or skill state. The existing eight
slot format loads into the first bank with an empty second bank. Invalid loads
preserve prior state. The client atomically saves preferences below
`user://hotbar_bindings`, scoped by authority/account/character from authenticated
Inventory context. These are local client preferences, not PostgreSQL or account
settings, and do not synchronize between machines. CEF reload retains native
state; local CH transfer, new composition and same-character relog restore the
file. Other characters/authorities use separate files. Corrupt/unwritable files
fail closed with feedback and are not silently deleted.

`hotbar` is a separately validated presentation domain: sixteen entries, current
availability/quantity, busy/error and owner vitals. Native handlers accept only a
slot index and, for assignment, an existing bag UID. No client-supplied revision,
tier, HP/MP or final effect is accepted. Inventory snapshots refresh bindings;
combat snapshots refresh bars. Icon elements are retained when content is unchanged.
The HUD registers its visible panel as a CEF pointer region; the surrounding world
stays interactive. Drag behavior is shared with Inventory's existing runtime.

## Verification

- `tests/hotbar_bindings.tscn`: model/JSON/legacy format, unavailable ownership,
  atomic preference replacement, current revision, persistence and character scope.
- Web contracts cover sixteen keys, vitals validation, Inventory-only drop,
  assignment without relocation, clear/activate/system intentions and disposal.
- `tests/run-combat.ps1 -Scene hotbar_network -MarkerPrefix HOTBAR` verifies real
  EQUIP rejection (including restored shortcuts) and local CH restoration. `-NativeClient1` exercises the
  actual CEF adapter, F1, input ownership, Options, vitals and reload. Native keys
  are synthetic; physical keyboard/IME/Alt-Tab acceptance remains manual.
- Existing browser preview tests use actual pointer drag to assign/clear a slot
  through the production view, plus sample/empty HUD fixtures and existing windows.
  Preview fixtures never execute authoritative item actions.
