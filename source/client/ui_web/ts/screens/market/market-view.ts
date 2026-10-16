import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type {
  DragRegistration,
  DropPreview,
} from '../../game-ui/drag/item-drag-types.js';
import type {
  ItemPresentation,
  ResolveItemIcon,
} from '../../game-ui/item-types.js';
import type {
  InventorySnapshot,
  CommandResult,
  WalletSnapshot,
} from '../../protocol/contracts.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { UiItemSlot } from '../../game-ui/items/ui-item-slot.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import {
  OwnedItemDragSubject,
  itemWindowControls,
} from '../../game-ui/items/item-drag-policy.js';
import {
  carriedCell,
  placement,
  firstFittingPlacement,
} from '../inventory/placement.js';
import {
  OwnMarketOffer,
  type MarketOffer,
  type MarketSnapshot,
  type MarketCommand,
} from './market-model.js';
type Action = 'list' | 'edit' | 'cancel' | 'claim' | 'configure';
interface Options {
  manager: WindowManager;
  drag: ItemDragRuntime;
  resolveItemIcon: ResolveItemIcon;
  command: (action: Action, payload: MarketCommand) => Promise<CommandResult>;
  collectRevenue?: (retry: boolean) => Promise<CommandResult>;
  onClose: () => void;
  onRegionsChanged: () => void;
}
export function mountMarket(root: HTMLElement, options: Options) {
  const shell = new UiWindow(root, {
    id: 'player-shop',
    title: 'My Shop',
    className: 'player-shop-window',
    manager: options.manager,
    placement: {
      kind: 'relative',
      target: 'inventory',
      side: 'left',
      gap: 12,
      fallback: {
        kind: 'viewport',
        anchor: 'top-right',
        offset: { x: 280, y: 80 },
      },
    },
    onClose: options.onClose,
    onCancel: () => options.drag.cancel(),
    canDrag: () => !options.drag.active,
    onRegionsChanged: options.onRegionsChanged,
  });
  const name = document.createElement('input');
  name.className = 'market-name';
  name.maxLength = 40;
  name.setAttribute('aria-label', 'Shop name');
  name.dataset.uiText = '';
  const nameRow = document.createElement('div');
  nameRow.className = 'market-toolbar';
  const save = button('Save', () => void configure()),
    pause = button(
      'Pause',
      () =>
        void configure(
          state.active && state.status === 'active' ? 'paused' : 'active',
        ),
    );
  nameRow.append(name, save, pause);
  const gridRoot = document.createElement('div');
  gridRoot.className = 'market-grid';
  const grid = UiItemGrid(gridRoot, { slotSize: () => 40 }),
    tooltip = ItemTooltip(root, { geometry: () => options.manager });
  const selection = document.createElement('p');
  selection.className = 'market-selection';
  selection.textContent = 'Drop an Inventory item here to list it.';
  const price = document.createElement('input');
  price.type = 'text';
  price.inputMode = 'numeric';
  price.value = '100';
  price.dataset.uiText = '';
  price.setAttribute('aria-label', 'Whole stack price in Yang');
  const negotiable = document.createElement('input');
  negotiable.type = 'checkbox';
  negotiable.setAttribute('aria-label', 'Do negocjacji (bez ceny)');
  const negotiableLabel = document.createElement('label');
  negotiableLabel.append(negotiable, document.createTextNode('Do negocjacji'));
  negotiable.addEventListener('change', () => {
    price.disabled = negotiable.checked;
  });
  const actions = document.createElement('div');
  actions.className = 'market-actions';
  const confirm = button('List item', () => void submitSelection()),
    cancel = button('Withdraw to Inventory', () => void cancelSelection());
  actions.append(price, negotiableLabel, confirm, cancel);
  const claims = document.createElement('div');
  claims.className = 'market-claims';
  const claimsTitle = document.createElement('p');
  claimsTitle.textContent = 'Account claims';
  const status = document.createElement('p');
  status.className = 'market-status';
  status.setAttribute('role', 'status');
  const retry = button('Retry same command', () => {
    if (lastIntent) void submit(lastIntent.action, lastIntent.payload);
  });
  retry.hidden = true;
  const wallet = document.createElement('p');
  wallet.className = 'market-wallet';
  const revenue = document.createElement('p');
  const collect = button('Collect Yang', () => void collectRevenue());
  async function collectRevenue() {
    if (!state.active || pending || disposed || !options.collectRevenue) return;
    pending = true;
    collect.disabled = true;
    try {
      const result = await options.collectRevenue(
        Boolean(state.revenuePending),
      );
      if (!disposed)
        setStatus(
          result.ok
            ? 'Revenue collected.'
            : String(result.error ?? 'Outcome unknown.'),
        );
    } catch {
      if (!disposed) setStatus('Outcome unknown. Retry collection.');
    } finally {
      pending = false;
      if (!disposed) render();
    }
  }
  shell.contentRoot.append(
    nameRow,
    gridRoot,
    selection,
    actions,
    claimsTitle,
    claims,
    status,
    retry,
    wallet,
    revenue,
    collect,
  );
  let state: MarketSnapshot = { active: false },
    inventory: InventorySnapshot = { columns: 5, rows: 9, pages: 4, items: [] };
  let candidate: { item: ItemPresentation; position: number } | null = null,
    selected: string | null = null,
    pending = false,
    disposed = false;
  let lastIntent: { action: Action; payload: MarketCommand } | null = null;
  const bindings: DragRegistration[] = itemWindowControls(options.drag, root),
    sources: DragRegistration[] = [];
  function button(label: string, onClick: () => void) {
    const node = document.createElement('button');
    node.className = 'ui-button';
    node.type = 'button';
    node.textContent = label;
    node.addEventListener('click', onClick);
    return node;
  }
  function commandId() {
    return (
      globalThis.crypto?.randomUUID?.() ??
      'market_' + Date.now() + '_' + Math.random().toString(16).slice(2)
    );
  }
  function model() {
    return {
      columns: 5,
      rows: 8,
      pages: 1,
      items: state.active ? state.offers.map((o) => o.item) : [],
    };
  }
  function chosen(): MarketOffer | undefined {
    return state.active
      ? state.offers.find((o) => o.id === selected)
      : undefined;
  }
  function setStatus(message: string) {
    status.textContent = message;
    shell.refresh();
  }
  function choose(offer: MarketOffer) {
    candidate = null;
    selected = offer.id;
    negotiable.checked = offer.price === null;
    price.disabled = negotiable.checked;
    if (offer.price !== null) price.value = String(offer.price);
    selection.textContent =
      offer.item.name +
      ' · ' +
      (offer.price === null
        ? 'Do negocjacji'
        : offer.price.toLocaleString('en-US') + ' Yang');
    confirm.textContent = 'Set price';
    cancel.disabled = false;
  }
  function selectInventory(identity: { id: string; revision: number }) {
    const item = inventory.items.find(
      (i) => i.id === identity.id && i.revision === identity.revision,
    );
    if (!item) return Promise.resolve({ ok: false, error: 'stale' });
    const target = firstFittingPlacement(model(), item);
    if (!target) return Promise.resolve({ ok: false, error: 'capacity' });
    pick(item, target.y * 5 + target.x);
    return Promise.resolve({ ok: true });
  }
  function pick(item: ItemPresentation, position: number) {
    candidate = { item, position };
    selected = null;
    selection.textContent = item.name + ' → slot ' + (position + 1);
    confirm.textContent = 'List item';
    cancel.disabled = true;
    if (!negotiable.checked) price.focus();
  }
  async function submit(action: Action, payload: MarketCommand) {
    if (pending || disposed) return;
    pending = true;
    lastIntent = { action, payload };
    retry.hidden = true;
    setStatus('Waiting for server…');
    try {
      const result = await options.command(action, payload);
      if (disposed) return;
      setStatus(result.ok ? 'Saved.' : String(result.error ?? 'Rejected.'));
      if (result.ok) {
        lastIntent = null;
        if (
          document.activeElement instanceof HTMLElement &&
          root.contains(document.activeElement)
        )
          document.activeElement.blur();
      } else if (result.error === 'timeout') retry.hidden = false;
    } catch {
      if (!disposed) {
        setStatus('Outcome unknown. Retry the same command.');
        retry.hidden = false;
      }
    } finally {
      pending = false;
    }
  }
  function validPrice() {
    if (negotiable.checked) return 0;
    const value = Number(price.value);
    return /^\d+$/.test(price.value) &&
      Number.isSafeInteger(value) &&
      value > 0 &&
      value <= 9000000000000000
      ? value
      : null;
  }
  async function submitSelection() {
    const value = validPrice();
    if (value === null) {
      setStatus('Enter a positive whole Yang price.');
      return;
    }
    if (candidate) {
      await submit('list', {
        command_id: commandId(),
        uid: candidate.item.id,
        revision: candidate.item.revision,
        position: candidate.position,
        price: value,
      });
    } else {
      const offer = chosen();
      if (offer)
        await submit('edit', {
          command_id: commandId(),
          offer_id: offer.id,
          revision: offer.revision,
          position: offer.item.y * 5 + offer.item.x,
          price: value,
        });
    }
  }
  async function configure(statusValue?: 'active' | 'paused') {
    if (!state.active) return;
    await submit('configure', {
      command_id: commandId(),
      revision: state.revision,
      name: name.value,
      status: statusValue ?? state.status,
    });
  }
  async function cancelSelection() {
    const offer = chosen();
    if (offer)
      await submit('cancel', {
        command_id: commandId(),
        offer_id: offer.id,
        revision: offer.revision,
      });
  }
  const target = options.drag.registerTarget({
    element: gridRoot,
    preview: (
      payload,
      pointer,
    ): DropPreview<{
      item: ItemPresentation;
      position: number;
      offer?: MarketOffer;
    } | null> => {
      const owned =
        payload.subject instanceof OwnedItemDragSubject &&
        payload.subject.container === 'inventory'
          ? payload.subject
          : null;
      const offered =
        payload.subject instanceof OwnMarketOffer ? payload.subject : null;
      if (!owned && !offered) return { valid: false, data: null };
      const item = owned?.item ?? offered!.offer.item,
        rect = gridRoot.getBoundingClientRect();
      const cell = carriedCell(
        {
          x: (pointer.point.x - rect.left) / pointer.scale,
          y: (pointer.point.y - rect.top) / pointer.scale,
        },
        pointer.grabOffset,
        40,
      );
      const preview = placement(model(), item, cell.x, cell.y, 0),
        valid = preview.valid && !pending && state.active;
      const marker = document.createElement('div');
      marker.className = 'placement-preview' + (valid ? '' : ' invalid');
      marker.style.left = cell.x * 40 + 'px';
      marker.style.top = cell.y * 40 + 'px';
      marker.style.height = item.height * 40 + 'px';
      return {
        valid,
        data: {
          item,
          position: cell.y * 5 + cell.x,
          ...(offered ? { offer: offered.offer } : {}),
        },
        visual: { element: marker, parent: gridRoot },
      };
    },
    drop: async (_payload, preview) => {
      if (!preview.data) return;
      const { item, position, offer } = preview.data;
      if (offer)
        await submit('edit', {
          command_id: commandId(),
          offer_id: offer.id,
          revision: offer.revision,
          position,
          price: offer.price ?? 0,
        });
      else pick(item, position);
    },
  });
  bindings.push(
    target,
    options.drag.registerControl(nameRow, 'cancel'),
    options.drag.registerControl(actions, 'cancel'),
    options.drag.registerControl(collect, 'cancel'),
  );
  shell.listen(gridRoot, 'pointermove', (event) => {
    const node =
      event.target instanceof Element
        ? event.target.closest<HTMLElement>('.ui-item-slot')
        : null;
    const offer = state.active
      ? state.offers.find((o) => o.item.id === node?.dataset.id)
      : undefined;
    if (offer && !options.drag.active) tooltip.show(event, offer.item);
    else tooltip.hide();
  });
  shell.listen(gridRoot, 'pointerleave', () => tooltip.hide());
  shell.listen(price, 'keydown', (event) => {
    if (event.key === 'Enter') void submitSelection();
    else if (event.key === 'Escape') options.onClose();
  });
  shell.listen(name, 'keydown', (event) => {
    if (event.key === 'Enter') void configure();
    else if (event.key === 'Escape') options.onClose();
  });
  function render() {
    revenue.textContent =
      'Claimable: ' +
      (state.active
        ? (state.claimableYang ?? '0').replace(/\B(?=(\d{3})+(?!\d))/g, ',')
        : '0') +
      ' Yang';
    collect.textContent =
      state.active && state.revenuePending
        ? 'Retry collection'
        : 'Collect Yang';
    collect.disabled =
      pending ||
      !state.active ||
      Boolean(state.revenueBusy) ||
      (!state.revenuePending && (state.claimableYang ?? '0') === '0');
    sources.forEach((s) => s.dispose());
    sources.length = 0;
    tooltip.hide();
    grid.render(
      {
        columns: 5,
        rows: 8,
        items: state.active ? state.offers.map((o) => o.item) : [],
      },
      (item) => {
        const node = UiItemSlot({
          item,
          slotSize: 40,
          resolveItemIcon: options.resolveItemIcon,
        });
        const offer = state.active
          ? state.offers.find((o) => o.item.id === item.id)
          : undefined;
        if (offer)
          sources.push(
            options.drag.registerSource({
              element: node,
              payload: () => {
                if (pending) return null;
                choose(offer);
                return {
                  sourceId: 'player-shop',
                  subject: new OwnMarketOffer(offer),
                  presentation: {
                    width: 38,
                    height: item.height * 40 - 2,
                    render: (ghost) =>
                      paintItemIcon(ghost, item, {
                        resolveItemIcon: options.resolveItemIcon,
                      }),
                  },
                };
              },
            }),
          );
        return node;
      },
    );
    claims.replaceChildren();
    if (state.active)
      for (const item of state.claims) {
        const node = button(
          'Collect ' + item.name,
          () =>
            void submit('claim', {
              command_id: commandId(),
              uid: item.id,
              revision: item.revision,
            }),
        );
        node.title = item.name;
        claims.append(node);
      }
    if (state.active) {
      if (document.activeElement !== name) name.value = state.name;
      pause.textContent = state.status === 'active' ? 'Pause' : 'Resume';
    }
    if (selected && !chosen()) {
      selected = null;
      selection.textContent = 'Drop an Inventory item here to list it.';
    }
    shell.refresh();
    options.onRegionsChanged();
  }
  return {
    regions: [shell.panel],
    refresh: () => shell.refresh(),
    selectInventory,
    setWallet(snapshot: WalletSnapshot) {
      wallet.textContent =
        'Yang ' + (snapshot.balance ?? 0).toLocaleString('en-US');
    },
    setInventory(snapshot: InventorySnapshot) {
      inventory = snapshot;
      if (
        candidate &&
        !snapshot.items.some(
          (i) =>
            i.id === candidate!.item.id &&
            i.revision === candidate!.item.revision,
        )
      ) {
        candidate = null;
        selection.textContent = 'Drop an Inventory item here to list it.';
      }
    },
    setState(snapshot: MarketSnapshot) {
      const opened = root.hidden && snapshot.active;
      state = snapshot;
      if (
        !snapshot.active &&
        document.activeElement instanceof HTMLElement &&
        root.contains(document.activeElement)
      )
        document.activeElement.blur();
      root.hidden = !snapshot.active;
      render();
      if (opened) shell.handle.activate();
    },
    closeIfActive() {
      if (root.hidden) return false;
      options.onClose();
      return true;
    },
    dispose() {
      disposed = true;
      sources.forEach((s) => s.dispose());
      bindings.forEach((b) => b.dispose());
      tooltip.dispose();
      grid.dispose();
      shell.dispose();
    },
  };
}
