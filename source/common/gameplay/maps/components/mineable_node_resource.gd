class_name MineableNodeResource
extends Resource
## Data-only definition of a gathering node "type" (Copper Vein, Iron Vein,
## Healing Herb, ...). A [MineableNode] scene instanced in a map points at
## one of these resources via its `data` export, then reads the gathering
## config from it. Tuning copper vein values now updates every copper vein
## in every map at once. Gathering currently grants items only.

## The item granted per yield (a MaterialItem; its outlet is a vendor trade or a recipe).
@export var ore: Item
@export var yield_amount: int = 1
## Tool the player must have equipped (matched against ToolItem.tool_type).
@export var required_tool: StringName = &"pickaxe"

@export_group("Extraction")
## HP the per-player progress drains before one charge is consumed and the
## player gets the yield. Each pickaxe swing chips this down by the swing's
## extraction_damage.
@export var extraction_hp: int = 3
## Total shared yields before depletion. Snap-refills as a group.
@export var max_charges: int = 3
## Continuous regen while at least 1 charge remains: +1 charge every X sec.
@export var charge_regen_seconds: float = 12.0
## Recharge time after the node hits 0 charges. Longer than continuous regen,
## refills ALL charges at once.
@export var depleted_recharge_seconds: float = 60.0
## Per-player cooldown after a successful extraction.
@export var player_cooldown_seconds: float = 5.0

@export_group("Visual")
## Sprite shown at the node. Use an [AtlasTexture] (right-click in the
## inspector → "New AtlasTexture", then assign the spritesheet to its `atlas`
## and click "Edit Region" to pick the sub-rect visually). A plain Texture2D
## also works for one-off art.
@export var texture: Texture2D
