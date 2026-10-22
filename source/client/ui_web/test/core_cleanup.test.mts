import { mountExchange } from '../web/screens/market/exchange-view.js';
import { MAX_STATE_BYTES, MAX_BYTES } from '../web/protocol.js';
import { transfer } from '../web/screens/storage/transfer.js';
import { mountStorage } from '../web/screens/storage/storage-view.js';
import { mountMarket } from '../web/screens/market/market-view.js';
import { ItemDragRuntime } from '../web/game-ui/drag/item-drag-runtime.js';
import { mountMarketBrowser } from '../web/screens/market/browser-view.js';
import type { StorageSnapshot } from '../web/protocol/contracts.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import { UiWindow } from '../web/core/window/ui-window.js';
import { updateGameViews } from '../web/inventory/domain-updates.js';
import { mountInventory } from '../web/screens/inventory/inventory-view.js';
import { mountEquipment } from '../web/screens/equipment/equipment-view.js';
import { DomainStore } from '../web/store.js';
import {
  decode,
  isStateMessage,
  encode,
  readDomainSnapshot,
} from '../web/protocol.js';
import type { DomainSnapshot, StateType } from '../web/protocol/contracts.js';
import { mountStorageFixture } from './storage.fixture.mjs';
import {
  environment,
  target,
  measure,
  capture,
  fire,
  bagItem,
  equippedItem,
} from './fixtures.mjs';
import { element as findElement } from '../web/core/dom.js';

test('manager state is read-only and disposal is terminal for public operations and live handles', () => {
  const { manager, host } = environment(),
    element = target();
  const handle = manager.register({ id: 'one', element });
  assert.equal(manager.activeWindowId, null); // Registration does not activate.
  assert.equal(Reflect.set(manager, 'scale', 5), false);
  assert.equal(
    Reflect.set(manager, 'viewport', { width: 1, height: 1 }),
    false,
  );
  assert.equal(Reflect.set(manager, 'activeWindowId', 'other'), false);
  assert.equal(Reflect.set(manager.viewport, 'width', 1), false);
  assert.equal(Reflect.has(manager, 'windows'), false);
  assert.equal(manager.has('one'), true);
  handle.onLayoutChanged(() =>
    assert.throws(
      () => manager.register({ id: 'reentrant', element }),
      /Disposed WindowManager/,
    ),
  );
  manager.dispose();
  manager.dispose();
  handle.dispose();
  assert.equal(manager.disposed, true);
  assert.equal(manager.registeredCount, 0);
  assert.equal(manager.activeWindowId, null);
  for (const operation of [
    () => manager.register({ id: 'new', element }),
    () => manager.unregister('one'),
    () => manager.activate('one'),
    () => manager.refresh('one'),
    () => manager.refreshAll(),
    () => manager.setScale(1),
    () => manager.setViewport(manager.viewport),
    () => manager.place('one'),
    () => manager.move('one', { x: 0, y: 0 }),
    () => handle.activate(),
    () => handle.place(),
    () => handle.move({ x: 0, y: 0 }),
    () => handle.resetPosition(),
    () => handle.refresh(),
    () => handle.onActivate(() => {}),
    () => handle.onLayoutChanged(() => {}),
  ])
    assert.throws(operation, /Disposed WindowManager/);
  host.dispatchEvent(new host.Event('resize'));
  assert.equal(manager.registeredCount, 0);
});

test('disposing the manager during captured drag cancels transients and permits shell cleanup', () => {
  const { doc, manager, frames } = environment(),
    root = target();
  doc.body.append(root);
  let cancellations = 0;
  const shell = new UiWindow(root, {
    id: 'drag',
    title: 'Drag',
    manager,
    onCancel: () => cancellations++,
  });
  measure(shell.panel);
  const header = findElement(root, '.window-header', 'header');
  capture(header);
  shell.refresh();
  fire(header, 'pointerdown');
  fire(doc, 'pointermove', 220, 160);
  assert.equal(header.hasPointerCapture(1), true);
  assert.equal(frames.size, 1);
  manager.dispose();
  assert.equal(header.hasPointerCapture(1), false);
  assert.equal(frames.size, 0);
  assert.equal(cancellations, 1);
  shell.dispose();
  shell.dispose();
  manager.dispose();
});

