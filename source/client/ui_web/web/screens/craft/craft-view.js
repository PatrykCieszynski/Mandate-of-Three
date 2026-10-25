import { isItem } from '../../protocol.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
export function isCraft(v) {
    if (!v || typeof v !== 'object')
        return false;
    const s = v;
    const item = isItem;
    return (typeof s.active === 'boolean' &&
        typeof s.pending === 'boolean' &&
        typeof s.busy === 'boolean' &&
        typeof s.effect === 'string' &&
        s.effect.length <= 512 &&
        Array.isArray(s.targets) &&
        s.targets.length <= 180 &&
        s.targets.every(item) &&
        !!s.currency &&
        typeof s.currency === 'object' &&
        (Object.keys(s.currency).length === 0 || item(s.currency)));
}
export const CRAFT_CURRENCIES = [
    'change_spark',
    'renewal_dust',
    'completion_shard',
];
// Explicit currency-use mode, separate from ordinary item carrying/placement.
export function mountCraft(root, options) {
    const doc = root.ownerDocument;
    const surface = doc.createElement('div');
    surface.className = 'craft-input-surface';
    surface.id = 'craft-targeting';
    surface.hidden = true;
    surface.setAttribute('aria-hidden', 'true');
    doc.body.append(surface);
    const cursor = doc.createElement('div');
    cursor.className = 'craft-use-cursor';
    surface.append(cursor);
    const icon = doc.createElement('span'), hint = doc.createElement('span');
    icon.className = 'craft-cursor-icon';
    cursor.append(icon, hint);
    const recovery = doc.createElement('div');
    recovery.className = 'craft-recovery';
    recovery.hidden = true;
    const message = doc.createElement('span'), retry = doc.createElement('button');
    retry.textContent = 'Odzyskaj wynik';
    recovery.append(message, retry);
    (root.querySelector('.window-content') ?? root).append(recovery);
    let state = {
        active: false,
        pending: false,
        busy: false,
        currency: {},
        effect: '',
        targets: [],
    }, armed = false, inFlight = false, disposed = false, notice = '';
    function reason(item) {
        if (!item)
            return 'Wybierz przedmiot w torbie';
        const target = state.targets.find((i) => i.id === item.id);
        if (!target)
            return 'Nie można użyć tej waluty na tym przedmiocie';
        const rarity = target.tooltip?.rarity;
        const currency = state.currency
            .definition_id;
        if (currency === 'change_spark')
            return rarity === 'normal' ? '' : 'Wymaga przedmiotu Normal';
        if (rarity !== 'magic')
            return 'Wymaga przedmiotu Magic';
        if (currency === 'completion_shard' &&
            target.tooltip?.affixes?.length !== 1)
            return 'Wymaga dokładnie jednego affixu';
        return '';
    }
    function refreshTargets() {
        for (const node of root.querySelectorAll('.inventory-item')) {
            const target = state.targets.find((i) => i.id === node.dataset.id);
            if (armed) {
                node.dataset.craftTarget = reason(target) ? 'invalid' : 'valid';
                node.title = reason(target);
            }
            else {
                delete node.dataset.craftTarget;
                node.removeAttribute('title');
            }
        }
    }
    function render() {
        surface.hidden = !armed;
        icon.replaceChildren();
        const currency = state.currency;
        if (currency.id)
            paintItemIcon(icon, currency, {
                resolveItemIcon: options.resolveItemIcon,
            });
        hint.textContent =
            inFlight || state.busy
                ? 'Oczekiwanie…'
                : state.pending
                    ? 'Najpierw odzyskaj wynik'
                    : notice || `${currency.name ?? ''} · kliknij cel · Shift: powtarzaj`;
        recovery.hidden = !state.pending || state.busy || inFlight;
        message.textContent = 'Wynik przemiany niepotwierdzony. ';
        retry.disabled = inFlight || state.busy;
        refreshTargets();
        options.regions();
    }
    function cancel() {
        if (!armed)
            return false;
        armed = false;
        notice = '';
        options.close();
        render();
        return true;
    }
    async function use(item, shift) {
        if (!armed || inFlight || state.busy || state.pending)
            return;
        const why = reason(item);
        if (why) {
            notice = why;
            render();
            return;
        }
        const target = state.targets.find((i) => i.id === item.id);
        inFlight = true;
        notice = '';
        render();
        try {
            const result = await options.execute({
                id: target.id,
                revision: target.revision,
            });
            if (disposed)
                return;
            if (result.ok) {
                if (!shift || !state.currency.id)
                    cancel();
            }
            else
                notice = `Nie ukończono: ${result.error ?? 'unknown'}`;
        }
        catch {
            notice = 'Brak potwierdzenia — odzyskaj wynik';
        }
        finally {
            inFlight = false;
            if (!disposed)
                render();
        }
    }
    function pointer(event) {
        if (!armed)
            return;
        if (event.button === 2) {
            event.preventDefault();
            event.stopImmediatePropagation();
            cancel();
            return;
        }
        if (event.button !== 0)
            return;
        if (event.target instanceof doc.defaultView.Element &&
            root.contains(event.target) &&
            event.target.closest('button,[role=tab]'))
            return;
        if (event.target instanceof doc.defaultView.Node &&
            recovery.contains(event.target))
            return;
        // A normal drag never reaches crafting. Use mode consumes a deliberate click
        // before any Inventory activation or placement can run.
        event.preventDefault();
        event.stopImmediatePropagation();
        options.cancelCarry();
        const node = event.target instanceof doc.defaultView.Element
            ? event.target.closest('.inventory-item')
            : null;
        if (node && root.contains(node)) {
            const item = state.targets.find((i) => i.id === node.dataset.id);
            if (item)
                void use(item, event.shiftKey);
            else {
                notice = 'Nieprawidłowy cel';
                render();
            }
        }
    }
    function move(event) {
        cursor.style.left = `${Math.max(0, Math.min(event.clientX + 14, (doc.defaultView?.innerWidth ?? 0) - 260))}px`;
        cursor.style.top = `${Math.max(0, Math.min(event.clientY + 14, (doc.defaultView?.innerHeight ?? 0) - 72))}px`;
    }
    function key(event) {
        if (event.key === 'Escape' && cancel()) {
            event.preventDefault();
            event.stopImmediatePropagation();
        }
    }
    function blur() {
        cancel();
    }
    async function recover() {
        if (inFlight || state.busy)
            return;
        inFlight = true;
        render();
        try {
            const result = await options.retry();
            if (result.ok || !state.pending) {
                if (!cancel())
                    options.close();
            }
        }
        catch {
            notice = 'Nie udało się odzyskać wyniku';
        }
        finally {
            inFlight = false;
            if (!disposed)
                render();
        }
    }
    retry.addEventListener('click', () => void recover());
    doc.addEventListener('pointerdown', pointer, true);
    doc.addEventListener('pointermove', move, true);
    doc.addEventListener('keydown', key, true);
    doc.defaultView?.addEventListener('blur', blur);
    return {
        regions: [surface],
        engaged: () => armed,
        cancel,
        refreshTargets,
        reason,
        use,
        setState(next) {
            const opening = next.active && !state.active;
            state = next;
            if (opening && !next.pending) {
                options.cancelCarry();
                armed = true;
            }
            if (!next.active)
                armed = false;
            if (armed && !next.currency.id)
                cancel();
            render();
        },
        dispose() {
            disposed = true;
            armed = false;
            doc.removeEventListener('pointerdown', pointer, true);
            doc.removeEventListener('pointermove', move, true);
            doc.removeEventListener('keydown', key, true);
            doc.defaultView?.removeEventListener('blur', blur);
            surface.remove();
            recovery.remove();
            refreshTargets();
        },
    };
}
