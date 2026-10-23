export const hotbarKeys = Array.from({ length: 16 }, (_, i) => i < 8 ? String(i + 1) : `F${i - 7}`);
export function isHotbar(v) {
    const obj = (x) => !!x && typeof x === 'object' && !Array.isArray(x);
    const nonnegative = (x) => typeof x === 'number' && Number.isFinite(x) && x >= 0;
    if (!obj(v) ||
        !Array.isArray(v.slots) ||
        v.slots.length !== 16 ||
        !v.slots.every((s) => obj(s) &&
            (Object.keys(s).length === 0 ||
                (typeof s.id === 'string' &&
                    s.id.length > 0 &&
                    s.id.length <= 80 &&
                    typeof s.name === 'string' &&
                    s.name.length <= 160 &&
                    typeof s.icon_id === 'string' &&
                    s.icon_id.length <= 128 &&
                    Number.isSafeInteger(s.quantity) &&
                    nonnegative(s.quantity) &&
                    typeof s.available === 'boolean'))))
        return false;
    const vitals = v.vitals;
    return (typeof v.busy === 'boolean' &&
        typeof v.ready === 'boolean' &&
        typeof v.error === 'string' &&
        v.error.length <= 160 &&
        obj(vitals) &&
        typeof vitals.ready === 'boolean' &&
        ['hp', 'max_hp', 'mp', 'max_mp'].every((k) => nonnegative(vitals[k])) &&
        typeof vitals.level === 'string' &&
        /^[1-9][0-9]{0,18}$/.test(vitals.level));
}