function gameViews() {
  const env = environment();
  const { manager, doc, host } = env;
  Object.assign(globalThis, {
    innerWidth: host.innerWidth,
    innerHeight: host.innerHeight,
    getComputedStyle: host.getComputedStyle.bind(host),
  });
  const inventoryRoot = target(),
    equipmentRoot = target();
  inventoryRoot.hidden = true;
  equipmentRoot.hidden = true;
  doc.body.append(inventoryRoot, equipmentRoot);
  const work = {
    inventory: 0,
    equipment: 0,
    wallet: 0,
    inventoryGeometry: 0,
    equipmentGeometry: 0,
    regions: 0,
  };
  const inventory = mountInventory(inventoryRoot, {
    manager,
    moveItem: async () => ({ ok: true }),
    onRegionsChanged: () => work.inventoryGeometry++,
  });
  const equipment = mountEquipment(equipmentRoot, {
    manager,
    unequipItem: async () => ({ ok: true }),
    onRegionsChanged: () => work.equipmentGeometry++,
  });
  measure(findElement(inventoryRoot, '.window', 'section'));
  measure(findElement(equipmentRoot, '.equipment-window', 'section'), 220, 300);
  const views = {
    manager,
    inventoryRoot,
    equipmentRoot,
    viewport: () => ({ width: host.innerWidth, height: host.innerHeight }),
    onRegionsChanged: () => work.regions++,
    inventory: {
      ...inventory,
      setState: ((state) => {
        work.inventory++;
        inventory.setState(state);
      }) satisfies typeof inventory.setState,
      setInfo: ((state) => {
        work.wallet++;
        inventory.setInfo(state);
      }) satisfies typeof inventory.setInfo,
    },
    equipment: {
      ...equipment,
      setState: ((state) => {
        work.equipment++;
        equipment.setState(state);
      }) satisfies typeof equipment.setState,
    },
  };
  const state: DomainSnapshot = {
    hud: { inventory_open: true, equipment_open: true, ui_scale: 1 },
    wallet: { balance: 1234 },
    inventory: { columns: 5, rows: 9, pages: 4, items: [bagItem] },
    equipment: { items: [equippedItem], stats: { attack: 10 } },
  };
  const update = (type: StateType, snapshot = state) =>
    updateGameViews(type, snapshot, views);
  const reset = () => {
    for (const key of [
      'inventory',
      'equipment',
      'wallet',
      'inventoryGeometry',
      'equipmentGeometry',
      'regions',
    ] as const)
      work[key] = 0;
  };
  const dispose = () => {
    inventory.dispose();
    equipment.dispose();
    manager.dispose();
    env.dom.window.close();
  };
  return { ...env, views, state, work, update, reset, dispose };
}

test('domain dispatch updates only relevant screens and avoids wallet/player layout work', () => {
  const { update, work, reset, dispose, views } = gameViews();
  try {
    update('ui.snapshot');
    assert.equal(work.inventory, 1);
    assert.equal(work.equipment, 1);
    assert.equal(work.wallet, 1);
    reset();
    const item = findElement(views.inventoryRoot, '.ui-item-slot', 'div');
    update('wallet.updated');
    assert.deepEqual(work, {
      inventory: 0,
      equipment: 0,
      wallet: 1,
      inventoryGeometry: 0,
      equipmentGeometry: 0,
      regions: 0,
    });
    assert.equal(
      findElement(views.inventoryRoot, '.ui-item-slot', 'div'),
      item,
    );
    reset();
    update('player.updated');
    assert.ok(Object.values(work).every((count) => count === 0));
    update('hud.updated');
    assert.ok(Object.values(work).every((count) => count === 0));
    update('inventory.updated');
    assert.equal(work.inventory, 1);
    assert.equal(work.wallet, 0);
    assert.equal(work.equipment, 0);
    assert.equal(work.equipmentGeometry, 0);
    assert.ok(work.inventoryGeometry > 0);
    reset();
    update('equipment.updated');
    assert.equal(work.equipment, 1);
    assert.equal(work.inventory, 0);
    assert.equal(work.wallet, 0);
    assert.equal(work.inventoryGeometry, 0);
    assert.ok(work.equipmentGeometry > 0);
  } finally {
    dispose();
  }
});

