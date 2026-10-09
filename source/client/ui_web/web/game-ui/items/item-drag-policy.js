import { carriedCell, placement } from '../../screens/inventory/placement.js';
import { paintItemIcon } from './item-icon.js';
// A current owned-item policy contract, deliberately outside the opaque runtime.
// Future offer subjects need their own policies, without changing gesture mechanics.
export class OwnedItemDragSubject {
    container;
    item;
    constructor(container, item) {
        this.container = container;
        this.item = item;
    }
}
export function ownedItemPayload(container, item, slotSize, resolveItemIcon) {
    return {
        sourceId: container,
        subject: new OwnedItemDragSubject(container, item),
        presentation: {
            width: slotSize - 2,
            height: item.height * slotSize - 2,
            render: (ghost) => paintItemIcon(ghost, item, { resolveItemIcon }),
        },
    };
}
export function itemGridPreview(element, model, page, slotSize, payload, pointer) {
    if (!(payload.subject instanceof OwnedItemDragSubject))
        return { valid: false, data: null };
    const rect = element.getBoundingClientRect();
    const cell = carriedCell({
        x: (pointer.point.x - rect.left) / pointer.scale,
        y: (pointer.point.y - rect.top) / pointer.scale,
    }, pointer.grabOffset, slotSize);
    const position = placement(model, payload.subject.item, cell.x, cell.y, page);
    const marker = document.createElement('div');
    marker.className = 'placement-preview' + (position.valid ? '' : ' invalid');
    marker.style.left = cell.x * slotSize + 'px';
    marker.style.top = cell.y * slotSize + 'px';
    marker.style.height = payload.subject.item.height * slotSize + 'px';
    return {
        valid: position.valid,
        data: { subject: payload.subject, position },
        visual: { element: marker, parent: element },
    };
}
export function itemWindowControls(drag, root) {
    if (!drag)
        return [];
    return [...root.querySelectorAll('.window-header')].map((element) => drag.registerControl(element, 'cancel'));
}
