import { UiWindow } from '../../core/window/ui-window.js';
import { UiCurrency } from '../../core/primitives/ui-currency.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { itemWindowControls } from '../../game-ui/items/item-drag-policy.js';
import { NpcShopOfferDragSubject, shopOfferPayload, } from './shop-drag-policy.js';
export function mountShop(root, options) {
    let state = { active: false }, pending = false, disposed = false, generation = 0;
    const shell = new UiWindow(root, {
        id: 'shop',
        title: 'Shop',
        className: 'shop-window',
        manager: options.manager,
        placement: {
            kind: 'relative',
            target: 'inventory',
            side: 'left',
            align: 'start',
            gap: 12,
            fallback: {
                kind: 'viewport',
                anchor: 'top-left',
                offset: { x: 16, y: 180 },
            },
        },
        onClose: options.onClose,
        canDrag: () => !options.drag.active,
        onCancel: () => options.drag.cancel(),
        ...(options.onRegionsChanged
            ? { onRegionsChanged: options.onRegionsChanged }
            : {}),
    });
    const offers = document.createElement('div');
    offers.className = 'shop-offers';
    const hint = document.createElement('p');
    hint.className = 'shop-hint';
    hint.textContent = 'Right-click to buy · Drag to Inventory';
    const wallet = document.createElement('footer'), status = document.createElement('p');
    status.className = 'shop-status';
    status.setAttribute('role', 'status');
    shell.contentRoot.append(offers, hint, wallet, status);
    const currency = UiCurrency(wallet, {
        label: 'Yang',
        iconId: 'currencies.yang',
    }), tip = ItemTooltip(root, { geometry: () => options.manager });
    const sources = [], controls = itemWindowControls(options.drag, root);
    const errors = {
        funds: 'Not enough Yang.',
        inventory_full: 'Inventory is full.',
        occupied: 'That space is occupied.',
        unknown_offer: 'Offer is no longer available.',
        out_of_range: 'Move closer to the NPC.',
        no_interaction: 'Reopen the NPC interaction.',
        service_disabled: 'Shop is unavailable.',
        too_fast: 'Wait before buying again.',
        storage: 'Purchase failed. Try again.',
        request: 'Invalid placement.',
    };
    async function buyOffer(subject, position) {
        if (!state.active ||
            pending ||
            subject.npcInstanceId !== state.npcInstanceId ||
            subject.serviceId !== state.serviceId ||
            !state.offers.some((offer) => offer.offerId === subject.offer.offerId))
            return;
        pending = true;
        tip.hide();
        status.textContent = 'Buying…';
        const requestGeneration = generation;
        const command = {
            npc_instance_id: subject.npcInstanceId,
            service_id: subject.serviceId,
            offer_id: subject.offer.offerId,
            ...(position
                ? { x: position.x, y: position.y, page: position.page }
                : {}),
        };
        try {
            const result = await options.buy(command);
            if (!disposed && generation === requestGeneration)
                status.textContent = result.ok
                    ? 'Purchased.'
                    : (errors[result.error ?? ''] ??
                        `Purchase rejected: ${result.error ?? 'request'}`);
        }
        catch {
            if (!disposed && generation === requestGeneration)
                status.textContent = 'Purchase failed. Try again.';
        }
        finally {
            if (generation === requestGeneration)
                pending = false;
        }
    }
    function render() {
        sources.forEach((binding) => binding.dispose());
        sources.length = 0;
        offers.replaceChildren();
        root.hidden = !state.active;
        if (state.active) {
            shell.panel.querySelector('h1').textContent = state.name;
            for (const offer of state.offers) {
                const entry = document.createElement('button');
                entry.type = 'button';
                entry.className = 'npc-service shop-offer shop-item';
                entry.dataset.offerId = offer.offerId;
                entry.setAttribute('aria-label', offer.name);
                const name = document.createElement('span');
                name.className = 'shop-offer-name';
                name.textContent = offer.name;
                const quantity = document.createElement('span');
                quantity.className = 'shop-quantity';
                quantity.textContent = '×' + offer.quantity;
                entry.append(name, quantity);
                offers.append(entry);
                const subject = new NpcShopOfferDragSubject(state.npcInstanceId, state.serviceId, offer);
                sources.push(options.drag.registerSource({
                    element: entry,
                    payload: () => {
                        if (pending)
                            return null;
                        tip.hide();
                        return shopOfferPayload(subject, 40, options.resolveItemIcon);
                    },
                }));
                entry.addEventListener('pointerdown', (event) => {
                    if (event.button === 2 && !options.drag.active && !pending) {
                        event.preventDefault();
                        void buyOffer(subject);
                    }
                });
                entry.addEventListener('pointermove', (event) => {
                    if (!options.drag.active && !pending)
                        tip.show(event, {
                            ...offer,
                            kind: 'shop-offer',
                            currency: state.active ? state.currency : 'yang',
                        });
                });
                entry.addEventListener('pointerleave', () => tip.hide());
            }
        }
        shell.refresh();
        options.onRegionsChanged?.();
    }
    return {
        regions: [shell.panel],
        buyOffer,
        setState(snapshot) {
            tip.hide();
            const wasOpen = state.active;
            const changed = state.active !== snapshot.active ||
                (state.active &&
                    snapshot.active &&
                    (state.npcInstanceId !== snapshot.npcInstanceId ||
                        state.serviceId !== snapshot.serviceId));
            if (changed) {
                generation++;
                pending = false;
                status.textContent = '';
            }
            state = structuredClone(snapshot);
            render();
            if (state.active && !wasOpen)
                shell.handle.activate();
        },
        setWallet(wallet) {
            currency.setValue(wallet?.ready === false ? undefined : wallet?.balance);
        },
        dispose() {
            disposed = true;
            generation++;
            sources.forEach((binding) => binding.dispose());
            controls.forEach((binding) => binding.dispose());
            tip.dispose();
            currency.dispose();
            shell.dispose();
        },
    };
}