test('HUD open transitions activate and raise a window without rerendering domain content', () => {
  const { update, state, manager, views, work, reset, dispose } = gameViews();
  try {
    assert.equal(manager.activeWindowId, null);
    update('ui.snapshot');
    assert.equal(manager.activeWindowId, 'equipment');
    reset();
    update('hud.updated', {
      ...state,
      hud: { inventory_open: false, equipment_open: true },
    });
    update('hud.updated', state);
    assert.equal(manager.activeWindowId, 'inventory');
    const inventory = views.inventoryRoot,
      equipment = views.equipmentRoot;
    assert.ok(Number(inventory.style.zIndex) > Number(equipment.style.zIndex));
    update('hud.updated', {
      ...state,
      hud: { inventory_open: true, equipment_open: false },
    });
    update('hud.updated', state);
    assert.equal(manager.activeWindowId, 'equipment');
    assert.ok(Number(equipment.style.zIndex) > Number(inventory.style.zIndex));
    assert.equal(work.inventory, 0);
    assert.equal(work.equipment, 0);
    assert.equal(work.wallet, 0);
  } finally {
    dispose();
  }
});

test('malformed domain update leaves rendered items intact and valid wallet updates still render', () => {
  const { views, state, work, reset, dispose } = gameViews(),
    store = new DomainStore();
  const receive = (type: StateType, payload: object) => {
    const message = decode(encode(type, payload));
    if (!isStateMessage(message)) throw Error('Invalid test envelope');
    if (store.apply(message)) {
      const snapshot = readDomainSnapshot(store.state);
      assert.ok(snapshot);
      updateGameViews(type, snapshot, views);
    }
  };
  try {
    receive('ui.snapshot', state);
    reset();
    const item = findElement(views.inventoryRoot, '.ui-item-slot', 'div');
    receive('inventory.updated', { ...state.inventory, columns: 1000000000 });
    assert.ok(Object.values(work).every((count) => count === 0));
    receive('wallet.updated', { balance: 42 });
    assert.equal(work.wallet, 1);
    assert.equal(work.inventory, 0);
    assert.equal(work.equipment, 0);
    assert.equal(
      findElement(views.inventoryRoot, '.ui-item-slot', 'div'),
      item,
    );
    assert.match(
      findElement(views.inventoryRoot, '.wallet', 'footer').textContent ?? '',
      /42/,
    );
  } finally {
    dispose();
  }
});

test('Storage delegated tooltip hides on empty cells and can show again over an item', () => {
  const { doc, manager } = environment(),
    root = target();
  doc.body.append(root);
  const fixture = mountStorageFixture(root, {
    manager,
    resolveItemIcon: () => null,
    onClose: () => {},
    onItemAction: () => {},
    onRegionsChanged: () => {},
  });
  try {
    fixture.setState({
      columns: 4,
      rows: 5,
      items: [{ ...bagItem, x: 1, y: 1 }],
    });
    const item = findElement(root, '.ui-item-slot', 'div'),
      empty = findElement(root, '.cell', 'div'),
      tooltip = findElement(root, '.ui-tooltip', 'aside');
    fire(item, 'pointermove');
    assert.equal(tooltip.hidden, false);
    fire(empty, 'pointermove');
    assert.equal(tooltip.hidden, true);
    fire(item, 'pointermove');
    assert.equal(tooltip.hidden, false);
  } finally {
    fixture.dispose();
    manager.dispose();
  }
});

