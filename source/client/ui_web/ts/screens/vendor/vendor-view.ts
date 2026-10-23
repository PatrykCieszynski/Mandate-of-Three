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
  hint.textContent = 'Drag from Inventory · Right-click to remove';
  const yourHeading = document.createElement('h2');
  yourHeading.className = 'vendor-heading';
  yourHeading.textContent = 'Your offer';
  const offerHeading = document.createElement('h2');
  offerHeading.className = 'vendor-heading';
  offerHeading.textContent = 'Vendor’s offer';
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
  const rewardCells = document.createElement('div');
  offer.append(rewardCells);
  const rewardGrid = UiItemGrid(rewardCells, { slotSize: () => 40 });
  const offerSummary = document.createElement('p');
  offerSummary.className = 'vendor-summary';
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
    label: 'Accept',
    onClick: () => void send('confirm', {}),
  });
  const recover = UiButton({
    className: 'ui-button',
    label: 'Check sale result',
    onClick: () => void send('recover', {}),
  });
  confirm.element.setAttribute('aria-label', 'Confirm sale');
  const cancel = UiButton({
    className: 'ui-button',
    label: 'Cancel',
    onClick: options.close,
  });
  const offerHeader = document.createElement('div');
  offerHeader.className = 'vendor-offer-heading';
  offerHeader.append(offerHeading, refresh.element);
  const actions = document.createElement('div');
  actions.className = 'vendor-actions';
  actions.append(confirm.element, cancel.element);
  shell.contentRoot.append(
    offerHeader,
    offer,
    offerSummary,
    yourHeading,
    viewport,
    hint,
    editor,
    status,
    recover.element,
    actions,
  );
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
    let rows = 4;
    const items = state.items.map((item) => {
      let at = 0;
      while (
        Array.from({ length: item.height }, (_, dy) => at + dy * 8).some((c) =>
          occupied.has(c),
        )
      )
        at++;
      for (let dy = 0; dy < item.height; dy++) occupied.add(at + dy * 8);
      rows = Math.max(rows, Math.floor(at / 8) + item.height);
      return { ...item, x: at % 8, y: Math.floor(at / 8) };
    });
    grid.render({ columns: 8, rows, items }, (item) => {
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
    const rewards: {
      kind: 'yang' | 'mystery';
      quantity: string;
      index: number;
    }[] = [];
    if (
      state.quote.yang !== undefined &&
      (state.quote.yang !== '0' || !state.quote.rewards?.length)
    )
      rewards.push({ kind: 'yang', quantity: state.quote.yang, index: 0 });
    for (const reward of state.quote.rewards ?? [])
      rewards.push({
        kind: 'mystery',
        quantity: String(reward.quantity),
        index: rewards.length,
      });
    rewardGrid.render(
      {
        columns: 8,
        rows: Math.max(3, Math.ceil(rewards.length / 8)),
        items: rewards.map((r) => ({
          ...r,
          x: r.index % 8,
          y: Math.floor(r.index / 8),
          height: 1,
        })),
      },
      (reward) => {
        const isYang = reward.kind === 'yang';
        const item = UiSlot({
          label: isYang
            ? `${reward.quantity} Yang`
            : `Random Skill Book ×${reward.quantity}`,
          className: isYang ? 'vendor-yang' : 'vendor-mystery',
        });
        item.setAttribute('role', 'img');
        const symbol = document.createElement('span');
        symbol.className = 'vendor-reward-symbol';
        symbol.textContent = isYang ? '◉' : '?';
        const count = document.createElement('span');
        count.className = 'vendor-reward-count';
        count.textContent = isYang ? reward.quantity : `×${reward.quantity}`;
        item.append(symbol, count);
        item.onpointermove = (e) =>
          tip.show(
            e,
            isYang
              ? {
                  name: `${reward.quantity} Yang`,
                  description:
                    'Currency offered by the vendor for this basket.',
                }
              : {
                  name: 'Random Skill Book',
                  description:
                    'One random book from the available pool. The exact reward is drawn only when the sale commits.',
                },
          );
        item.onpointerleave = () => tip.hide();
        return item;
      },
    );
    offerSummary.textContent =
      state.quote.yang === undefined
        ? 'Add items below to receive an offer.'
        : `${state.quote.yang} Yang${state.quote.rewards?.length ? ' + mystery reward' : ''}`;
    cancel.element.textContent = state.pending ? 'Close' : 'Cancel';
    cancel.element.title = state.pending
      ? 'Close the window; pending sale recovery is retained.'
      : 'Close without confirming the offered items.';
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
      rewardGrid.dispose();
      tip.dispose();
      for (const b of [apply, remove, refresh, confirm, recover, cancel])
        b.dispose();
      shell.dispose();
    },
  };
}
