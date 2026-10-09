import type {Envelope, RawObject, CommandResult, DomainName, DomainSnapshot, RawDomainState,
  StateMessage, InventorySnapshot, InventoryItem, ItemPresentation, EquipmentItem, EquipmentSnapshot, WalletSnapshot, HudSnapshot, Viewport} from './contracts.js';
export const VERSION = 1;
export const MAX_BYTES = 16384;
const bytes = (value: string) => new TextEncoder().encode(value).length;
export function isObject(value: unknown): value is RawObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
export function encode(type: string, payload: object = {}, id?: string): string {
  const message: {v: 1; type: string; payload: object; id?: string} = {v: VERSION, type, payload};
  if (id !== undefined) message.id = id;
  const json = JSON.stringify(message);
  decode(json);
  return json;
}
function isEnvelope(value: unknown): value is Envelope {
  return isObject(value) && !Object.keys(value).some(key => !['v','type','id','payload'].includes(key)) &&
    value.v === VERSION && typeof value.type === 'string' && isObject(value.payload) &&
    (!('id' in value) || (typeof value.id === 'string' && value.id.length > 0 && value.id.length <= 80));
}
export function decodeAndValidate(parsed: unknown): Envelope {
  if (!isEnvelope(parsed)) throw Error('envelope');
  return parsed;
}
export function decode(json: unknown): Envelope {
  if (typeof json !== 'string' || bytes(json) > MAX_BYTES) throw Error('size');
  const parsed: unknown = JSON.parse(json);
  return decodeAndValidate(parsed);
}
export function isCommandResult(result: unknown): result is CommandResult {
  return isObject(result) && typeof result.ok === 'boolean' &&
    !Object.keys(result).some(key => !['ok','error'].includes(key)) &&
    (!('error' in result) || typeof result.error === 'string');
}
export function isStateMessage(message: Envelope): message is StateMessage {
  return !message.id && ['ui.snapshot','inventory.updated','equipment.updated','wallet.updated','player.updated','hud.updated'].includes(message.type);
}
export function isDomainName(value: string): value is DomainName {
  return ['inventory','equipment','wallet','player','hud'].includes(value);
}
export function isRawDomainState(value: unknown): value is RawDomainState {
  return isObject(value) && Object.entries(value).every(([key, domain]) => isDomainName(key) && isObject(domain));
}
function isItem(value: unknown): value is ItemPresentation {
  return isObject(value) && typeof value.id === 'string' && typeof value.revision === 'number' &&
    typeof value.name === 'string' && typeof value.icon_id === 'string' && typeof value.height === 'number' &&
    typeof value.quantity === 'number' && (!('description' in value) || typeof value.description === 'string');
}
function isInventoryItem(value: unknown): value is InventoryItem {
  return isItem(value) && isObject(value) && typeof value.x === 'number' && typeof value.y === 'number' && typeof value.page === 'number';
}
function isEquipmentItem(value: unknown): value is EquipmentItem {
  return isItem(value) && isObject(value) && typeof value.slot === 'string';
}
function isInventory(value: unknown): value is InventorySnapshot {
  return isObject(value) && typeof value.columns === 'number' && typeof value.rows === 'number' &&
    typeof value.pages === 'number' && Array.isArray(value.items) && value.items.every(isInventoryItem);
}
function isEquipment(value: unknown): value is EquipmentSnapshot {
  return isObject(value) && (!('items' in value) || (Array.isArray(value.items) && value.items.every(isEquipmentItem))) &&
    (!('stats' in value) || (isObject(value.stats) && (!('attack' in value.stats) || typeof value.stats.attack === 'number')));
}
function isWallet(value: unknown): value is WalletSnapshot {
  return isObject(value) && (!('balance' in value) || typeof value.balance === 'number') &&
    (!('ready' in value) || typeof value.ready === 'boolean');
}
function isViewport(value: unknown): value is Viewport {
  return isObject(value) && typeof value.width === 'number' && typeof value.height === 'number';
}
function isHud(value: unknown): value is HudSnapshot {
  return isObject(value) && (!('inventory_open' in value) || typeof value.inventory_open === 'boolean') &&
    (!('equipment_open' in value) || typeof value.equipment_open === 'boolean') &&
    (!('ui_scale' in value) || typeof value.ui_scale === 'number') &&
    (!('viewport' in value) || isViewport(value.viewport));
}
function isDomainSnapshot(value: unknown): value is DomainSnapshot {
  return isRawDomainState(value) &&
    (!('inventory' in value) || isInventory(value.inventory)) &&
    (!('equipment' in value) || isEquipment(value.equipment)) &&
    (!('wallet' in value) || isWallet(value.wallet)) &&
    (!('hud' in value) || isHud(value.hud));
}
// The raw store retains its shallow protocol contract. Views receive only checked fields.
export function readDomainSnapshot(value: unknown): DomainSnapshot | null {
  return isDomainSnapshot(value) ? value : null;
}
export function errorMessage(error: unknown): unknown {
  return isObject(error) ? error.message : undefined;
}