test('Storage owns two independent pages and composes item actions, tooltips and lifecycle', () => {
  const { doc, manager } = environment(),
    root = target();
  doc.body.append(root);
  const actions: string[] = [];
  let closes = 0;
  const view = mountStorage(root, {
    manager,
    resolveItemIcon: () => null,
    onClose: () => closes++,
    onItemAction: (_event, item) => actions.push(item.id),
  });
  const state: StorageSnapshot = {
    columns: 15,
    rows: 9,
    pages: 2,
    items: [
      { ...bagItem, id: 'page-one', x: 14, y: 6, page: 0 },
      { ...bagItem, id: 'page-two', x: 3, y: 2, page: 1 },
    ],
  };
  try {
    view.setState(state);
    const capacity = findElement(root, '.storage-capacity', 'p');
    const capacityText = capacity.textContent;
    view.setStatus('Transfer rejected: full');
    assert.equal(
      findElement(root, '.storage-status', 'p').textContent,
      'Transfer rejected: full',
    );
    assert.equal(capacity.textContent, capacityText);
    view.setStatus('');
    assert.equal(findElement(root, '.storage-status', 'p').hidden, true);
    assert.equal(capacity.textContent, capacityText);
    assert.equal(root.querySelectorAll('.cell').length, 135);
    const first = findElement(root, '.ui-item-slot', 'div');
    assert.equal(first.dataset.id, 'page-one');
    fire(first, 'pointermove');
    const tooltip = findElement(root, '.ui-tooltip', 'aside');
    assert.equal(tooltip.hidden, false);
    fire(findElement(root, '.cell', 'div'), 'pointermove');
    assert.equal(tooltip.hidden, true);
    fire(first, 'pointerdown');
    assert.deepEqual(actions, ['page-one']);
    const tabs = root.querySelectorAll<HTMLButtonElement>('[role=tab]');
    assert.equal(tabs.length, 2);
    tabs[1]?.click();
    assert.equal(tooltip.hidden, true);
    assert.equal(tabs[1]?.getAttribute('aria-selected'), 'true');
    const second = findElement(root, '.ui-item-slot', 'div');
    assert.equal(second.dataset.id, 'page-two');
    fire(second, 'pointerdown');
    assert.deepEqual(actions, ['page-one', 'page-two']);
    view.setState({ ...state, items: [] });
    assert.equal(root.querySelector('.ui-item-slot'), null);
    assert.equal(root.querySelectorAll('.cell').length, 135);
    findElement(root, '.window-close', 'button').click();
    assert.equal(closes, 1);
    view.dispose();
    view.dispose();
    assert.equal(manager.has('storage'), false);
    first.click();
    assert.equal(actions.length, 2);
  } finally {
    view.dispose();
    manager.dispose();
  }
});

test('Storage transfers preserve footprints and reject stale, full and occupied targets without mutating state', () => {
  const item = { ...bagItem, id: 'source', x: 0, y: 0, page: 0, revision: 4 };
  const source = { columns: 5, rows: 9, pages: 4, items: [item] };
  const occupied = { ...item, id: 'occupied', x: 0, y: 0, page: 0 };
  const destination = { columns: 15, rows: 9, pages: 2, items: [occupied] };
  const original = structuredClone({ source, destination });
  assert.equal(transfer(source, destination, item.id, 3), null);
  assert.equal(
    transfer(source, destination, item.id, 4, { x: 0, y: 1, page: 0 }),
    null,
  );
  assert.equal(
    transfer(source, destination, item.id, 4, { x: 14, y: 8, page: 0 }),
    null,
  );
  const moved = transfer(source, destination, item.id, 4);
  assert.ok(moved);
  assert.equal(moved.sourceItems.length, 0);
  assert.deepEqual(moved.destinationItems.at(-1), {
    ...item,
    x: 1,
    y: 0,
    revision: 5,
  });
  assert.deepEqual({ source, destination }, original);
  const full = {
    columns: 1,
    rows: 3,
    pages: 2,
    items: [occupied, { ...occupied, id: 'second', page: 1 }],
  };
  assert.equal(transfer(source, full, item.id, 4), null);
  const secondPage = transfer(
    source,
    { ...full, items: [occupied] },
    item.id,
    4,
  );
  assert.equal(secondPage?.destinationItems.at(-1)?.page, 1);
  const target = { x: 2, y: 2, page: 3, container: 'inventory', valid: true };
  const same = transfer(source, source, item.id, 4, target);
  assert.equal(same?.destinationItems.length, 1);
  assert.equal(same?.destinationItems[0]?.page, 3);
  assert.equal(
    Object.hasOwn(same?.destinationItems[0] ?? {}, 'container'),
    false,
  );
  assert.equal(Object.hasOwn(same?.destinationItems[0] ?? {}, 'valid'), false);
});

