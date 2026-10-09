import type {InventoryItem} from '../protocol/contracts.js';
import type {ResolveItemIcon} from './item-types.js';
import {UiSlot} from '../core/primitives/ui-slot.js';
import {paintItemIcon} from './item-icon.js';
export function UiItemSlot({item,slotSize,resolveItemIcon}: {item: InventoryItem; slotSize: number; resolveItemIcon: ResolveItemIcon}) {
  const element=UiSlot({className:'inventory-item',label:item.name});element.dataset.id=item.id;element.dataset.height=String(item.height);
  element.style.height=item.height*slotSize-2+'px';paintItemIcon(element,item,{resolveItemIcon});return element;
}
