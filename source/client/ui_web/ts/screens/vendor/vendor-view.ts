import { UiWindow } from '../../core/window/ui-window.js';
import { UiButton } from '../../core/primitives/ui-button.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { UiSlot } from '../../core/primitives/ui-slot.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import {
  OwnedItemDragSubject,
  itemWindowControls,
} from '../../game-ui/items/item-drag-policy.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type { ResolveItemIcon } from '../../game-ui/item-types.js';
import type { CommandResult } from '../../protocol/contracts.js';
import type { VendorSnapshot } from './vendor-model.js';

export function mountVendor(
  root: HTMLElement,
  options: {
    manager: WindowManager;
    drag: ItemDragRuntime;
    resolveItemIcon: ResolveItemIcon;
    command: (
      action: 'edit' | 'refresh' | 'confirm' | 'recover',
      p: Record<string, unknown>,
    ) => Promise<CommandResult>;
    close: () => void;
    regions: () => void;
  },
) {
  let state: VendorSnapshot | undefined,
    disposed = false,
    flight = false,
    selected = '';
  const shell = new UiWindow(root, {
    id: 'vendor',
    title: 'Sell',
    className: 'vendor-window',
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
        offset: { x: 20, y: 150 },
      },
    },
    onClose: options.close,
    onCancel: () => options.drag.cancel(),
    canDrag: () => !options.drag.active,
    onRegionsChanged: options.regions,
    scrollBorder: 2,
    hideHorizontalOverflow: true,
  });
  const hint = document.createElement('p');
  hint.className = 'vendor-hint';
  hint.textContent = 'Offer items from Inventory. Right-click to remove.';
  const viewport = document.createElement('div');
  viewport.className = 'vendor-basket';
  viewport.setAttribute('aria-label', 'Sale basket');
  const cells = document.createElement('div');
  viewport.append(cells);
  const grid = UiItemGrid(cells, { slotSize: () => 40 });
  const editor = document.createElement('div');
  editor.className = 'vendor-quantity';
  const amount = document.createElement('input');
  amount.type = 'number';
  amount.min = '1';
  amount.max = '200';
  amount.step = '1';
  amount.setAttribute('aria-label', 'Quantity to sell');
  const apply = UiButton({
    className: 'ui-button',
    label: 'Set quantity',
    onClick: () => {
      if (selected)
        void send('edit', { id: selected, amount: Number(amount.value) });
    },
  });
  const remove = UiButton({
    className: 'ui-button',
    label: 'Remove',
    onClick: () => {
      if (selected) void send('edit', { id: selected, amount: 0 });
    },
  });
  editor.append(amount, apply.element, remove.element);
  const offer = document.createElement('div');
  offer.className = 'vendor-offer';
  offer.setAttribute('aria-label', 'Vendor offer');
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  status.className = 'vendor-status';
  const refresh = UiButton({
    className: 'ui-button',
    label: 'Refresh offer',
    onClick: () => void send('refresh', {}),
  });
  const confirm = UiButton({
    className: 'ui-button',
    label: 'Confirm sale',
    onClick: () => void send('confirm', {}),
  });
  const recover = UiButton({
    className: 'ui-button',
    label: 'Check sale result',
    onClick: () => void send('recover', {}),
  });
  const actions = document.createElement('div');
  actions.className = 'vendor-actions';
  actions.append(refresh.element, confirm.element, recover.element);
  shell.contentRoot.append(hint, viewport, editor, offer, status, actions);
  const tip = ItemTooltip(root, { geometry: () => options.manager });
  const controls = itemWindowControls(options.drag, root);
  controls.push(
    options.drag.registerTarget({
      element: viewport,
      preview: (payload) => ({
        valid:
          !!state?.active &&
          !state.pending &&
          !state.busy &&
          !flight &&
          payload.subject instanceof OwnedItemDragSubject &&
          payload.subject.container === 'inventory',
        data: null,
      }),
      drop: async (payload) => {
        const s = payload.subject;
        if (
          s instanceof OwnedItemDragSubject &&
          s.container === 'inventory' &&
          !state?.pending
        )
          await send('edit', {
            id: s.item.id,
            amount: Math.min(200, s.item.quantity),
          });
      },
    }),
  );
  const errors: Record<string, string> = {
    sale_pending:
      'Sale not confirmed. Check its result before making another sale.',
    not_committed: 'No sale was recorded. Refresh the offer and confirm again.',
    stale: 'An offered item changed. Remove it and add it again.',
    quote_expired: 'Offer expired. Refresh it before confirming.',
    quote_stale: 'Offer is no longer current. Refresh it.',
    unsellable: 'The basket contains an item this vendor cannot buy.',
    basket_limit: 'Basket limit: 32 items and 1000 units.',
    overflow: 'The sale would exceed your Yang limit.',
    journal_unavailable:
      'Sale recovery storage is unavailable. Confirming is blocked.',
    storage: 'Offer unavailable. Refresh or check the pending sale.',
    out_of_range: 'Move closer to the NPC.',
    no_interaction: 'Reopen the NPC shop.',
    inventory_full: 'Not enough room for the reward. Nothing was sold.',
  };
  async function send(
    action: 'edit' | 'refresh' | 'confirm' | 'recover',
    p: Record<string, unknown>,
  ) {
    if (disposed || flight) return { ok: false, error: 'busy' };
    flight = true;
    updateActions();
    tip.hide();
    try {
      const r = await options.command(action, p);
      if (!disposed && !r.ok)
        status.textContent =
          errors[r.error ?? ''] ?? `Request rejected: ${r.error ?? 'request'}`;
      return r;
    } catch {
      if (!disposed)
        status.textContent = 'Response not confirmed. Check the sale result.';
      return { ok: false, error: 'timeout' };
    } finally {
      flight = false;
      if (!disposed) updateActions();
    }
  }
  function updateActions() {
    const locked = flight || !!state?.busy;
    confirm.setDisabled(
      locked ||
        !state?.ready ||
        !!state.pending ||
        !state.quote.yang ||
        state.items.some((i) => !i.available),
    );
    refresh.setDisabled(
      locked ||
        !state?.ready ||
        !!state.pending ||
        !state?.items.length ||
        !!state?.quoting,
    );
    recover.element.hidden = !state?.pending;
    recover.setDisabled(locked);
    amount.disabled = locked || !!state?.pending;
    apply.setDisabled(amount.disabled);
    remove.setDisabled(amount.disabled);
  }
  function render() {
    if (!state) return;
    root.hidden = !state.active;
    tip.hide();
    const occupied = new Set<number>();
    let rows = 3;
    const items = state.items.map((item) => {
      let at = 0;
      while (
        Array.from({ length: item.height }, (_, dy) => at + dy * 5).some((c) =>
          occupied.has(c),
        )
      )
        at++;
      for (let dy = 0; dy < item.height; dy++) occupied.add(at + dy * 5);
      rows = Math.max(rows, Math.floor(at / 5) + item.height);
      return { ...item, x: at % 5, y: Math.floor(at / 5) };
    });
    grid.render({ columns: 5, rows, items }, (item) => {
      const el = UiSlot({
        tag: 'button',
        label: `Offered ${item.name}`,
        className: 'ui-item-slot vendor-item',
      });
      el.style.height = `${item.height * 40 - 2}px`;
      el.classList.toggle('unavailable', !item.available);
      paintItemIcon(el, item, { resolveItemIcon: options.resolveItemIcon });
      el.onclick = () => {
        selected = item.id;
        amount.value = String(item.quantity);
        amount.max = String(item.maximum);
        editor.hidden = false;
      };
      el.oncontextmenu = (e) => {
        e.preventDefault();
        if (!state?.pending) void send('edit', { id: item.id, amount: 0 });
      };
      el.onpointermove = (e) => {
        if (!options.drag.active) tip.show(e, item);
      };
      el.onpointerleave = () => tip.hide();
      return el;
    });
    editor.hidden = !state.items.some((i) => i.id === selected);
    offer.replaceChildren();
    const yang = document.createElement('div');
    yang.className = 'vendor-yang';
    yang.textContent =
      state.quote.yang === undefined
        ? 'Add items to receive an offer.'
        : `${state.quote.yang} Yang`;
    offer.append(yang);
    for (const reward of state.quote.rewards ?? []) {
      const mystery = UiSlot({
        label: `Random Skill Book ×${reward.quantity}`,
        className: 'vendor-mystery',
      });
      mystery.setAttribute('role', 'img');
      mystery.textContent = `? ×${reward.quantity}`;
      mystery.onpointermove = (e) =>
        tip.show(e, {
          name: 'Random Skill Book',
          description:
            'One random book from the available pool. The exact reward is drawn only when the sale commits.',
        });
      mystery.onpointerleave = () => tip.hide();
      offer.append(mystery);
    }
    status.textContent = state.busy
      ? 'Confirming sale…'
      : state.quoting
        ? 'Requesting offer…'
        : state.outcome || (errors[state.error] ?? state.error);
    updateActions();
    shell.refresh();
    options.regions();
  }
  return {
    regions: [shell.panel],
    setState(next: VendorSnapshot) {
      const open = !state?.active && next.active;
      state = structuredClone(next);
      render();
      if (open) shell.handle.activate();
    },
    dispose() {
      disposed = true;
      controls.forEach((c) => c.dispose());
      grid.dispose();
      tip.dispose();
      for (const b of [apply, remove, refresh, confirm, recover]) b.dispose();
      shell.dispose();
    },
  };
}