test('Storage IPC validates its capacity independently and large valid snapshots keep commands bounded', () => {
  const store = new DomainStore();
  const item = { ...bagItem, height: 1, x: 14, y: 8, page: 1 };
  const state = { columns: 15, rows: 9, pages: 2, items: [item] };
  assert.equal(
    store.apply({ v: 1, type: 'storage.updated', payload: state }),
    true,
  );
  for (const value of [NaN, Infinity, -1, 15, 1.5])
    assert.equal(
      store.apply({
        v: 1,
        type: 'storage.updated',
        payload: { ...state, items: [{ ...item, x: value }] },
      }),
      false,
    );
  assert.deepEqual(store.state.storage, state);
  assert.equal(
    store.apply({ v: 1, type: 'wallet.updated', payload: { balance: 17 } }),
    true,
  );
  const items = Array.from({ length: 270 }, (_, i) => ({
    ...item,
    id: String(i),
    x: i % 15,
    y: Math.floor(i / 15) % 9,
    page: Math.floor(i / 135),
  }));
  assert.ok(encode('storage.updated', { ...state, items }).length > MAX_BYTES);
  assert.throws(() =>
    encode('command.result', { ok: true, error: 'x'.repeat(MAX_BYTES) }, 'big'),
  );
  assert.throws(() =>
    encode('storage.updated', { text: 'x'.repeat(MAX_STATE_BYTES) }),
  );
});

test('HUD cannot open Storage without Inventory and preserves last valid lifecycle', () => {
  const store = new DomainStore();
  const valid = { storage_open: true, inventory_open: true };
  assert.equal(
    store.apply({ v: 1, type: 'hud.updated', payload: valid }),
    true,
  );
  for (const payload of [
    { storage_open: true, inventory_open: false },
    { storage_open: true },
  ]) {
    assert.equal(store.apply({ v: 1, type: 'hud.updated', payload }), false);
    assert.deepEqual(store.state.hud, valid);
  }
  assert.equal(
    store.apply({
      v: 1,
      type: 'hud.updated',
      payload: { storage_open: false, inventory_open: false },
    }),
    true,
  );
});

test('Inventory right-click activates only UID/revision and preserves items on rejection', async () => {
  const { doc, host, manager } = environment();
  const root = target();
  doc.body.append(root);
  const commands: unknown[] = [];
  const view = mountInventory(root, {
    manager,
    moveItem: async () => ({ ok: true }),
    activateItem: async (command) => {
      commands.push(command);
      return { ok: false, error: 'no_action' };
    },
  });
  try {
    view.setState({
      inventory: { columns: 5, rows: 9, pages: 4, items: [bagItem] },
    });
    findElement(root, '.inventory-item', 'div').dispatchEvent(
      new host.MouseEvent('pointerdown', { button: 2, bubbles: true }),
    );
    assert.equal(
      root.querySelector('.inventory-status')?.textContent,
      'Activating…',
    );
    await Promise.resolve();
    assert.deepEqual(commands, [
      { id: bagItem.id, revision: bagItem.revision },
    ]);
    assert.equal(
      root.querySelector('.inventory-status')?.textContent,
      'Activation rejected: no_action',
    );
    assert.equal(
      root.querySelector('.inventory-item')?.getAttribute('data-id'),
      bagItem.id,
    );
  } finally {
    view.dispose();
    manager.dispose();
  }
});

