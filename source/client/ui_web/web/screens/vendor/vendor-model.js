import { isItem, isObject } from '../../protocol.js';
export function isVendor(v) {
    if (!isObject(v) ||
        !['active', 'ready', 'busy', 'quoting', 'pending'].every((k) => typeof v[k] === 'boolean') ||
        !Array.isArray(v.items) ||
        v.items.length > 32 ||
        !isObject(v.quote) ||
        typeof v.error !== 'string' ||
        v.error.length > 96 ||
        typeof v.outcome !== 'string' ||
        v.outcome.length > 65536)
        return false;
    const ids = new Set();
    if (!v.items.every((i) => isItem(i) &&
        isObject(i) &&
        !ids.has(i.id) &&
        !!ids.add(i.id) &&
        typeof i.available === 'boolean' &&
        Number.isSafeInteger(i.maximum) &&
        Number(i.maximum) >= 1 &&
        Number(i.maximum) <= 200 &&
        i.quantity <= 200))
        return false;
    const q = v.quote;
    if (Object.keys(q).length === 0)
        return true;
    return (Object.keys(q).length === 3 &&
        typeof q.yang === 'string' &&
        /^(0|[1-9][0-9]{0,15})$/.test(q.yang) &&
        BigInt(q.yang) <= 9000000000000000n &&
        Number.isSafeInteger(q.expires_at) &&
        Array.isArray(q.rewards) &&
        q.rewards.length <= 32 &&
        q.rewards.every((r) => isObject(r) &&
            r.type === 'random_pool' &&
            typeof r.pool === 'string' &&
            r.pool.length <= 64 &&
            typeof r.icon_id === 'string' &&
            r.icon_id.length <= 64 &&
            Number.isSafeInteger(r.quantity) &&
            Number(r.quantity) > 0 &&
            Number(r.quantity) <= 1000));
}
