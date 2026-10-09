// Current Storage geometry; skins never change these domain dimensions.
export const STORAGE_COLUMNS = 15;
export const STORAGE_ROWS = 9;
export const STORAGE_PAGES = 2;
export const STORAGE_PAGE_CELLS = STORAGE_COLUMNS * STORAGE_ROWS;
export const STORAGE_CAPACITY = STORAGE_PAGE_CELLS * STORAGE_PAGES;
export { ITEM_SLOT_SIZE } from '../../game-ui/items/item-geometry.js';
