import { placement, firstFittingPlacement } from '../inventory/placement.js';
// Preview domain operation. The native server will remain authoritative.
export function transfer(source, destination, id, revision, target) {
    const item = source.items.find((item) => item.id === id && item.revision === revision);
    if (!item ||
        !Number.isSafeInteger(item.revision) ||
        item.revision < 0 ||
        item.revision === Number.MAX_SAFE_INTEGER)
        return null;
    const same = source === destination;
    if (!same && destination.items.some((other) => other.id === id))
        return null;
    const model = { ...destination, items: [...destination.items] };
    const location = target ?? firstFittingPlacement(model, item);
    if (!location ||
        !placement(model, item, location.x, location.y, location.page).valid)
        return null;
    const moved = {
        ...item,
        x: location.x,
        y: location.y,
        page: location.page,
        revision: item.revision + 1,
    };
    const remaining = source.items.filter((other) => other.id !== id);
    return {
        sourceItems: remaining,
        destinationItems: [...(same ? remaining : destination.items), moved],
    };
}
