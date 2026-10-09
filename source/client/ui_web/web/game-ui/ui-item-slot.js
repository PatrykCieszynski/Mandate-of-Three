import { UiSlot } from '../core/ui-slot.js';
import { paintItemIcon } from './item-icon.js';
export function UiItemSlot({ item, slotSize, resolveItemIcon }) {
    const element = UiSlot({ className: 'inventory-item', label: item.name });
    element.dataset.id = item.id;
    element.dataset.height = String(item.height);
    element.style.height = item.height * slotSize - 2 + 'px';
    paintItemIcon(element, item, { resolveItemIcon });
    return element;
}
