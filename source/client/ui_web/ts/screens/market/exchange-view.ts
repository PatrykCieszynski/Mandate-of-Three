import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type { ItemPresentation } from '../../game-ui/item-types.js';
import { OwnedItemDragSubject } from '../../game-ui/items/item-drag-policy.js';
import type { CommandResult } from '../../protocol/contracts.js';
import type { ExchangeSnapshot, ExchangeCommand } from './exchange-model.js';
import { marketCommandId } from './market-model.js';
interface Options {
  manager: WindowManager;
  drag: ItemDragRuntime;
  command: (
    action: 'deposit' | 'withdraw' | 'order' | 'cancel_order',
    p: ExchangeCommand,
  ) => Promise<CommandResult>;
  retry: () => Promise<CommandResult>;
  close: () => void;
  regions: () => void;
}
export function mountExchange(root: HTMLElement, o: Options) {
  const shell = new UiWindow(root, {
    id: 'exchange',
    title: 'Currency Exchange',
    className: 'exchange-window',
    manager: o.manager,
    placement: {
      kind: 'viewport',
      anchor: 'top-left',
      offset: { x: 40, y: 90 },
    },
    onClose: o.close,
    onCancel: () => o.drag.cancel(),
    canDrag: () => !o.drag.active,
    onRegionsChanged: o.regions,
  });
  let state: ExchangeSnapshot = { active: false },
    candidate:
      { item: ItemPresentation; source: 'bag' | 'account_storage' } | undefined,
    disposed = false;
  const balances = document.createElement('div'),
    deposit = document.createElement('div');
  deposit.className = 'exchange-deposit';
  deposit.textContent = 'Drop a material from Inventory or Storage.';
  const depositAmount = input('Deposit amount', '1'),
    depositButton = button('Deposit', () => {
      if (candidate)
        void submit('deposit', {
          command_id: marketCommandId(),
          uid: candidate.item.id,
          revision: candidate.item.revision,
          amount: number(depositAmount),
          source: candidate.source,
        });
    });
  const withdrawal = input('Withdraw amount', '1'),
    destination = document.createElement('select');
  destination.dataset.uiText = '';
  destination.setAttribute('aria-label', 'Withdraw destination');
  destination.add(new Option('To bag', 'bag'));
  destination.add(new Option('To account claim', 'claim'));
  const withdrawAsset = document.createElement('select');
  withdrawAsset.dataset.uiText = '';
  withdrawAsset.setAttribute('aria-label', 'Withdraw asset');
  const withdrawButton = button(
    'Withdraw',
    () =>
      void submit('withdraw', {
        command_id: marketCommandId(),
        asset_id: withdrawAsset.value,
        amount: number(withdrawal),
        destination: destination.value as 'bag' | 'claim',
      }),
  );
  const row = document.createElement('div');
  row.className = 'exchange-controls';
  row.append(
    depositAmount,
    depositButton,
    withdrawAsset,
    withdrawal,
    destination,
    withdrawButton,
  );
  const have = document.createElement('select'),
    want = document.createElement('select');
  have.dataset.uiText = want.dataset.uiText = '';
  have.setAttribute('aria-label', 'Have asset');
  want.setAttribute('aria-label', 'Want asset');
  const quantity = input('Material quantity', '100'),
    numerator = input('Yang numerator', '10'),
    denominator = input('Material denominator', '1');
  const orderRow = document.createElement('div');
  orderRow.className = 'exchange-controls';
  const label = document.createElement('p');
  label.textContent =
    'Limit: Yang numerator / Material denominator. Whole Material quantity; no fees.';
  orderRow.append(
    have,
    want,
    quantity,
    numerator,
    denominator,
    button(
      'Place limit order',
      () =>
        void submit('order', {
          command_id: marketCommandId(),
          have_asset: have.value,
          want_asset: want.value,
          quantity: number(quantity),
          price_num: number(numerator),
          price_den: number(denominator),
        }),
    ),
  );
  const depth = document.createElement('div'),
    orders = document.createElement('div'),
    fills = document.createElement('div'),
    status = document.createElement('p');
  status.setAttribute('role', 'status');
  const retry = button('Retry same command', () => void o.retry());
  retry.hidden = true;
  shell.contentRoot.append(
    balances,
    deposit,
    row,
    label,
    orderRow,
    status,
    retry,
    depth,
    orders,
    fills,
  );
  function input(label: string, value: string) {
    const n = document.createElement('input');
    n.type = 'text';
    n.inputMode = 'numeric';
    n.value = value;
    n.setAttribute('aria-label', label);
    n.title = label;
    n.dataset.uiText = '';
    return n;
  }
  function button(label: string, fn: () => void) {
    const n = document.createElement('button');
    n.type = 'button';
    n.className = 'ui-button';
    n.textContent = label;
    n.addEventListener('click', fn);
    return n;
  }
  function number(input: HTMLInputElement) {
    const n = Number(input.value);
    return /^\d+$/.test(input.value) &&
      Number.isSafeInteger(n) &&
      n > 0 &&
      n <= 9000000000000000
      ? n
      : -1;
  }
  async function submit(
    action: Parameters<Options['command']>[0],
    p: ExchangeCommand,
  ) {
    if (!state.active || state.busy) return;
    status.textContent = 'Waiting for server…';
    try {
      const r = await o.command(action, p);
      if (disposed) return;
      status.textContent = r.ok ? 'Committed.' : (r.error ?? 'Rejected');
      if (r.ok && action === 'deposit') {
        candidate = undefined;
        deposit.textContent = 'Drop a material from Inventory or Storage.';
      }
    } catch {
      if (!disposed)
        status.textContent = 'Outcome unknown. Retry the same command.';
    }
  }
  const target = o.drag.registerTarget({
    element: deposit,
    preview: (payload) => {
      const s = payload.subject;
      return {
        valid:
          s instanceof OwnedItemDragSubject &&
          (s.container === 'inventory' || s.container === 'storage'),
        data: s,
      };
    },
    drop: (_payload, preview) => {
      const s = preview.data;
      if (!(s instanceof OwnedItemDragSubject)) return;
      candidate = {
        item: s.item,
        source: s.container === 'storage' ? 'account_storage' : 'bag',
      };
      deposit.textContent =
        'Deposit ' + s.item.name + ' (' + s.item.quantity + ')';
      depositAmount.value = String(s.item.quantity);
    },
  });
  shell.listen(have, 'change', () => {
    if (want.value === have.value)
      want.value = have.value === 'yang' ? withdrawAsset.value : 'yang';
  });
  shell.listen(want, 'change', () => {
    if (have.value === want.value)
      have.value = want.value === 'yang' ? withdrawAsset.value : 'yang';
  });
  function render() {
    if (!state.active) return;
    balances.textContent =
      'Yang free ' +
      (state.yang - state.reservedYang).toLocaleString('en-US') +
      ' / reserved ' +
      state.reservedYang.toLocaleString('en-US');
    for (const a of state.assets) {
      const p = document.createElement('p');
      p.textContent = a.name + ' free ' + a.free + ' / reserved ' + a.reserved;
      balances.append(p);
    }
    const hv = have.value,
      wv = want.value;
    have.replaceChildren(
      new Option('Yang', 'yang'),
      ...state.assets.map((a) => new Option(a.name, a.asset_id)),
    );
    want.replaceChildren(
      new Option('Yang', 'yang'),
      ...state.assets.map((a) => new Option(a.name, a.asset_id)),
    );
    const previousWithdrawAsset = withdrawAsset.value;
    withdrawAsset.replaceChildren(
      ...state.assets.map((a) => new Option(a.name, a.asset_id)),
    );
    if (state.assets.some((a) => a.asset_id === previousWithdrawAsset)) {
      withdrawAsset.value = previousWithdrawAsset;
    }
    have.value = hv || 'yang';
    want.value = wv || state.assets[0]?.asset_id || '';
    depth.replaceChildren();
    const title = document.createElement('p');
    title.textContent = 'Orderbook · Yang / materials';
    depth.append(title);
    for (const d of state.depth) {
      const p = document.createElement('p');
      p.textContent =
        d.side + ' ' + d.remaining + ' @ ' + d.priceNum + '/' + d.priceDen;
      depth.append(p);
    }
    orders.replaceChildren();
    const own = document.createElement('p');
    own.textContent = 'Your orders';
    orders.append(own);
    for (const order of state.orders) {
      const row = document.createElement('p');
      row.textContent =
        order.side +
        ' ' +
        order.asset +
        ' · ' +
        order.remaining +
        '/' +
        order.quantity +
        ' @ ' +
        order.priceNum +
        '/' +
        order.priceDen +
        ' · ' +
        order.status +
        ' · received ' +
        order.received;
      if (order.status === 'active' && !state.ledgerOnly)
        row.append(
          button(
            'Cancel remaining',
            () =>
              void submit('cancel_order', {
                command_id: marketCommandId(),
                order_id: order.id,
                revision: order.revision,
              }),
          ),
        );
      orders.append(row);
    }
    fills.replaceChildren();
    const history = document.createElement('p');
    history.textContent = 'Recent fills';
    fills.append(history);
    for (const f of state.fills) {
      const p = document.createElement('p');
      p.textContent = f.quantity + ' ' + f.asset + ' ↔ ' + f.yang + ' Yang';
      fills.append(p);
    }
    retry.hidden = !state.retryAvailable;
    retry.disabled = state.busy;
    depositButton.disabled = withdrawButton.disabled =
      state.busy || state.retryAvailable;
    for (const control of orderRow.querySelectorAll<
      HTMLInputElement | HTMLSelectElement | HTMLButtonElement
    >('input, select, button'))
      control.disabled =
        !!state.ledgerOnly || state.busy || state.retryAvailable;
    label.textContent = state.ledgerOnly
      ? 'Material deposits and withdrawals are available. Order trading is not enabled yet.'
      : 'Limit: Yang numerator / Material denominator. Whole Material quantity; no fees.';
    shell.refresh();
    o.regions();
  }
  return {
    regions: [shell.panel],
    setState(v: ExchangeSnapshot) {
      const opened = root.hidden && v.active;
      state = v;
      root.hidden = !v.active;
      if (
        !v.active &&
        document.activeElement instanceof HTMLElement &&
        root.contains(document.activeElement)
      )
        document.activeElement.blur();
      render();
      if (opened) shell.handle.activate();
    },
    closeIfActive() {
      if (root.hidden) return false;
      o.close();
      return true;
    },
    dispose() {
      disposed = true;
      target.dispose();
      shell.dispose();
    },
  };
}