test('Inventory retry confirms a saved action from current revision without dragging or executing again', async () => {
  const { doc, host, manager } = environment(),
    root = target();
  doc.body.append(root);
  let retries = 0,
    mutations = 0,
    closes = 0;
  const current = { ...bagItem, revision: bagItem.revision + 1 };
  const snapshot = {
    columns: 5,
    rows: 9,
    pages: 4,
    items: [current],
    recoveryPending: true,
  };
  const view = mountInventory(root, {
    manager,
    onClose: () => closes++,
    moveItem: async () => {
      mutations++;
      return { ok: true };
    },
    activateItem: async () => {
      mutations++;
      view.setState({ inventory: snapshot });
      return { ok: false, error: 'inventory_pending' };
    },
    retry: async () => {
      retries++;
      return { ok: true };
    },
  });
  view.setState({ inventory: { ...snapshot, recoveryPending: false } });
  findElement(root, '.inventory-item', 'div').dispatchEvent(
    new host.MouseEvent('pointerdown', { button: 2, bubbles: true }),
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  findElement(root, '.inventory-item', 'div').dispatchEvent(
    new host.MouseEvent('pointerdown', { button: 2, bubbles: true }),
  );
  assert.equal(
    mutations,
    1,
    'New inventory activation waits for unresolved intent',
  );
  const retry = Array.from(
    root.querySelectorAll<HTMLButtonElement>('button'),
  ).find((n) => n.textContent === 'Retry inventory action')!;
  assert.equal(retry.hidden, false);
  assert.equal(
    retry.disabled,
    false,
    'timeout must release the Inventory retry control',
  );
  retry.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(retries, 1);
  assert.equal(
    mutations,
    1,
    'Retry uses no new item/revision/placement payload',
  );
  view.cancelOrClose();
  assert.equal(closes, 1, 'Close remains presentation only');
  view.setState({ inventory: { ...snapshot, recoveryPending: false } });
  assert.equal(retry.hidden, true);
  const store = new DomainStore();
  assert.equal(
    store.apply({ v: 1, type: 'inventory.updated', payload: snapshot }),
    true,
  );
  assert.equal(
    store.apply({
      v: 1,
      type: 'inventory.updated',
      payload: { ...snapshot, recoveryPending: 'yes' },
    }),
    false,
  );
  view.dispose();
  manager.dispose();
  host.close();
});

test('Storage retry remains available after the original item left shared storage', async () => {
  const { doc, host, manager } = environment(),
    root = target();
  doc.body.append(root);
  let retries = 0,
    mutations = 0,
    closes = 0;
  const snapshot: StorageSnapshot = {
    columns: 15,
    rows: 9,
    pages: 2,
    items: [],
    recoveryPending: true,
  };
  const view = mountStorage(root, {
    manager,
    resolveItemIcon: () => '',
    onClose: () => closes++,
    transfer: async () => {
      mutations++;
      view.setState(snapshot);
      return { ok: false, error: 'storage_pending' };
    },
    retry: async () => {
      retries++;
      return { ok: true };
    },
  });
  view.setState({ ...snapshot, recoveryPending: false });
  await view.receiveFromInventory(bagItem);
  const retry = Array.from(
    root.querySelectorAll<HTMLButtonElement>('button'),
  ).find((n) => n.textContent === 'Retry Storage action')!;
  assert.equal(retry.hidden, false);
  assert.equal(
    retry.disabled,
    false,
    'timeout result releases the Retry control after pending state arrived',
  );
  assert.equal(
    view.tryQuickDeposit(bagItem),
    null,
    'unresolved transfer blocks a new intention',
  );
  retry.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(retries, 1);
  assert.equal(
    mutations,
    1,
    'retry never needs an item or free destination in the current snapshot',
  );
  findElement(root, '[aria-label="Close storage"]', 'button').click();
  assert.equal(closes, 1, 'closing presentation does not clear pending intent');
  view.setState({ ...snapshot, recoveryPending: false });
  assert.equal(retry.hidden, true);
  const store = new DomainStore();
  assert.equal(
    store.apply({ v: 1, type: 'storage.updated', payload: { ...snapshot } }),
    true,
  );
  assert.equal(
    store.apply({
      v: 1,
      type: 'storage.updated',
      payload: { ...snapshot, recoveryPending: 'yes' },
    }),
    false,
  );
  view.dispose();
  manager.dispose();
  host.close();
});

test('Trading Glass keeps one unresolved purchase ID across selection changes and closed visitor windows', async () => {
  const { host, doc, manager } = environment();
  Object.assign(globalThis, {
    HTMLElement: host.HTMLElement,
    HTMLInputElement: host.HTMLInputElement,
    Option: host.Option,
  });
  const root = target();
  const shopRoot = target();
  root.hidden = true;
  shopRoot.hidden = true;
  doc.body.append(root, shopRoot);

  const first = 'a'.repeat(32);
  const second = 'b'.repeat(32);
  const item = (id: string, x: number) => ({
    ...bagItem,
    id,
    revision: 0,
    x,
    y: 0,
    page: 0,
    height: 2,
    quantity: 1,
  });
  const offers = [
    { id: first, revision: 0, price: 100, item: item(first, 0) },
    { id: second, revision: 0, price: 200, item: item(second, 2) },
  ];
  const shop = {
    active: true as const,
    shopId: 42,
    name: 'Test merchant',
    status: 'active' as const,
    revision: 0,
    columns: 5 as const,
    rows: 8 as const,
    offers,
    claims: [],
  };
  const sent: Array<Record<string, unknown>> = [];
  const view = mountMarketBrowser(root, shopRoot, {
    manager,
    resolveItemIcon: () => '',
    catalog: async () => ({ ok: true }),
    search: async () => ({ ok: true }),
    visit: async () => ({ ok: true }),
    buy: async (intent) => {
      sent.push({ ...intent });
      return sent.length === 1 ? { ok: false, error: 'timeout' } : { ok: true };
    },
    close: () => {},
    regions: () => {},
  });
  const snapshot = (activeShop: typeof shop | Record<string, never>) => ({
    active: true as const,
    catalog: [],
    stats: {},
    results: [],
    cursor: '',
    shop: activeShop,
    highlight: first,
    error: '',
  });
  view.setState(snapshot(shop));
  shopRoot.querySelector<HTMLElement>('[data-id="' + first + '"]')!.click();
  const buy = Array.from(
    shopRoot.querySelectorAll<HTMLButtonElement>('button'),
  ).find((node) => node.textContent === 'Buy selected item')!;
  assert.equal(buy.disabled, false);
  buy.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(sent.length, 1);
  const command = { ...sent[0] };

  shopRoot.querySelector<HTMLElement>('[data-id="' + second + '"]')!.click();
  assert.equal(buy.disabled, true, 'an unknown buy locks other offers');
  buy.click();
  assert.equal(sent.length, 1, 'a second buy cannot overwrite the original ID');

  // The seller shop may close or disappear while the result remains unknown.
  view.setState(snapshot({}));
  assert.equal(shopRoot.hidden, true);
  const retry = Array.from(
    root.querySelectorAll<HTMLButtonElement>('button'),
  ).find((node) => node.textContent === 'Retry same purchase')!;
  assert.equal(retry.hidden, false, 'Retry stays in Trading Glass');
  retry.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(
    sent[1],
    command,
    'retry replays exactly the first purchase',
  );
  assert.equal(retry.hidden, true);

  view.setState(snapshot(shop));
  shopRoot.querySelector<HTMLElement>('[data-id="' + second + '"]')!.click();
  assert.equal(buy.disabled, false);
  buy.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(sent.length, 3);
  assert.notEqual(
    sent[2]!.command_id,
    command.command_id,
    'a new ID only after resolution',
  );

  view.dispose();
  manager.dispose();
  host.close();
});

test('restored seller intent retries from native journal without an old item or browser command body', async () => {
  const { manager } = environment();
  manager.register({ id: 'inventory', element: target() });
  const root = target();
  const drag = new ItemDragRuntime({
    scale: () => 1,
    onRegionsChanged: () => {},
  });
  let executions = 0,
    retries = 0;
  const view = mountMarket(root, {
    manager,
    drag,
    resolveItemIcon: () => '',
    command: async () => {
      executions++;
      return { ok: true };
    },
    retrySeller: async () => {
      retries++;
      return retries === 1
        ? { ok: false, error: 'seller_pending' }
        : { ok: true };
    },
    onClose: () => {},
    onRegionsChanged: () => {},
  });
  const state = {
    active: true as const,
    shopId: 1,
    name: 'Seller',
    status: 'active' as const,
    revision: 0,
    columns: 5 as const,
    rows: 8 as const,
    offers: [],
    claims: [],
    sellerPending: true,
    sellerBusy: false,
  };
  view.setState(state);
  const retry = [...root.querySelectorAll('button')].find(
    (b) => b.textContent === 'Retry same command',
  )!;
  assert.equal(retry.hidden, false);
  retry.click();
  retry.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(retries, 1);
  assert.equal(retry.disabled, false);
  assert.equal(retry.hidden, false);
  retry.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(retries, 2);
  assert.equal(executions, 0);
  assert.equal(retry.hidden, true);
  view.setState({ ...state, sellerPending: false });
  assert.equal(retry.hidden, true);
  view.dispose();
  drag.dispose();
  manager.dispose();
});

test('restored purchase retries via native journal after the offer disappeared', async () => {
  const { manager, host } = environment();
  Object.assign(globalThis, { Option: host.Option });
  const root = target(),
    shopRoot = target();
  let calls = 0,
    sends = 0;
  const view = mountMarketBrowser(root, shopRoot, {
    manager,
    resolveItemIcon: () => '',
    catalog: async () => ({ ok: true }),
    search: async () => ({ ok: true }),
    visit: async () => ({ ok: true }),
    buy: async () => {
      sends++;
      return { ok: true };
    },
    retryPurchase: async () => {
      calls++;
      return { ok: true };
    },
    close: () => {},
    regions: () => {},
  });
  view.setState({
    active: true,
    catalog: [],
    stats: {},
    results: [],
    cursor: '',
    shop: {},
    highlight: '',
    error: '',
    purchasePending: true,
    purchaseBusy: false,
  });
  const retry = [...root.querySelectorAll('button')].find(
    (b) => b.textContent === 'Retry same purchase',
  )!;
  assert.equal(retry.hidden, false);
  retry.click();
  retry.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls, 1);
  assert.equal(sends, 0);
  view.setState({
    active: true,
    catalog: [],
    stats: {},
    results: [],
    cursor: '',
    shop: {},
    highlight: '',
    error: '',
    purchasePending: false,
  });
  assert.equal(retry.hidden, true);
  view.dispose();
  manager.dispose();
  host.close();
});

