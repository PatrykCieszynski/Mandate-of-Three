import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { carriedCell, placement } from '../inventory/placement.js';
export class NpcShopOfferDragSubject {
    npcInstanceId;
    serviceId;
    offer;
    constructor(npcInstanceId, serviceId, offer) {
        this.npcInstanceId = npcInstanceId;
        this.serviceId = serviceId;
        this.offer = offer;
    }
}
export function shopOfferPayload(subject, slotSize, resolveItemIcon) {
    return {
        sourceId: 'npc-shop',
        subject,
        presentation: {
            width: slotSize - 2,
            grabOffset: { x: slotSize / 2, y: slotSize / 2 },
            height: subject.offer.height * slotSize - 2,
            render: (ghost) => paintItemIcon(ghost, { ...subject.offer, icon_id: subject.offer.iconId }, { resolveItemIcon }),
        },
    };
}
export function shopGridPreview(element, model, page, slotSize, payload, pointer) {
    if (!(payload.subject instanceof NpcShopOfferDragSubject))
        return { valid: false, data: null };
    const rect = element.getBoundingClientRect();
    const cell = carriedCell({
        x: (pointer.point.x - rect.left) / pointer.scale,
        y: (pointer.point.y - rect.top) / pointer.scale,
    }, pointer.grabOffset, slotSize);
    // Empty identity cannot exclude an owned item from occupied cells.
    const position = placement(model, { id: '', height: payload.subject.offer.height }, cell.x, cell.y, page);
    const marker = document.createElement('div');
    marker.className = 'placement-preview' + (position.valid ? '' : ' invalid');
    marker.style.left = cell.x * slotSize + 'px';
    marker.style.top = cell.y * slotSize + 'px';
    marker.style.height = payload.subject.offer.height * slotSize + 'px';
    return {
        valid: position.valid,
        data: { subject: payload.subject, position },
        visual: { element: marker, parent: element },
    };
}
