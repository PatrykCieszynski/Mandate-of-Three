export const VERSION = 1;
export const MAX_BYTES = 16384;
// Bounded snapshots for the real 180 + 270 cell screens. Commands stay 16 KiB.
export const MAX_STATE_BYTES = 131072;
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
    if (typeof json !== 'string' || bytes(json) > MAX_STATE_BYTES)
        throw Error('size');
    const parsed = JSON.parse(json);
    const message = decodeAndValidate(parsed);
    if (bytes(json) > MAX_BYTES && !isStateMessage(message))
        throw Error('size');
    return message;
}
export function isCommandResult(result) {
    return isObject(result) && typeof result.ok === 'boolean' &&
        !Object.keys(result).some(key => !['ok', 'error'].includes(key)) &&
        (!('error' in result) || typeof result.error === 'string');
}
export function isStateMessage(message) {
    return !message.id && ['ui.snapshot', 'storage.updated', 'inventory.updated', 'equipment.updated', 'wallet.updated', 'player.updated', 'hud.updated'].includes(message.type);
}
export function isDomainName(value) {
    return ['storage', 'inventory', 'equipment', 'wallet', 'player', 'hud'].includes(value);
}
export function isRawDomainState(value) {
    return isObject(value) && Object.entries(value).every(([key, domain]) => isDomainName(key) && isObject(domain));
}
// Match the current native InventoryGrid and InventoryWebController contract.
// These bound presentation work, not item ownership/eligibility or server actions.
const MAX_COLUMNS = 5, MAX_ROWS = 9, MAX_PAGES = 4, MAX_ITEM_HEIGHT = 3;
const UI_SCALES = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.5];
// Presentation sanity ceiling; accommodates 8K/ultrawide without unbounded geometry.
const MAX_VIEWPORT = 16384;
const MAX_YANG = 9000000000000000; // WalletStoreSqlite.MAX_YANG; exact in JS.
function finiteRange(value, min, max) {
    return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
}
function integerRange(value, min, max = Number.MAX_SAFE_INTEGER) {
    return finiteRange(value, min, max) && Number.isSafeInteger(value);
}
function isItem(value) {
    return isObject(value) && typeof value.id === 'string' && integerRange(value.revision, 0) &&
        typeof value.name === 'string' && typeof value.icon_id === 'string' && integerRange(value.height, 1, MAX_ITEM_HEIGHT) &&
        integerRange(value.quantity, 1) && (!('description' in value) || typeof value.description === 'string');
}
function isInventoryItem(value) {
    return isItem(value) && isObject(value) && integerRange(value.x, 0, MAX_COLUMNS - 1) &&
        integerRange(value.y, 0, MAX_ROWS - 1) && integerRange(value.page, 0, MAX_PAGES - 1);
}
function isEquipmentItem(value) {
    return isItem(value) && isObject(value) && typeof value.slot === 'string';
}
function isInventory(value) {
    if (!isObject(value) || !integerRange(value.columns, 1, MAX_COLUMNS) || !integerRange(value.rows, 1, MAX_ROWS) ||
        !integerRange(value.pages, 1, MAX_PAGES) || !Array.isArray(value.items) ||
        value.items.length > value.columns * value.rows * value.pages || !value.items.every(isInventoryItem))
        return false;
    // Coordinates/footprints must fit the actual snapshot, including smaller grids.
    const { columns, rows, pages } = value;
    return value.items.every(item => item.x < columns && item.y + item.height <= rows && item.page < pages);
}
function isStorage(value) {
    if (!isObject(value) || value.columns !== 15 || value.rows !== 9 || value.pages !== 2 || !Array.isArray(value.items) || value.items.length > 270)
        return false;
    return value.items.every(item => isItem(item) && isObject(item) && integerRange(item.x, 0, 14) && integerRange(item.y, 0, 8) && item.y + item.height <= 9 && integerRange(item.page, 0, 1));
}
function isEquipment(value) {
    return isObject(value) && (!('items' in value) || (Array.isArray(value.items) && value.items.every(isEquipmentItem))) &&
        (!('stats' in value) || (isObject(value.stats) && (!('attack' in value.stats) || finiteRange(value.stats.attack, 0, Number.MAX_SAFE_INTEGER))));
}
function isWallet(value) {
    return isObject(value) && (!('balance' in value) || integerRange(value.balance, 0, MAX_YANG)) &&
        (!('ready' in value) || typeof value.ready === 'boolean');
}
function isViewport(value) {
    // A hidden/minimized host can legitimately publish a zero-sized viewport.
    return isObject(value) && integerRange(value.width, 0, MAX_VIEWPORT) && integerRange(value.height, 0, MAX_VIEWPORT);
}
function isHud(value) {
    return isObject(value) && (!('storage_open' in value) || typeof value.storage_open === 'boolean') && (!('inventory_open' in value) || typeof value.inventory_open === 'boolean') &&
        (!('equipment_open' in value) || typeof value.equipment_open === 'boolean') &&
        (!('ui_scale' in value) || (finiteRange(value.ui_scale, 0.8, 1.5) && UI_SCALES.includes(value.ui_scale))) &&
        (!('viewport' in value) || isViewport(value.viewport));
}
// A single domain update must pass the same checks as a full view snapshot.
export function isValidDomainValue(domain, value) {
    if (!isObject(value))
        return false;
    switch (domain) {
        case 'storage': return isStorage(value);
        case 'inventory': return isInventory(value);
        case 'equipment': return isEquipment(value);
        case 'wallet': return isWallet(value);
        case 'hud': return isHud(value);
        case 'player': return true; // Opaque domain; no player fields are consumed by these screens.
    }
}
export function isValidDomainState(value) {
    return isRawDomainState(value) && Object.entries(value).every(([domain, payload]) => isDomainName(domain) && isValidDomainValue(domain, payload));
}
function isDomainSnapshot(value) {
    return isValidDomainState(value);
}
export function readDomainSnapshot(value) {
    return isDomainSnapshot(value) ? value : null;
}
export function errorMessage(error) {
    return isObject(error) ? error.message : undefined;
}
