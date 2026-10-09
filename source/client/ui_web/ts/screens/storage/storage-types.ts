import type {
  ItemPresentation,
  PositionedItem,
} from '../../game-ui/item-types.js';
// Storage owns its capacity and page model; Inventory's wire contract is unchanged.
export interface StorageItem extends ItemPresentation, PositionedItem {
  page: number;
}
export interface StorageSnapshot {
  columns: 15;
  rows: 9;
  pages: 2;
  items: readonly StorageItem[];
}
