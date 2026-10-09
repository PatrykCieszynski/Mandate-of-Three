import type {ItemSlotPresentation, ResolveItemIcon} from '../item-types.js';
import {UiSlot} from '../../core/primitives/ui-slot.js';
import {paintItemIcon} from './item-icon.js';
export function UiItemSlot({item,slotSize,resolveItemIcon}: {item: ItemSlotPresentation; slotSize: number; resolveItemIcon: ResolveItemIcon}) {
  const element=UiSlot({className:'ui-item-slot',label:item.name});element.dataset.id=item.id;element.dataset.height=String(item.height);
  element.style.height=item.height*slotSize-2+'px';paintItemIcon(element,item,{resolveItemIcon});return element;
}
