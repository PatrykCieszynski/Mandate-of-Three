# NPC Upgrade CEF preview

Implemented 2026-10-10. This stage adds presentation for +0 through +9 only.
The accepted first gameplay transaction remains +0 to +1, Yang plus one material,
100% success. No upgrade RPC, recipe Resource, inventory mutation, wallet spend,
persistence, failure, destruction or downgrade is introduced here.

## Access and behavior

Select Upgrade at the Blacksmith. The existing authoritative NPC selection opens
`screens/upgrade/upgrade-view.ts` instead of the service placeholder. The client
presentation also opens Inventory. The shared UiWindow initially places Upgrade
beside Inventory and supplies clamping, drag, scaling and small-viewport scrolling.

Drag an Inventory Iron Sword into the target slot to inspect it. This uses the
shared item drag runtime and an inspection-only drop policy: the item stays in
Inventory, with the same UID, revision and placement. Other containers, offers,
stacked items and unsupported icons/levels do not qualify. The current prototype
only has an Iron Sword definition. Until structured upgrade-level metadata lands,
the presentation reads its existing trailing +0 through +9 label; this must never
become gameplay validation. A changed inventory revision refreshes the selection;
a missing selected item clears it. Leaving/changing NPC service resets local state.

The panel shows icon, rarity-colored name, category, effective Attack comparison,
existing affix lines and requirements when supplied, a required material row,
Yang cost and success chance. Hover uses the shared ItemTooltip. At +9 the recipe
is hidden, the action is disabled and the panel displays the maximum-level state.

The game view selects items only through the Inventory drop target. Upgrade is
its prominent primary action, with a smaller Cancel directly below. The result
has space above/below its level and Attack comparison; materials, Yang cost and
success chance follow underneath. Upgrade opens inline confirmation; Confirm
advances only the local display by one step. Back/Escape first cancel confirmation. Outside it,
Cancel/close/Escape follow the shared NPC routing: menu for multiple services,
end interaction for one service. Escape still cancels a carried item first.

The preview-only notice remains visible until gameplay is connected. Development
controls are absent from the game. Open `source/client/ui_web/web/dev/upgrade.html`
through a local Web asset server for the standalone development page: it opts into
`devPreview`, provides Preview Iron Sword and mouse-only minus/plus level controls,
and mounts no Web bridge or real gameplay state. The game entry never imports
that development module. Temporary fixture values
are next level times 1000 Yang, one material per three next levels rounded up,
100% chance, and Iron Sword's existing +2 Attack per level. Material icon/name and
costs are illustrative presentation data, not accepted economy/balance. Inventory
material availability and wallet affordability are deliberately not simulated.

## Verification

Default `tests/run-smoke.ps1` includes a small local-state contract: source item
immutability, cancellation/context reset and registration cleanup. It does not
assert pixel geometry or a specific DOM tree.

Optional `tests/run-shop-browser.ps1` now checks both NPC Shop and Upgrade using
production HTML/JS, controlled IPC and installed Playwright/Chrome. Upgrade checks
real Inventory mouse-drop inspection, all nine confirmations through +9, maximum
state, Escape/back, scale/viewport bounds and absence of item/economy commands.
It also verifies that example/level controls exist only on the standalone dev page.
Both legacy skin and CSS fallback are covered; optional PNGs are diagnostic only.
This browser check does not verify embedded native CEF/GPU behavior.
