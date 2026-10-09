import type { Point, Size, Viewport } from './window-types.js';
// Physical viewport, logical UI geometry. Skins never supply these dimensions.
export function clampWindow(
  position: Point,
  size: Size,
  viewport: Viewport,
  scale: number,
) {
  return {
    x: Math.max(0, Math.min(position.x, viewport.width / scale - size.width)),
    y: Math.max(0, Math.min(position.y, viewport.height / scale - size.height)),
  };
}