test('Exchange ledger mode keeps native Retry available without a source stack and disables trading', async () => {
  const { manager, host } = environment();
  Object.assign(globalThis, { Option: host.Option });
  const root = target();
  const drag = new ItemDragRuntime({
    scale: () => 1,
    onRegionsChanged: () => {},
  });
  let retries = 0,
    commands = 0;
  const view = mountExchange(root, {
    manager,
    drag,
    command: async () => {
      commands++;
      return { ok: true };
    },
    retry: async () => {
      retries++;
      return { ok: true };
    },
    close: () => {},
    regions: () => {},
  });
  const state = {
    active: true as const,
    yang: 1500,
    reservedYang: 0,
    assets: [
      {
        asset_id: 'upgrade_ore',
        name: 'Ore',
        stack_limit: 200,
        free: 2,
        reserved: 0,
      },
    ],
    orders: [],
    depth: [],
    fills: [],
    busy: false,
    retryAvailable: true,
    ledgerOnly: true,
  };
  view.setState(state);
  const buttons = [...root.querySelectorAll('button')];
  const retry = buttons.find((b) => b.textContent === 'Retry same command')!;
  assert.equal(retry.hidden, false);
  assert.equal(
    buttons.find((b) => b.textContent === 'Place limit order')!.disabled,
    true,
  );
  assert.equal(
    buttons.find((b) => b.textContent === 'Deposit')!.disabled,
    true,
  );
  retry.click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(retries, 1);
  assert.equal(commands, 0);
  view.setState({ ...state, retryAvailable: false });
  assert.equal(retry.hidden, true);
  assert.equal(
    buttons.find((b) => b.textContent === 'Withdraw')!.disabled,
    false,
  );
  view.dispose();
  drag.dispose();
  manager.dispose();
  host.close();
});
