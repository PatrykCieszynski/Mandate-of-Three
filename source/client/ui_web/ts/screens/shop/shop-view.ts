import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import { UiSlot } from '../../core/primitives/ui-slot.js';
import { UiCurrency } from '../../core/primitives/ui-currency.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { itemWindowControls } from '../../game-ui/items/item-drag-policy.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type { DragRegistration } from '../../game-ui/drag/item-drag-types.js';
import type { ResolveItemIcon } from '../../game-ui/item-types.js';
import type {
  WalletSnapshot,
  CommandResult,
} from '../../protocol/contracts.js';
import type { Placement } from '../inventory/placement.js';
import type { ShopSnapshot, ShopBuyCommand } from './shop-model.js';
import {
  NpcShopOfferDragSubject,
  shopOfferPayload,
} from './shop-drag-policy.js';
export function mountShop(
  root: HTMLElement,
  options: {
    manager: WindowManager;
    drag: ItemDragRuntime;
    resolveItemIcon: ResolveItemIcon;
    buy: (command: ShopBuyCommand) => Promise<CommandResult>;
    onClose: () => void;
    onRegionsChanged?: () => void;
  },
) {
  let state: ShopSnapshot = { active: false },
    pending = false,
    disposed = false,
    generation = 0;
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
  const wallet = document.createElement('footer'),
    status = document.createElement('p');
  status.className = 'shop-status';
  status.setAttribute('role', 'status');
  shell.contentRoot.append(offers, hint, wallet, status);
  const currency = UiCurrency(wallet, {
      label: 'Yang',
      iconId: 'currencies.yang',
    }),
    tip = ItemTooltip(root, { geometry: () => options.manager });
  const sources: DragRegistration[] = [],
    controls = itemWindowControls(options.drag, root);
  const errors: Record<string, string> = {
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
  async function buyOffer(
    subject: NpcShopOfferDragSubject,
    position?: Placement,
  ): Promise<void> {
    if (
      !state.active ||
      pending ||
      subject.npcInstanceId !== state.npcInstanceId ||
      subject.serviceId !== state.serviceId ||
      !state.offers.some((offer) => offer.offerId === subject.offer.offerId)
    )
      return;
    pending = true;
    tip.hide();
    status.textContent = 'Buying…';
    const requestGeneration = generation;
    const command: ShopBuyCommand = {
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
    } catch {
      if (!disposed && generation === requestGeneration)
        status.textContent = 'Purchase failed. Try again.';
    } finally {
      if (generation === requestGeneration) pending = false;
    }
  }
  function render() {
    sources.forEach((binding) => binding.dispose());
    sources.length = 0;
    offers.replaceChildren();
    root.hidden = !state.active;
    if (state.active) {
      shell.panel.querySelector('h1')!.textContent = state.name;
      for (const offer of state.offers) {
        const entry = document.createElement('div');
        entry.className = 'shop-offer';
        entry.dataset.offerId = offer.offerId;
        const icon = UiSlot({
          className: 'ui-item-slot shop-item',
          label: offer.name,
        });
        icon.style.height = offer.height * 40 - 2 + 'px';
        paintItemIcon(
          icon,
          { ...offer, icon_id: offer.iconId },
          { resolveItemIcon: options.resolveItemIcon },
        );
        const name = document.createElement('span');
        name.className = 'shop-offer-name';
        name.textContent = offer.name;
        const price = document.createElement('span');
        price.className = 'shop-price';
        price.textContent = offer.price.toLocaleString('en-US') + ' Yang';
        const quantity = document.createElement('span');
        quantity.className = 'shop-quantity';
        quantity.textContent = '×' + offer.quantity;
        entry.append(icon, name, quantity, price);
        offers.append(entry);
        const subject = new NpcShopOfferDragSubject(
          state.npcInstanceId,
          state.serviceId,
          offer,
        );
        sources.push(
          options.drag.registerSource({
            element: icon,
            payload: () => {
              if (pending) return null;
              tip.hide();
              return shopOfferPayload(subject, 40, options.resolveItemIcon);
            },
          }),
        );
        icon.addEventListener('pointerdown', (event) => {
          if (event.button === 2 && !options.drag.active && !pending) {
            event.preventDefault();
            void buyOffer(subject);
          }
        });
        icon.addEventListener('pointermove', (event) => {
          if (!options.drag.active && !pending)
            tip.show(event, {
              name: offer.name,
              description:
                offer.description ??
                `${offer.price.toLocaleString('en-US')} Yang · Quantity ${offer.quantity}`,
            });
        });
        icon.addEventListener('pointerleave', () => tip.hide());
      }
    }
    shell.refresh();
    options.onRegionsChanged?.();
  }
  return {
    regions: [shell.panel],
    buyOffer,
    setState(snapshot: ShopSnapshot) {
      tip.hide();
      const wasOpen = state.active;
      const changed =
        state.active !== snapshot.active ||
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
      if (state.active && !wasOpen) shell.handle.activate();
    },
    setWallet(wallet: WalletSnapshot | undefined) {
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
