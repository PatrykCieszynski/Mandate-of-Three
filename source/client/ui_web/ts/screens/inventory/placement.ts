import type { Point } from '../../core/window/window-types.js';
import type {
  InventoryItem,
  InventorySnapshot,
} from '../../protocol/contracts.js';
export type PlacementInventory = Omit<InventorySnapshot, 'items'> & {
  items: Pick<InventoryItem, 'id' | 'height' | 'x' | 'y' | 'page'>[];
};
export type Placement = ReturnType<typeof placement>;
// Advisory preview only. The authenticated world server decides every move.
export function carriedCell(
  pointer: Point,
  grabOffset: Point,
  slotSize: number,
) {
  // Snap the whole footprint to the nearest grid origin, preserving the grab point.
  return {
    x: Math.round((pointer.x - grabOffset.x) / slotSize),
    y: Math.round((pointer.y - grabOffset.y) / slotSize),
  };
}
export function placement(
  inventory: PlacementInventory,
  item: Pick<InventoryItem, 'id' | 'height'>,
  x: number,
  y: number,
  page: number,
) {
  const valid =
    Number.isInteger(x) &&
    Number.isInteger(y) &&
    Number.isInteger(page) &&
    x >= 0 &&
    x < inventory.columns &&
    y >= 0 &&
    y + item.height <= inventory.rows &&
    page >= 0 &&
    page < inventory.pages &&
    !inventory.items.some(
      (other) =>
        other.id !== item.id &&
        other.page === page &&
        other.x === x &&
        y < other.y + other.height &&
        y + item.height > other.y,
    );
  return { x, y, page, valid };
}

// Advisory receiving preview. Absence of a requested position means first fit;
// authoritative placement and transactions remain exclusively in World.
export function firstFittingPlacement(
  inventory: PlacementInventory,
  item: Pick<InventoryItem, 'id' | 'height'>,
): Placement | null {
  for (let page = 0; page < inventory.pages; page++)
    for (let y = 0; y < inventory.rows; y++)
      for (let x = 0; x < inventory.columns; x++) {
        const candidate = placement(inventory, item, x, y, page);
        if (candidate.valid) return candidate;
      }
  return null;
}
