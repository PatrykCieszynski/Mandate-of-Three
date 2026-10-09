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
