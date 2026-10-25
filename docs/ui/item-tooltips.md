# Item tooltip presentation

Accepted 2026-10-10. `game-ui/items/item-tooltip.ts` is the shared renderer for
Inventory, Equipment, Storage and Shop. `UiTooltip` remains domain-agnostic and
owns positioning/clamping. No affix rolling, stat effects, item schema or server
mechanics are added in this pass.

## Content and rarity

Optional `tooltip` presentation metadata contains category, property lines,
requirement lines and affixes. An affix has one to three display lines and an
optional `kind: prefix | suffix`. IPC validates the shape, bounded text/arrays,
maximum six affixes, maximum three classified prefixes and three suffixes.

Production metadata carries the saved `tooltip.rarity`: Normal (white), Magic
(blue), or Rare (yellow). The renderer uses it independently of affix count;
five/six bonuses no longer imply Legendary. See [crafting and migration](../gameplay/item-progression.md#crafting-currencies-c3).
`itemRarity` remains a presentation-only fallback for old preview metadata:
zero bonuses Normal, one/two Magic, three/six Rare. It never authorizes crafting.

One affix may display several effects; lines are not counted as separate affixes.
Properties, requirements, upgrade and sockets do not contribute. The name and
frame use the colour, without a rarity label or affix counter. Empty sections
are hidden. Existing descriptions and offer prices remain supported; owned-item
replacement clears offer pricing. All supplied text uses `textContent`.

Normally only bonus effects appear. Hold Alt to reveal Prefix/Suffix below each
classified affix, release to hide them. Changes work without moving the mouse;
expanded content is measured and clamped again using the existing scale/viewport.
Item tooltips use a manual browser top layer to stay above neighboring windows,
without activating a window or changing keyboard focus. Unsupported hosts retain
ordinary positioning. Owner hiding also dismisses the top layer.
Bonus order stays fixed. Blur/hiding/disposal do not resurrect the tooltip.

Existing native attack rolls have no prefix/suffix metadata. They are displayed
and counted faithfully, without inventing a classification. Their gameplay
behaviour is unchanged. Versioned production rolls carry their actual kind; legacy bonuses remain unclassified.

## Input and preview

Pointer-only CEF keeps keyboard ownership in gameplay. CoreUiController
samples Alt and emits only transitions as `ui.tooltip_details {alt: boolean}`;
ready synchronizes the current state and application focus loss releases it.
WebBridge validates this presentation message (no request ID, exactly one boolean),
and composition forwards it to the tooltip. No server RPC or domain store update
is involved. Native input takes precedence over pointer modifier flags.

Browser-only preview supports DOM Alt and mirrors parent-page Alt to its iframe,
so hovering works without clicking to acquire keyboard focus. Reset fixtures show
six-affix Rare sword, Rare armour, Magic equipped sword and Normal material. Fixture
bonuses do not affect simulated transfers or production stats.

Default smoke exercises generated JS rarity boundaries, multiline affixes,
section replacement/escaping, stationary Alt and blur/dispose, native message
validation and malformed domain preservation. The native headless bridge checks
modifier transitions and focus loss. The opt-in browser preview suite checks Alt
against the real iframe. Native CEF input handoff is a manual milestone check.
