import type { STORAGE_COLUMNS, STORAGE_ROWS, STORAGE_PAGES } from '../screens/storage/storage-model.js';
// Existing native wire contracts; protocol.ts validates unknown input.
import type {Viewport} from '../core/window/window-types.js';
import type {ItemPresentation} from '../game-ui/item-types.js';
export interface InventoryItem extends ItemPresentation { x: number; y: number; page: number }
export interface EquipmentItem extends ItemPresentation { slot: string }
export interface InventorySnapshot { columns: number; rows: number; pages: number; items: InventoryItem[] }
export interface StorageSnapshot { columns:typeof STORAGE_COLUMNS; rows:typeof STORAGE_ROWS; pages:typeof STORAGE_PAGES; items:InventoryItem[] }
export interface EquipmentSnapshot { items?: EquipmentItem[]; stats?: { attack?: number } }
export interface WalletSnapshot { balance?: number; ready?: boolean }
export interface HudSnapshot { inventory_open?: boolean; equipment_open?: boolean; storage_open?: boolean; ui_scale?: number; viewport?: Viewport }
export type RawObject = Record<string, unknown>;
export type DomainName = 'storage' | 'inventory' | 'equipment' | 'wallet' | 'player' | 'hud';
export type RawDomainState = Partial<Record<DomainName, RawObject>>;
export interface DomainSnapshot {
  storage?: StorageSnapshot; inventory?: InventorySnapshot; equipment?: EquipmentSnapshot; wallet?: WalletSnapshot;
  player?: RawObject; hud?: HudSnapshot;
}
export interface Envelope { v: 1; type: string; id?: string; payload: RawObject }
export type StateType = 'ui.snapshot' | `${DomainName}.updated`;
// State payloads remain raw until their domain/view validators have checked them.
export interface StateMessage extends Envelope { type: StateType }
export interface ShortcutMessage { v: 1; type: 'ui.shortcut'; payload: {key: 'Escape'} }
export interface CommandResultMessage { v: 1; type: 'command.result'; id: string; payload: CommandResult }
export interface ItemCommand { id: string; revision: number }
export interface MoveItemCommand extends ItemCommand { x: number; y: number; page: number }
export interface StorageTransferCommand extends ItemCommand { from: 'inventory' | 'storage'; to: 'inventory' | 'storage'; x:number; y:number; page:number; quick:boolean }
export interface CommandPayloads {
  'storage.transfer': StorageTransferCommand;
  'storage.close': Record<string, never>;
  'inventory.move_item': MoveItemCommand;
  'equipment.equip': ItemCommand;
  'equipment.unequip': ItemCommand;
  'inventory.close': Record<string, never>;
  'equipment.close': Record<string, never>;
}
export type CommandMessage = {[K in keyof CommandPayloads]: {v: 1; type: K; id: string; payload: CommandPayloads[K]}}[keyof CommandPayloads];
export interface CommandResult { ok: boolean; error?: string }
export interface InteractiveRegion { id: string; x: number; y: number; w: number; h: number }
export interface InteractiveRegions { width: number; height: number; regions: InteractiveRegion[] }
export interface EventPayloads { 'ui.ready': Record<string, never>; 'ui.interactive_regions': InteractiveRegions }
export type EventMessage = {[K in keyof EventPayloads]: {v: 1; type: K; payload: EventPayloads[K]}}[keyof EventPayloads];
declare global {
  interface Window {
    sendIpcMessage(message: string): void;
    ipcMessage: { addListener(callback: (message: unknown) => void): void };
  }
}
