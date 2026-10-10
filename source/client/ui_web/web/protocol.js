import { isItemTooltipDetails } from './game-ui/items/item-tooltip-model.js';
import { STORAGE_COLUMNS, STORAGE_ROWS, STORAGE_PAGES, STORAGE_CAPACITY } from './screens/storage/storage-model.js';
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
    return !message.id && ['ui.snapshot', 'shop.updated', 'npc.updated', 'storage.updated', 'inventory.updated', 'equipment.updated', 'wallet.updated', 'player.updated', 'hud.updated'].includes(message.type);
}
export function isDomainName(value) {
    return ['shop', 'npc', 'storage', 'inventory', 'equipment', 'wallet', 'player', 'hud'].includes(value);
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
        integerRange(value.quantity, 1) && (!('description' in value) || typeof value.description === 'string') &&
        (!('tooltip' in value) || isItemTooltipDetails(value.tooltip));
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
    if (!isObject(value) || value.columns !== STORAGE_COLUMNS || value.rows !== STORAGE_ROWS || value.pages !== STORAGE_PAGES || !Array.isArray(value.items) || value.items.length > STORAGE_CAPACITY)
        return false;
    return value.items.every(item => isItem(item) && isObject(item) && integerRange(item.x, 0, STORAGE_COLUMNS - 1) && integerRange(item.y, 0, STORAGE_ROWS - 1) && item.y + item.height <= STORAGE_ROWS && integerRange(item.page, 0, STORAGE_PAGES - 1));
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
    return isObject(value) && (value.storage_open !== true || value.inventory_open === true) && (!('storage_open' in value) || typeof value.storage_open === 'boolean') && (!('inventory_open' in value) || typeof value.inventory_open === 'boolean') &&
        (!('equipment_open' in value) || typeof value.equipment_open === 'boolean') &&
        (!('ui_scale' in value) || (finiteRange(value.ui_scale, 0.8, 1.5) && UI_SCALES.includes(value.ui_scale))) &&
        (!('viewport' in value) || isViewport(value.viewport));
}
function isShop(value) {
    if (!isObject(value) || typeof value.active !== 'boolean')
        return false;
    if (!value.active)
        return Object.keys(value).length === 1;
    const id = (v) => typeof v === 'string' && /^[a-z][a-z0-9_]{0,63}$/.test(v);
    if (typeof value.npcInstanceId !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,79}$/.test(value.npcInstanceId) || !id(value.serviceId) || !id(value.shopId) || typeof value.name !== 'string' || !value.name || value.name.length > 128 || value.currency !== 'yang' || !Array.isArray(value.offers) || value.offers.length > 180)
        return false;
    const seen = new Set();
    for (const offer of value.offers) {
        if (!isObject(offer) || !id(offer.offerId) || typeof offer.offerId !== 'string' || seen.has(offer.offerId) || !id(offer.itemDefinitionId) || typeof offer.name !== 'string' || !offer.name || offer.name.length > 128 || typeof offer.iconId !== 'string' || offer.iconId.length > 64 || !integerRange(offer.height, 1, 3) || !integerRange(offer.quantity, 1) || !integerRange(offer.price, 1, MAX_YANG) || ('description' in offer && typeof offer.description !== 'string') || ('tooltip' in offer && !isItemTooltipDetails(offer.tooltip)) || 'uid' in offer || 'revision' in offer)
            return false;
        seen.add(offer.offerId);
    }
    return true;
}
function isNpc(value) {
    if (!isObject(value) || typeof value.active !== 'boolean')
        return false;
    if (!value.active)
        return Object.keys(value).length === 1;
    const contentId = (id) => typeof id === 'string' && /^[a-z][a-z0-9_]{0,63}$/.test(id);
    if (typeof value.npcInstanceId !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,79}$/.test(value.npcInstanceId) ||
        !contentId(value.npcDefinitionId) || typeof value.name !== 'string' || !value.name || value.name.length > 128 ||
        typeof value.selectedServiceId !== 'string' || !Array.isArray(value.services) || value.services.length > 16)
        return false;
    const seen = new Set();
    for (const service of value.services) {
        if (!isObject(service) || !contentId(service.id) || typeof service.id !== 'string' || seen.has(service.id) ||
            !integerRange(service.kind, 0, 3) || typeof service.label !== 'string' || !service.label || service.label.length > 128 ||
            typeof service.enabled !== 'boolean' || ('iconId' in service && (typeof service.iconId !== 'string' || service.iconId.length > 64)))
            return false;
        seen.add(service.id);
    }
    return value.selectedServiceId === '' || value.services.some(service => isObject(service) && service.id === value.selectedServiceId && service.enabled === true);
}
// A single domain update must pass the same checks as a full view snapshot.
export function isValidDomainValue(domain, value) {
    if (!isObject(value))
        return false;
    switch (domain) {
        case 'shop': return isShop(value);
        case 'npc': return isNpc(value);
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
