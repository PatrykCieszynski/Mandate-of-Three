import type { InventoryItem } from '../web/protocol/contracts.js';
import type { ItemContainer } from '../web/screens/storage/transfer.js';
import type { WindowManager } from '../web/core/window/window-manager.js';
import type { ResolveItemIcon } from '../web/game-ui/item-types.js';
import { carriedCell, placement } from '../web/screens/inventory/placement.js';
import { paintItemIcon } from '../web/game-ui/items/item-icon.js';
type ContainerId = 'inventory' | 'storage';
interface Target {
  container: ContainerId;
  x: number;
  y: number;
  page: number;
  valid: boolean;
}
interface Carry {
  container: ContainerId;
  item: InventoryItem;
  node: HTMLElement;
  pointer: number;
  x: number;
  y: number;
  offsetX: number;
  offsetY: number;
  moved: boolean;
  latched: boolean;
}
export function previewItemTransfer(options: {
  manager: WindowManager;
  resolveItemIcon: ResolveItemIcon;
  getState: (id: ContainerId) => ItemContainer;
  move: (
    from: ContainerId,
    to: ContainerId,
    item: InventoryItem,
    target?: Target,
  ) => boolean;
}) {
  let carry: Carry | null = null;
  let target: Target | null = null;
  const ghost = document.createElement('div');
  ghost.className = 'preview-carried-item';
  ghost.hidden = true;
  document.body.append(ghost);
  const marker = document.createElement('div');
  marker.className = 'placement-preview';
  const abort = new AbortController();
  const root = (id: ContainerId) => document.getElementById(id);
  const grid = (id: ContainerId) =>
    root(id)?.querySelector<HTMLElement>(
      id === 'storage' ? '.storage-grid' : '.inventory-grid',
    );
  const page = (id: ContainerId) =>
    [...(root(id)?.querySelectorAll('[role=tab]') ?? [])].findIndex(
      (tab) => tab.getAttribute('aria-selected') === 'true',
    );
  const available = () => root('storage')?.hidden === false;
  function cancel() {
    const old = carry;
    carry = null;
    target = null;
    if (old?.node.hasPointerCapture(old.pointer))
      old.node.releasePointerCapture(old.pointer);
    old?.node.classList.remove('carried');
    ghost.hidden = true;
    marker.remove();
  }
  function update(event: PointerEvent) {
    if (!carry) return;
    const scale = options.manager.scale;
    if (
      Math.hypot(event.clientX - carry.x, event.clientY - carry.y) >
      3 * scale
    )
      carry.moved = true;
    ghost.style.left = event.clientX - carry.offsetX * scale + 'px';
    ghost.style.top = event.clientY - carry.offsetY * scale + 'px';
    target = null;
    marker.remove();
    // Hit-testing includes clipping/scrolling and the active window's z-order.
    const hit = document
      .elementFromPoint(event.clientX, event.clientY)
      ?.closest<HTMLElement>('.ui-item-grid');
    for (const id of ['inventory', 'storage'] as const) {
      const element = grid(id);
      if (!element || element !== hit || root(id)?.hidden) continue;
      const rect = element.getBoundingClientRect();
      const cell = carriedCell(
        {
          x: (event.clientX - rect.left) / scale,
          y: (event.clientY - rect.top) / scale,
        },
        { x: carry.offsetX, y: carry.offsetY },
        40,
      );
      const valid = placement(
        { ...options.getState(id), items: [...options.getState(id).items] },
        carry.item,
        cell.x,
        cell.y,
        page(id),
      ).valid;
      target = { container: id, ...cell, page: page(id), valid };
      marker.className = 'placement-preview' + (valid ? '' : ' invalid');
      marker.style.left = cell.x * 40 + 'px';
      marker.style.top = cell.y * 40 + 'px';
      marker.style.height = carry.item.height * 40 + 'px';
      element.append(marker);
    }
  }
  function drop() {
    const old = carry,
      destination = target;
    cancel();
    if (old && destination?.valid)
      options.move(old.container, destination.container, old.item, destination);
  }
  document.addEventListener(
    'pointerdown',
    (event) => {
      if (event.button === 2 && carry) {
        event.preventDefault();
        event.stopImmediatePropagation();
        cancel();
        return;
      }
      if (event.button !== 0) return;
      if (
        carry &&
        event.target instanceof Element &&
        event.target.closest('.window-close, .titlebar')
      ) {
        cancel();
        return;
      }
      if (carry?.latched) {
        if (
          event.target instanceof Element &&
          event.target.closest('[role=tab]')
        ) {
          marker.remove();
          target = null;
          return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        update(event);
        drop();
        return;
      }
      if (!available() || !(event.target instanceof Element)) return;
      const node = event.target.closest<HTMLElement>('.ui-item-slot');
      const id = node?.closest('main')?.id;
      if (!node || (id !== 'inventory' && id !== 'storage')) return;
      const item = options
        .getState(id)
        .items.find((item) => item.id === node.dataset.id);
      if (!item) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      options.manager.activate(id);
      document
        .querySelectorAll<HTMLElement>('.ui-tooltip')
        .forEach((tip) => (tip.hidden = true));
      if (event.ctrlKey) {
        options.move(id, id === 'inventory' ? 'storage' : 'inventory', item);
        return;
      }
      const rect = node.getBoundingClientRect(),
        scale = options.manager.scale;
      carry = {
        container: id,
        item,
        node,
        pointer: event.pointerId,
        x: event.clientX,
        y: event.clientY,
        offsetX: (event.clientX - rect.left) / scale,
        offsetY: (event.clientY - rect.top) / scale,
        moved: false,
        latched: false,
      };
      node.setPointerCapture(event.pointerId);
      node.classList.add('carried');
      paintItemIcon(ghost, item, { resolveItemIcon: options.resolveItemIcon });
      ghost.style.width = 40 * scale + 'px';
      ghost.style.height = item.height * 40 * scale + 'px';
      ghost.hidden = false;
      update(event);
    },
    { capture: true, signal: abort.signal },
  );
  document.addEventListener(
    'pointermove',
    (event) => {
      if (!carry) return;
      event.stopImmediatePropagation();
      update(event);
    },
    { capture: true, signal: abort.signal },
  );
  document.addEventListener(
    'pointerup',
    (event) => {
      if (!carry || carry.latched || event.pointerId !== carry.pointer) return;
      event.stopImmediatePropagation();
      update(event);
      if (carry.moved) drop();
      else {
        carry.latched = true;
        if (carry.node.hasPointerCapture(carry.pointer))
          carry.node.releasePointerCapture(carry.pointer);
      }
    },
    { capture: true, signal: abort.signal },
  );
  document.addEventListener(
    'keydown',
    (event) => {
      if (event.key === 'Escape' && carry) {
        event.preventDefault();
        event.stopImmediatePropagation();
        cancel();
      }
    },
    { capture: true, signal: abort.signal },
  );
  document.addEventListener(
    'lostpointercapture',
    (event) => {
      if (carry && !carry.latched && event.pointerId === carry.pointer)
        cancel();
    },
    { signal: abort.signal },
  );
  window.addEventListener('blur', cancel, { signal: abort.signal });
  window.addEventListener('resize', cancel, { signal: abort.signal });
  document.addEventListener(
    'contextmenu',
    (event) => {
      if (carry) event.preventDefault();
    },
    { signal: abort.signal },
  );
  return {
    cancel,
    dispose() {
      cancel();
      abort.abort();
      ghost.remove();
    },
  };
}
