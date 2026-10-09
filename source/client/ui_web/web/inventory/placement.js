// Advisory preview only. The authenticated world server decides every move.
export function carriedCell(pointer, grabOffset, slotSize) {
  // Snap the whole footprint to the nearest grid origin, preserving the grab point.
  return {x: Math.round((pointer.x - grabOffset.x) / slotSize),
          y: Math.round((pointer.y - grabOffset.y) / slotSize)};
}
export function placement(inventory, item, x, y, page) {
  const valid = Number.isInteger(x) && Number.isInteger(y) && Number.isInteger(page) &&
    x >= 0 && x < inventory.columns && y >= 0 && y + item.height <= inventory.rows &&
    page >= 0 && page < inventory.pages && !inventory.items.some(other =>
      other.id !== item.id && other.page === page && other.x === x &&
      y < other.y + other.height && y + item.height > other.y);
  return {x, y, page, valid};
}
export function clampWindow(position, size, viewport, scale) {
  return {x: Math.max(0, Math.min(position.x, viewport.width / scale - size.width)),
          y: Math.max(0, Math.min(position.y, viewport.height / scale - size.height))};
}
