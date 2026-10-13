import { isObject } from '../../protocol.js';
const int = (v, min = 0, max = 9000000000000000) => typeof v === 'number' && Number.isSafeInteger(v) && v >= min && v <= max;
const price = (v) => int(v.priceNum, 1, 1000000000) && int(v.priceDen, 1, 1000000000);
export function isExchangeSnapshot(v) {
    if (!isObject(v) || typeof v.active !== 'boolean')
        return false;
    if (!v.active)
        return Object.keys(v).length === 1;
    return (int(v.yang) &&
        int(v.reservedYang) &&
        Number(v.reservedYang) <= Number(v.yang) &&
        typeof v.busy === 'boolean' &&
        typeof v.retryAvailable === 'boolean' &&
        Array.isArray(v.assets) &&
        v.assets.length <= 32 &&
        v.assets.every((a) => isObject(a) &&
            typeof a.asset_id === 'string' &&
            typeof a.name === 'string' &&
            int(a.stack_limit, 1, 10000) &&
            int(a.free) &&
            int(a.reserved)) &&
        Array.isArray(v.orders) &&
        v.orders.length <= 50 &&
        v.orders.every((o) => isObject(o) &&
            typeof o.id === 'string' &&
            /^[a-f0-9]{32}$/.test(o.id) &&
            typeof o.asset === 'string' &&
            (o.side === 'buy' || o.side === 'sell') &&
            int(o.quantity, 1) &&
            int(o.remaining) &&
            Number(o.remaining) <= Number(o.quantity) &&
            int(o.reserved) &&
            int(o.received) &&
            price(o) &&
            int(o.revision) &&
            (o.status === 'active' ||
                o.status === 'filled' ||
                o.status === 'cancelled')) &&
        Array.isArray(v.depth) &&
        v.depth.length <= 20 &&
        v.depth.every((d) => isObject(d) &&
            (d.side === 'buy' || d.side === 'sell') &&
            typeof d.asset === 'string' &&
            int(d.remaining, 1) &&
            price(d)) &&
        Array.isArray(v.fills) &&
        v.fills.length <= 20 &&
        v.fills.every((f) => isObject(f) &&
            int(f.id, 1) &&
            typeof f.asset === 'string' &&
            int(f.quantity, 1) &&
            int(f.yang, 1)));
}
