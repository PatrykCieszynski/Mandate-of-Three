import type { ItemTooltipDetails } from './items/item-tooltip-model.js';
export type ItemIconId = string;
export interface ItemPresentation {
  id: string; revision: number; name: string; icon_id: ItemIconId;
  height: number; quantity: number; description?: string; tooltip?: ItemTooltipDetails;
}
export type ResolveItemIcon = (id: ItemIconId) => string | null;

// Slot content has no inventory coordinates, page, revision or equipment location.
export type ItemSlotPresentation = Pick<ItemPresentation,'id'|'name'|'icon_id'|'height'|'quantity'>;
export type ItemIconPresentation = Pick<ItemPresentation,'name'|'icon_id'|'quantity'>;
export interface PositionedItem { x: number; y: number; height: number }
export interface ItemGridModel<T extends PositionedItem> { columns: number; rows: number; items: readonly T[] }
