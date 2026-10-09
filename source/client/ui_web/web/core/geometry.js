// Physical viewport, logical UI geometry. Skins never supply these dimensions.
export function clampWindow(position, size, viewport, scale) {
    return { x: Math.max(0, Math.min(position.x, viewport.width / scale - size.width)),
        y: Math.max(0, Math.min(position.y, viewport.height / scale - size.height)) };
}
