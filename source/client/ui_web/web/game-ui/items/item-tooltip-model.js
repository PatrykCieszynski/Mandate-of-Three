export function itemRarity(affixCount) {
    if (affixCount === 0)
        return 'normal';
    if (affixCount <= 2)
        return 'magic';
    if (affixCount <= 4)
        return 'rare';
    return 'legendary';
}
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = (value) => typeof value === 'string' && value.length > 0 && value.length <= 256;
const lines = (value, max) => Array.isArray(value) && value.length <= max && value.every(text);
// IPC metadata is still untrusted. Bound DOM work and enforce 3 prefixes/3 suffixes.
export function isItemTooltipDetails(value) {
    if (!object(value) ||
        Object.keys(value).some((key) => !['category', 'properties', 'requirements', 'affixes'].includes(key)))
        return false;
    if ('category' in value && !text(value.category))
        return false;
    if ('properties' in value && !lines(value.properties, 8))
        return false;
    if ('requirements' in value && !lines(value.requirements, 4))
        return false;
    if (!('affixes' in value))
        return true;
    if (!Array.isArray(value.affixes) || value.affixes.length > 6)
        return false;
    let prefixes = 0, suffixes = 0;
    for (const affix of value.affixes) {
        if (!object(affix) ||
            Object.keys(affix).some((key) => !['kind', 'lines'].includes(key)) ||
            !lines(affix.lines, 3) ||
            affix.lines.length === 0)
            return false;
        if (affix.kind === 'prefix')
            prefixes++;
        else if (affix.kind === 'suffix')
            suffixes++;
        else if ('kind' in affix)
            return false;
    }
    return prefixes <= 3 && suffixes <= 3;
}
