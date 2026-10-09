import { clampWindow } from './geometry.js';
const defaultPlacement = { kind: 'viewport', anchor: 'top-right' };
// Only measured, logical geometry. Screens own dimensions and placement choices.
export class WindowLayout {
    geometry;
    entries = new Map();
    constructor(geometry) {
        this.geometry = geometry;
    }
    register(id, element, placement = defaultPlacement) {
        this.entries.set(id, { element, placement, size: null, position: null, manual: false });
    }
    unregister(id) { this.entries.delete(id); }
    entry(id) {
        const entry = this.entries.get(id);
        if (!entry)
            throw new Error('Unknown window: ' + id);
        return entry;
    }
    measure(entry) {
        if (entry.element.getClientRects().length)
            entry.size = { width: entry.element.offsetWidth, height: entry.element.offsetHeight };
        return entry.size;
    }
    viewportPosition(placement, size) {
        const { viewport, scale } = this.geometry(), offset = placement.offset ?? { x: 0, y: 0 };
        return { x: (placement.anchor.endsWith('right') ? viewport.width / scale - size.width : 0) + offset.x,
            y: (placement.anchor.startsWith('bottom') ? viewport.height / scale - size.height : 0) + offset.y };
    }
    clamp(position, size) {
        const { viewport, scale } = this.geometry();
        return clampWindow(position, size, viewport, scale);
    }
    place(id, visiting = new Set()) {
        const entry = this.entry(id);
        if (visiting.has(id))
            throw new Error('Cyclic window placement: ' + id);
        visiting.add(id);
        const size = this.measure(entry) ?? { width: 0, height: 0 };
        let position = entry.position ?? { x: 0, y: 0 };
        if (!entry.manual) {
            const placement = entry.placement;
            if (placement.kind === 'viewport')
                position = this.viewportPosition(placement, size);
            else {
                position = this.viewportPosition(placement.fallback ?? defaultPlacement, size);
                const target = this.entries.get(placement.target), targetSize = target && this.measure(target);
                if (targetSize) {
                    const anchor = this.place(placement.target, visiting), gap = placement.gap ?? 0, offset = placement.offset ?? { x: 0, y: 0 };
                    const horizontal = placement.side === 'left' || placement.side === 'right';
                    const difference = horizontal ? targetSize.height - size.height : targetSize.width - size.width;
                    const alignment = placement.align === 'center' ? difference / 2 : placement.align === 'end' ? difference : 0;
                    switch (placement.side) {
                        case 'left':
                            position = { x: anchor.x - size.width - gap, y: anchor.y + alignment };
                            break;
                        case 'right':
                            position = { x: anchor.x + targetSize.width + gap, y: anchor.y + alignment };
                            break;
                        case 'top':
                            position = { x: anchor.x + alignment, y: anchor.y - size.height - gap };
                            break;
                        case 'bottom':
                            position = { x: anchor.x + alignment, y: anchor.y + targetSize.height + gap };
                            break;
                    }
                    position = { x: position.x + offset.x, y: position.y + offset.y };
                }
            }
        }
        entry.position = this.clamp(position, size);
        visiting.delete(id);
        return { ...entry.position };
    }
    move(id, position) {
        const entry = this.entry(id);
        entry.manual = true;
        entry.position = this.clamp(position, this.measure(entry) ?? { width: 0, height: 0 });
        return { ...entry.position };
    }
    resetPosition(id) { const entry = this.entry(id); entry.manual = false; entry.position = null; }
}
