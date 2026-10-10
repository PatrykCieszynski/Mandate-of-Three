import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import { UiSlot } from '../../core/primitives/ui-slot.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ITEM_SLOT_SIZE } from '../../game-ui/items/item-geometry.js';
import { shopOfferLayout } from './shop-layout.js';
import { UiCurrency } from '../../core/primitives/ui-currency.js';
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
    scrollBorder: 2,
    hideHorizontalOverflow: true,
    onClose: options.onClose,
    canDrag: () => !options.drag.active,
    onCancel: () => options.drag.cancel(),
    ...(options.onRegionsChanged
      ? { onRegionsChanged: options.onRegionsChanged }
      : {}),
  });
  const offers = document.createElement('div');
  offers.className = 'shop-offers';
  const grid = document.createElement('div');
  grid.className = 'shop-grid';
  grid.setAttribute('aria-label', 'Shop offers');
  offers.append(grid);
  const gridView = UiItemGrid(grid, { slotSize: () => ITEM_SLOT_SIZE });
  const wallet = document.createElement('footer'),
    status = document.createElement('p');
  status.className = 'shop-status';
  status.setAttribute('role', 'status');
  status.hidden = true;
  shell.contentRoot.append(offers, wallet, status);
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
  function setStatus(text: string) {
    status.textContent = text;
    status.hidden = !text;
    shell.refresh();
    options.onRegionsChanged?.();
  }
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
    setStatus('Buying…');
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
        setStatus(
          result.ok
            ? 'Purchased.'
            : (errors[result.error ?? ''] ??
                `Purchase rejected: ${result.error ?? 'request'}`),
        );
    } catch {
      if (!disposed && generation === requestGeneration)
        setStatus('Purchase failed. Try again.');
    } finally {
      if (generation === requestGeneration) pending = false;
    }
  }
  function render() {
    sources.forEach((binding) => binding.dispose());
    sources.length = 0;
    grid.replaceChildren();
    root.hidden = !state.active;
    if (state.active) {
      const catalog = state;
      shell.panel.querySelector('h1')!.textContent = catalog.name;
      gridView.render(shopOfferLayout(catalog.offers), (offer) => {
        const entry = UiSlot({
          className: 'ui-item-slot shop-offer shop-item',
          label: offer.name,
        });
        entry.dataset.offerId = offer.offerId;
        entry.dataset.height = String(offer.height);
        entry.style.height = offer.height * ITEM_SLOT_SIZE - 2 + 'px';
        paintItemIcon(
          entry,
          { ...offer, icon_id: offer.iconId },
          { resolveItemIcon: options.resolveItemIcon },
        );
        const subject = new NpcShopOfferDragSubject(
          catalog.npcInstanceId,
          catalog.serviceId,
          offer,
        );
        sources.push(
          options.drag.registerSource({
            element: entry,
            payload: () => {
              if (pending) return null;
              tip.hide();
              return shopOfferPayload(
                subject,
                ITEM_SLOT_SIZE,
                options.resolveItemIcon,
              );
            },
          }),
        );
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
              currency: catalog.currency,
            });
        });
        entry.addEventListener('pointerleave', () => tip.hide());
        return entry;
      });
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
        status.hidden = true;
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
      gridView.dispose();
      tip.dispose();
      currency.dispose();
      shell.dispose();
    },
  };
}
