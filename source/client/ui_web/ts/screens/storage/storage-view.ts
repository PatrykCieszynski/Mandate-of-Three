import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type { DragRegistration } from '../../game-ui/drag/item-drag-types.js';
import type { ItemPresentation } from '../../game-ui/item-types.js';
import type { Placement } from '../inventory/placement.js';
import type {
  CommandResult,
  StorageTransferCommand,
} from '../../protocol/contracts.js';
import { errorMessage } from '../../protocol.js';
import {
  ownedItemPayload,
  itemGridPreview,
  itemWindowControls,
} from '../../game-ui/items/item-drag-policy.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { ResolveItemIcon } from '../../game-ui/item-types.js';
import type {
  InventoryItem,
  StorageSnapshot,
} from '../../protocol/contracts.js';
import {
  STORAGE_COLUMNS,
  STORAGE_ROWS,
  STORAGE_PAGES,
  STORAGE_PAGE_CELLS,
  ITEM_SLOT_SIZE,
} from './storage-model.js';
import { UiWindow } from '../../core/window/ui-window.js';
import { UiButton } from '../../core/primitives/ui-button.js';
import { UiTab } from '../../core/primitives/ui-tab.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { UiItemSlot } from '../../game-ui/items/ui-item-slot.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
interface StorageOptions {
  blockCarry?: () => boolean;
  manager: WindowManager;
  resolveItemIcon: ResolveItemIcon;
  onClose: () => void;
  onItemAction?: (event: PointerEvent, item: InventoryItem) => void;
  drag?: ItemDragRuntime;
  retry?: () => Promise<CommandResult>;
  transfer?: (command: StorageTransferCommand) => Promise<CommandResult>;
  onRegionsChanged?: () => void;
}
export function mountStorage(root: HTMLElement, options: StorageOptions) {
  const shell = new UiWindow(root, {
    id: 'storage',
    title: 'Storage',
    className: 'storage-window',
    manager: options.manager,
    placement: {
      kind: 'viewport',
      anchor: 'top-left',
      offset: { x: 16, y: 80 },
    },
    onClose: options.onClose,
    ...(options.onRegionsChanged
      ? { onRegionsChanged: options.onRegionsChanged }
      : {}),
    scrollBorder: 2,
    hideHorizontalOverflow: true,
    onCancel: () => {
      tooltip.hide();
      options.drag?.cancel();
    },
    canDrag: () => !options.drag?.active,
  });
  const nav = document.createElement('nav');
  nav.className = 'storage-tabs';
  nav.setAttribute('aria-label', 'Storage pages');
  const gridRoot = document.createElement('div');
  gridRoot.className = 'storage-grid';
  const viewport = document.createElement('div');
  viewport.className = 'storage-grid-viewport';
  viewport.append(gridRoot);
  const capacity = document.createElement('p');
  capacity.className = 'storage-capacity';
  capacity.textContent = `${STORAGE_PAGE_CELLS} slots per page · ${STORAGE_PAGES} pages`;
  const status = document.createElement('p');
  status.className = 'storage-status';
  status.setAttribute('role', 'status');
  status.hidden = true;
  shell.contentRoot.append(nav, viewport, capacity, status);
  const grid = UiItemGrid(gridRoot, { slotSize: () => ITEM_SLOT_SIZE });
  const tooltip = ItemTooltip(root, { geometry: () => options.manager });
  let state: StorageSnapshot = {
    columns: STORAGE_COLUMNS,
    rows: STORAGE_ROWS,
    pages: STORAGE_PAGES,
    items: [],
  };
  const bindings = itemWindowControls(options.drag, root);
  const sourceBindings: DragRegistration[] = [];
  let pending = false;
  let page = 0,
    disposed = false;
  const retry = UiButton({
    label: 'Retry Storage action',
    onClick: () => void retryIntent(),
  });
  shell.contentRoot.append(retry.element);
  if (options.drag)
    bindings.push(options.drag.registerControl(retry.element, 'cancel'));
  async function retryIntent() {
    if (disposed || pending || !state.recoveryPending || !options.retry) return;
    pending = true;
    retry.setDisabled(true);
    try {
      const result = await options.retry();
      if (!disposed)
        setStatus(
          result.ok
            ? 'Storage action confirmed.'
            : result.error === 'storage_pending'
              ? 'Storage action not confirmed. Retry to check its result.'
              : result.error === 'journal_unavailable'
                ? 'Storage confirmation storage is unavailable. Further transfers are blocked.'
                : `Transfer rejected: ${result.error ?? 'request'}`,
        );
    } catch {
      if (!disposed)
        setStatus('Storage action not confirmed. Retry to check its result.');
    } finally {
      pending = false;
      if (!disposed) retry.setDisabled(false);
    }
  }
  const tabs = ['I', 'II'].map((label, index) => {
    const tab = UiTab({
      label,
      onSelect: () => {
        if (!options.drag?.latched) options.drag?.cancel();
        options.drag?.refreshPreview();
        page = index;
        render();
      },
    });
    nav.append(tab.element);
    return tab;
  });
  function render() {
    retry.element.hidden = !state.recoveryPending || !options.retry;
    retry.setDisabled(pending);
    if (state.recoveryPending)
      setStatus(
        'Storage action not confirmed. Use Retry; the original transfer is saved.',
      );
    sourceBindings.forEach((binding) => binding.dispose());
    sourceBindings.length = 0;
    tooltip.hide();
    grid.render(
      {
        columns: state.columns,
        rows: state.rows,
        items: state.items.filter((item) => item.page === page),
      },
      (item) => {
        const node = UiItemSlot({
          item,
          slotSize: ITEM_SLOT_SIZE,
          resolveItemIcon: options.resolveItemIcon,
        });
        if (options.drag)
          sourceBindings.push(
            options.drag.registerSource({
              element: node,
              payload: (event) => {
                if (pending || state.recoveryPending || options.blockCarry?.())
                  return null;
                shell.handle.activate();
                tooltip.hide();
                if (event.ctrlKey) {
                  void withdrawToInventory(item);
                  return null;
                }
                return ownedItemPayload(
                  'storage',
                  item,
                  ITEM_SLOT_SIZE,
                  options.resolveItemIcon,
                );
              },
            }),
          );
        return node;
      },
    );
    tabs.forEach((tab, index) => tab.setSelected(index === page));
    shell.refresh();
  }
  function itemFor(event: Event) {
    const node =
      event.target instanceof Element
        ? event.target.closest<HTMLElement>('.ui-item-slot')
        : null;
    return state.items.find(
      (item) => item.page === page && item.id === node?.dataset.id,
    );
  }
  shell.listen(gridRoot, 'pointermove', (event) => {
    const item = itemFor(event);
    if (item && !shell.drag && !options.drag?.active) tooltip.show(event, item);
    else tooltip.hide();
  });
  shell.listen(gridRoot, 'pointerleave', () => tooltip.hide());
  shell.listen(gridRoot, 'pointerdown', (event) => {
    const item = itemFor(event);
    if (item) options.onItemAction?.(event, item);
  });
  async function submit(
    from: 'inventory' | 'storage',
    to: 'inventory' | 'storage',
    item: ItemPresentation,
    position?: Placement,
  ) {
    if (pending || state.recoveryPending || disposed || !options.transfer)
      return;
    pending = true;
    setStatus('Transferring…');
    try {
      const result = await options.transfer({
        id: item.id,
        revision: item.revision,
        from,
        to,
        x: position?.x ?? 0,
        y: position?.y ?? 0,
        page: position?.page ?? 0,
        quick: !position,
      });
      if (!disposed)
        setStatus(
          result.ok
            ? ''
            : result.error === 'storage_pending'
              ? 'Storage action not confirmed. Use Retry.'
              : result.error === 'journal_unavailable'
                ? 'Storage confirmation storage is unavailable. Further transfers are blocked.'
                : `Transfer rejected: ${result.error ?? 'request'}`,
        );
    } catch (error) {
      if (!disposed) setStatus(`Transfer failed: ${errorMessage(error)}`);
    } finally {
      pending = false;
      if (!disposed) retry.setDisabled(false);
    }
  }
  function receiveFromInventory(item: ItemPresentation, position?: Placement) {
    return submit('inventory', 'storage', item, position);
  }
  function withdrawToInventory(item: ItemPresentation, position?: Placement) {
    return submit('storage', 'inventory', item, position);
  }
  function setStatus(message: string) {
    status.textContent = message;
    status.hidden = message.length === 0;
    shell.refresh();
  }
  if (options.drag) {
    bindings.push(options.drag.registerControl(nav, 'preserve'));
    bindings.push(
      options.drag.registerTarget({
        element: gridRoot,
        preview: (payload, pointer) => {
          const preview = itemGridPreview(
            gridRoot,
            state,
            page,
            ITEM_SLOT_SIZE,
            payload,
            pointer,
          );
          const valid =
            preview.valid &&
            !pending &&
            !state.recoveryPending &&
            !!options.transfer &&
            preview.data?.subject.container !== 'equipment';
          if (!valid) preview.visual?.element.classList.add('invalid');
          return { ...preview, valid };
        },
        drop: async (_payload, preview) => {
          if (!preview.data) return;
          const { subject, position } = preview.data;
          if (subject.container === 'inventory')
            await receiveFromInventory(subject.item, position);
          else if (subject.container === 'storage')
            await submit('storage', 'storage', subject.item, position);
        },
      }),
    );
  }
  render();
  return {
    regions: [shell.panel],
    refresh: () => shell.refresh(),
    activate: () => shell.handle.activate(),
    setStatus,
    receiveFromInventory,
    tryQuickDeposit(item: ItemPresentation): Promise<void> | null {
      if (
        root.hidden ||
        pending ||
        state.recoveryPending ||
        disposed ||
        !options.transfer
      )
        return null;
      return receiveFromInventory(item);
    },
    withdrawToInventory,
    setState(snapshot: StorageSnapshot) {
      options.drag?.cancel();
      state = structuredClone(snapshot);
      render();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      sourceBindings.forEach((binding) => binding.dispose());
      bindings.forEach((binding) => binding.dispose());
      shell.dispose();
      tabs.forEach((tab) => tab.dispose());
      tooltip.dispose();
      grid.dispose();
      retry.dispose();
    },
  };
}
