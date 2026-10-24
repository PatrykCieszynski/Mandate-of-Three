import { UiWindow } from '../../core/window/ui-window.js';
import { OwnedItemDragSubject } from '../../game-ui/items/item-drag-policy.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { isItemTooltipDetails, } from '../../game-ui/items/item-tooltip-model.js';
const decimal = (v) => typeof v === 'string' && /^\d{1,18}$/.test(v);
export function isTrade(v) {
    if (!v || typeof v !== 'object')
        return false;
    const s = v;
    return (typeof s.id === 'string' &&
        s.id.length <= 96 &&
        typeof s.phase === 'string' &&
        s.phase.length <= 64 &&
        Number.isSafeInteger(s.version) &&
        s.version >= 0 &&
        Number.isSafeInteger(s.self) &&
        Array.isArray(s.candidates) &&
        s.candidates.length <= 64 &&
        s.candidates.every((c) => !!c &&
            typeof c === 'object' &&
            Number.isSafeInteger(c.id) &&
            c.id > 0 &&
            typeof c.name === 'string') &&
        (s.own_side === undefined || s.own_side === 0 || s.own_side === 1) &&
        (s.accepted === undefined ||
            (Array.isArray(s.accepted) &&
                s.accepted.length === 2 &&
                s.accepted.every((a) => typeof a === 'boolean'))) &&
        (s.offers === undefined ||
            (Array.isArray(s.offers) &&
                s.offers.length === 2 &&
                s.offers.every((o) => !!o &&
                    typeof o === 'object' &&
                    typeof o.name === 'string' &&
                    decimal(o.yang) &&
                    Array.isArray(o.items) &&
                    o.items.length <= 8 &&
                    o.items.every((i) => !!i &&
                        typeof i === 'object' &&
                        /^[0-9a-f]{32}$/.test(i.uid) &&
                        decimal(i.revision) &&
                        typeof i.name === 'string' &&
                        typeof i.icon === 'string' &&
                        (i.tooltip === undefined || isItemTooltipDetails(i.tooltip)) &&
                        decimal(i.amount))))) &&
        ['recover_id', 'client_error', 'error'].every((k) => s[k] === undefined ||
            typeof s[k] === 'string') &&
        ['opened', 'incoming', 'pending'].every((k) => s[k] === undefined ||
            typeof s[k] === 'boolean'));
}
export function mountTrade(root, options) {
    const shell = new UiWindow(root, {
        id: 'trade',
        title: 'Trade · T',
        className: 'trade-window',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'top-left',
            offset: { x: 280, y: 100 },
        },
        onClose: options.close,
        onRegionsChanged: options.regions,
    });
    const content = document.createElement('div');
    const tip = ItemTooltip(root, { geometry: () => options.manager });
    content.className = 'trade-content';
    shell.contentRoot.append(content);
    const ownGrid = document.createElement('div');
    ownGrid.className = 'trade-grid';
    let state, flight = false, error = '', yangDraft;
    const own = () => state?.offers?.[state.own_side ?? 0];
    const send = async (p) => {
        if (flight)
            return;
        flight = true;
        render();
        try {
            const r = await options.command(p);
            error = r.ok ? '' : String(r.error ?? 'Request failed');
        }
        catch {
            error =
                'Connection lost. Recover the trade result before starting another.';
        }
        finally {
            flight = false;
            render();
        }
    };
    const button = (text, p) => {
        const b = document.createElement('button');
        b.className = 'ui-button';
        b.textContent = text;
        b.disabled = flight;
        b.onclick = () => void send(p);
        return b;
    };
    const offer = (items, yang = own()?.yang ?? '0') => {
        if (state?.phase === 'offer')
            void send({
                action: 'offer',
                trade_id: state.id,
                version: state.version,
                items,
                yang,
            });
    };
    const offerItem = async (item) => {
        if (!state || state.phase !== 'offer' || flight)
            return false;
        const lines = own()?.items.map((i) => ({ uid: i.uid, revision: i.revision })) ?? [];
        if (lines.some((i) => i.uid === item.id))
            return true;
        if (lines.length >= 8)
            return false;
        offer([...lines, { uid: item.id, revision: String(item.revision) }]);
        return true;
    };
    const unregister = options.drag.registerTarget({
        element: ownGrid,
        preview: (p) => ({
            valid: state?.phase === 'offer' &&
                !flight &&
                p.subject instanceof OwnedItemDragSubject &&
                p.subject.container === 'inventory',
            data: null,
        }),
        drop: async (p) => {
            if (p.subject instanceof OwnedItemDragSubject &&
                p.subject.container === 'inventory')
                offerItem(p.subject.item);
        },
    });
    function render() {
        tip.hide();
        content.replaceChildren();
        if (!state)
            return;
        root.hidden = !state.opened;
        if (!state.opened) {
            shell.refresh();
            options.regions();
            return;
        }
        const status = document.createElement('p');
        status.textContent =
            error || state.client_error || state.error || state.phase;
        content.append(status);
        if (state.pending && state.recover_id)
            content.append(button('Recover result', {
                action: 'recover',
                trade_id: state.recover_id,
            }));
        if (state.phase === 'idle' ||
            (state.offers === undefined &&
                state.phase !== 'invited' &&
                state.phase !== 'unavailable')) {
            const select = document.createElement('select');
            select.setAttribute('aria-label', 'Nearby player');
            state.candidates.forEach((c) => {
                const o = document.createElement('option');
                o.value = String(c.id);
                o.textContent = c.name;
                select.append(o);
            });
            const invite = document.createElement('button');
            invite.className = 'ui-button';
            invite.textContent = 'Invite to trade';
            invite.disabled = flight || !!state.pending || !state.candidates.length;
            invite.onclick = () => void send({ action: 'invite', target: Number(select.value) });
            content.append(select, invite);
        }
        if (state.phase === 'invited') {
            const p = document.createElement('p');
            p.textContent =
                state.offers?.[1 - (state.own_side ?? 0)]?.name ?? 'Trade invitation';
            content.append(p);
            if (state.incoming)
                content.append(button('Accept invitation', { action: 'join', trade_id: state.id }));
        }
        if (state.offers) {
            state.offers.forEach((o, index) => {
                const heading = document.createElement('h3');
                heading.textContent = `${index === state.own_side ? 'Your offer' : o.name} ${state.accepted?.[index] ? '✓ Accepted' : ''}`;
                const grid = index === state.own_side ? ownGrid : document.createElement('div');
                grid.className = 'trade-grid';
                grid.replaceChildren();
                for (let n = 0; n < 8; n++) {
                    const cell = document.createElement('button');
                    cell.className = 'trade-slot';
                    cell.disabled =
                        flight || index !== state.own_side || state.phase !== 'offer';
                    const item = o.items[n];
                    if (item) {
                        cell.title = item.name;
                        cell.onpointermove = (e) => tip.show(e, item);
                        cell.onpointerleave = () => tip.hide();
                        paintItemIcon(cell, {
                            name: item.name,
                            icon_id: item.icon,
                            quantity: Number(item.amount),
                        }, { resolveItemIcon: options.resolveItemIcon });
                        const remove = () => offer(o.items
                            .filter((i) => i.uid !== item.uid)
                            .map((i) => ({ uid: i.uid, revision: i.revision })));
                        cell.onclick = remove;
                        cell.oncontextmenu = (e) => {
                            e.preventDefault();
                            remove();
                        };
                    }
                    grid.append(cell);
                }
                content.append(heading, grid);
                const money = document.createElement('p');
                money.textContent = `Yang: ${o.yang}`;
                content.append(money);
            });
        }
        if (state.phase === 'offer') {
            const yang = document.createElement('input');
            yang.inputMode = 'numeric';
            yang.value = yangDraft ?? own()?.yang ?? '0';
            yang.oninput = () => {
                yangDraft = yang.value;
            };
            yang.setAttribute('aria-label', 'Yang offered');
            const update = document.createElement('button');
            update.className = 'ui-button';
            update.textContent = 'Set Yang';
            update.disabled = flight;
            update.onclick = () => {
                if (/^\d{1,16}$/.test(yang.value))
                    offer(own()?.items.map((i) => ({ uid: i.uid, revision: i.revision })) ??
                        [], yang.value);
            };
            content.append(yang, update, button('Accept current offer', {
                action: 'confirm',
                trade_id: state.id,
                version: state.version,
            }));
            const hint = document.createElement('p');
            hint.textContent =
                'Drag or Ctrl-click items from Inventory. Whole stacks only. Any change clears both acceptances.';
            content.append(hint);
        }
        if (['invited', 'offer'].includes(state.phase))
            content.append(button('Cancel trade', { action: 'cancel', trade_id: state.id }));
        shell.refresh();
        options.regions();
    }
    return {
        regions: [shell.panel],
        offerItem,
        setState(s) {
            const opening = root.hidden && s.opened;
            if (s.id !== state?.id ||
                s.offers?.[s.own_side ?? 0]?.yang !== own()?.yang)
                yangDraft = undefined;
            state = s;
            render();
            if (opening)
                shell.handle.activate();
        },
        dispose() {
            unregister.dispose();
            tip.dispose();
            shell.dispose();
        },
    };
}
