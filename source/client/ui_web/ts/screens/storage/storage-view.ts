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
import { UiTab } from '../../core/primitives/ui-tab.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { UiItemSlot } from '../../game-ui/items/ui-item-slot.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
interface StorageOptions {
  manager: WindowManager;
  resolveItemIcon: ResolveItemIcon;
  onClose: () => void;
  onItemAction: (event: PointerEvent, item: InventoryItem) => void;
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
    onCancel: () => tooltip.hide(),
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
  let page = 0,
    disposed = false;
  const tabs = ['I', 'II'].map((label, index) => {
    const tab = UiTab({
      label,
      onSelect: () => {
        page = index;
        render();
      },
    });
    nav.append(tab.element);
    return tab;
  });
  function render() {
    tooltip.hide();
    grid.render(
      {
        columns: state.columns,
        rows: state.rows,
        items: state.items.filter((item) => item.page === page),
      },
      (item) =>
        UiItemSlot({
          item,
          slotSize: ITEM_SLOT_SIZE,
          resolveItemIcon: options.resolveItemIcon,
        }),
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
    if (item && !shell.drag) tooltip.show(event, item);
    else tooltip.hide();
  });
  shell.listen(gridRoot, 'pointerleave', () => tooltip.hide());
  shell.listen(gridRoot, 'pointerdown', (event) => {
    const item = itemFor(event);
    if (item) options.onItemAction(event, item);
  });
  render();
  return {
    regions: [shell.panel],
    refresh: () => shell.refresh(),
    activate: () => shell.handle.activate(),
    setStatus(message: string) {
      status.textContent = message;
      status.hidden = message.length === 0;
      shell.refresh();
    },
    setState(snapshot: StorageSnapshot) {
      state = structuredClone(snapshot);
      render();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      shell.dispose();
      tabs.forEach((tab) => tab.dispose());
      tooltip.dispose();
      grid.dispose();
    },
  };
}
