export const VERSION = 1;
export const MAX_BYTES = 16384;
const bytes = (value) => new TextEncoder().encode(value).length;
export function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}
export function encode(type, payload = {}, id) {
    const message = { v: VERSION, type, payload };
    if (id !== undefined)
        message.id = id;
    const json = JSON.stringify(message);
    decode(json);
    return json;
}
function isEnvelope(value) {
    return isObject(value) && !Object.keys(value).some(key => !['v', 'type', 'id', 'payload'].includes(key)) &&
        value.v === VERSION && typeof value.type === 'string' && isObject(value.payload) &&
        (!('id' in value) || (typeof value.id === 'string' && value.id.length > 0 && value.id.length <= 80));
}
export function decodeAndValidate(parsed) {
    if (!isEnvelope(parsed))
        throw Error('envelope');
    return parsed;
}
export function decode(json) {
    if (typeof json !== 'string' || bytes(json) > MAX_BYTES)
        throw Error('size');
    const parsed = JSON.parse(json);
    return decodeAndValidate(parsed);
}
export function isCommandResult(result) {
    return isObject(result) && typeof result.ok === 'boolean' &&
        !Object.keys(result).some(key => !['ok', 'error'].includes(key)) &&
        (!('error' in result) || typeof result.error === 'string');
}
export function isStateMessage(message) {
    return !message.id && ['ui.snapshot', 'inventory.updated', 'equipment.updated', 'wallet.updated', 'player.updated', 'hud.updated'].includes(message.type);
}
export function isDomainName(value) {
    return ['inventory', 'equipment', 'wallet', 'player', 'hud'].includes(value);
}
export function isRawDomainState(value) {
    return isObject(value) && Object.entries(value).every(([key, domain]) => isDomainName(key) && isObject(domain));
}
function isItem(value) {
    return isObject(value) && typeof value.id === 'string' && typeof value.revision === 'number' &&
        typeof value.name === 'string' && typeof value.icon_id === 'string' && typeof value.height === 'number' &&
        typeof value.quantity === 'number' && (!('description' in value) || typeof value.description === 'string');
}
function isInventoryItem(value) {
    return isItem(value) && isObject(value) && typeof value.x === 'number' && typeof value.y === 'number' && typeof value.page === 'number';
}
function isEquipmentItem(value) {
    return isItem(value) && isObject(value) && typeof value.slot === 'string';
}
function isInventory(value) {
    return isObject(value) && typeof value.columns === 'number' && typeof value.rows === 'number' &&
        typeof value.pages === 'number' && Array.isArray(value.items) && value.items.every(isInventoryItem);
}
function isEquipment(value) {
    return isObject(value) && (!('items' in value) || (Array.isArray(value.items) && value.items.every(isEquipmentItem))) &&
        (!('stats' in value) || (isObject(value.stats) && (!('attack' in value.stats) || typeof value.stats.attack === 'number')));
}
function isWallet(value) {
    return isObject(value) && (!('balance' in value) || typeof value.balance === 'number') &&
        (!('ready' in value) || typeof value.ready === 'boolean');
}
function isViewport(value) {
    return isObject(value) && typeof value.width === 'number' && typeof value.height === 'number';
}
function isHud(value) {
    return isObject(value) && (!('inventory_open' in value) || typeof value.inventory_open === 'boolean') &&
        (!('equipment_open' in value) || typeof value.equipment_open === 'boolean') &&
        (!('ui_scale' in value) || typeof value.ui_scale === 'number') &&
        (!('viewport' in value) || isViewport(value.viewport));
}
function isDomainSnapshot(value) {
    return isRawDomainState(value) &&
        (!('inventory' in value) || isInventory(value.inventory)) &&
        (!('equipment' in value) || isEquipment(value.equipment)) &&
        (!('wallet' in value) || isWallet(value.wallet)) &&
        (!('hud' in value) || isHud(value.hud));
}
// The raw store retains its shallow protocol contract. Views receive only checked fields.
export function readDomainSnapshot(value) {
    return isDomainSnapshot(value) ? value : null;
}
export function errorMessage(error) {
    return isObject(error) ? error.message : undefined;
}
