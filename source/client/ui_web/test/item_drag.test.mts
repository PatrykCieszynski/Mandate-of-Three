import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ItemDragRuntime } from '../web/game-ui/drag/item-drag-runtime.js';
import { mountInventory } from '../web/screens/inventory/inventory-view.js';
import { mountStorage } from '../web/screens/storage/storage-view.js';
import { mountEquipment } from '../web/screens/equipment/equipment-view.js';
import type { ItemDragPayload } from '../web/game-ui/drag/item-drag-types.js';
import type { StorageTransferCommand } from '../web/protocol/contracts.js';
import {
  environment,
  capture,
  target,
  bagItem,
  equippedItem,
} from './fixtures.mjs';
function fixture() {
  const env = environment();
  Object.assign(globalThis, {
    HTMLElement: env.host.HTMLElement,
    getComputedStyle: env.host.getComputedStyle.bind(env.host),
  });
  let hit: Element | null = null,
    scale = 1,
    reports = 0;
  Object.defineProperty(env.doc, 'elementFromPoint', {
    configurable: true,
    value: () => hit,
  });
  const runtime = new ItemDragRuntime({
    scale: () => scale,
    onRegionsChanged: () => reports++,
  });
  const node = target();
  env.doc.body.append(node);
  capture(node);
  const payload: ItemDragPayload = {
    sourceId: 'catalog-offer',
    subject: Object.freeze({ offer: 'opaque-offer' }),
    presentation: {
      width: 38,
      height: 78,
      render: (ghost) => {
        ghost.textContent = 'Offer';
      },
    },
  };
  function pointer(
    element: EventTarget,
    type: string,
    x = 10,
    y = 10,
    button = 0,
    id = 7,
    ctrlKey = false,
  ) {
    const event = new env.host.MouseEvent(type, {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      button,
      ctrlKey,
    });
    Object.defineProperty(event, 'pointerId', { value: id });
    element.dispatchEvent(event);
  }
  return {
    ...env,
    runtime,
    node,
    payload,
    pointer,
    setHit: (element: Element | null) => {
      hit = element;
    },
    setScale: (value: number) => {
      scale = value;
    },
    reports: () => reports,
  };
}
const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
test('opaque offer and target data support click carry, threshold drag and preview lifecycle', async () => {
  const f = fixture();
  const surface = target();
  f.doc.body.append(surface);
  const subjects: unknown[] = [],
    data = { offerQuantity: 2 };
  let drops = 0;
  f.runtime.registerSource({ element: f.node, payload: () => f.payload });
  f.runtime.registerTarget({
    element: surface,
    preview: (payload, pointer) => {
      subjects.push(payload.subject);
      assert.deepEqual(pointer.grabOffset, { x: 10, y: 10 });
      const marker = f.doc.createElement('div');
      marker.className = 'test-preview';
      return {
        valid: true,
        data,
        visual: { element: marker, parent: surface },
      };
    },
    drop: (payload, preview) => {
      assert.equal(payload, f.payload);
      assert.equal(preview.data, data);
      drops++;
    },
  });
  try {
    f.pointer(f.node, 'pointerdown');
    assert.equal(f.node.hasPointerCapture(7), true);
    f.pointer(f.node, 'pointerup');
    assert.equal(f.runtime.latched, true);
    assert.equal(f.node.hasPointerCapture(7), false);
    f.setHit(surface);
    f.pointer(f.doc, 'pointermove', 100, 100);
    assert.equal(surface.querySelectorAll('.test-preview').length, 1);
    f.pointer(f.doc, 'pointermove', 120, 100);
    assert.equal(surface.querySelectorAll('.test-preview').length, 1);
    f.pointer(surface, 'pointerdown', 120, 100);
    await flush();
    assert.equal(drops, 1);
    assert.equal(f.runtime.active, false);
    assert.equal(surface.childElementCount, 0);
    f.pointer(f.node, 'pointerdown');
    f.pointer(f.doc, 'pointermove', 100, 100);
    f.pointer(f.node, 'pointerup', 100, 100);
    await flush();
    assert.equal(drops, 2);
    assert.ok(subjects.every((subject) => subject === f.payload.subject));
    assert.ok(f.reports() >= 4);
  } finally {
    f.runtime.dispose();
    f.manager.dispose();
  }
});
test('single session, pending drop and right-click cancellation never start a second carry', async () => {
  const f = fixture(),
    second = target();
  f.doc.body.append(second);
  capture(second);
  let starts = 0,
    activations = 0,
    drops = 0;
  let finish: (() => void) | undefined;
  for (const element of [f.node, second])
    f.runtime.registerSource({
      element,
      payload: () => {
        starts++;
        return f.payload;
      },
    });
  second.addEventListener('pointerdown', () => activations++);
  f.runtime.registerTarget({
    element: second,
    preview: () => ({ valid: true, data: 17 }),
    drop: () => {
      drops++;
      return new Promise<void>((resolve) => {
        finish = resolve;
      });
    },
  });
  try {
    f.pointer(f.node, 'pointerdown');
    f.pointer(f.node, 'pointerup');
    f.pointer(second, 'pointerdown', 10, 10, 2);
    assert.equal(activations, 0);
    assert.equal(f.runtime.active, false);
    assert.equal(starts, 1);
    f.pointer(f.node, 'pointerdown');
    f.pointer(second, 'pointerdown', 10, 10, 0, 8);
    assert.equal(starts, 2);
    f.setHit(second);
    f.pointer(f.node, 'pointerup', 80, 80);
    await flush();
    assert.equal(drops, 1);
    f.pointer(f.node, 'pointerdown');
    assert.equal(starts, 2);
    assert.equal(f.runtime.active, false);
    finish?.();
    await flush();
    f.pointer(f.node, 'pointerdown');
    assert.equal(starts, 3);
  } finally {
    finish?.();
    f.runtime.dispose();
    f.manager.dispose();
  }
});
test('Escape, blur, resize, pointer cancel and scale change clean capture and previews', () => {
  const f = fixture();
  f.runtime.registerSource({ element: f.node, payload: () => f.payload });
  try {
    for (const event of [
      'Escape',
      'blur',
      'resize',
      'pointercancel',
      'scale',
    ]) {
      f.setScale(1);
      f.pointer(f.node, 'pointerdown');
      if (event === 'Escape')
        f.doc.dispatchEvent(
          new f.host.KeyboardEvent('keydown', {
            key: 'Escape',
            bubbles: true,
            cancelable: true,
          }),
        );
      else if (event === 'scale') {
        f.setScale(1.25);
        f.pointer(f.doc, 'pointermove', 100, 100);
      } else
        (event === 'pointercancel' ? f.doc : f.host).dispatchEvent(
          new f.host.Event(event, { bubbles: true }),
        );
      assert.equal(f.runtime.active, false, event);
      assert.equal(f.node.hasPointerCapture(7), false, event);
      assert.equal(
        f.doc.querySelector<HTMLElement>('.carried-item')?.hidden,
        true,
        event,
      );
    }
    f.setScale(1.25);
    f.pointer(f.node, 'pointerdown', 25, 50);
    f.pointer(f.doc, 'pointermove', 100, 150, 0, 99);
    assert.equal(
      f.doc.querySelector<HTMLElement>('.carried-item')?.style.left,
      '0px',
    );
    f.pointer(f.doc, 'pointermove', 100, 150);
    assert.equal(
      f.doc.querySelector<HTMLElement>('.carried-item')?.style.left,
      '75px',
    );
    assert.equal(
      f.doc.querySelector<HTMLElement>('.carried-item')?.style.transform,
      'scale(1.25)',
    );
  } finally {
    f.runtime.dispose();
    f.manager.dispose();
  }
});
test('unregister and stale DOM cleanup release references; dispose is idempotent and terminal', () => {
  const f = fixture();
  const source = f.runtime.registerSource({
    element: f.node,
    payload: () => f.payload,
  });
  const destination = target();
  f.doc.body.append(destination);
  const marker = f.doc.createElement('div');
  const targetHandle = f.runtime.registerTarget({
    element: destination,
    preview: () => ({
      valid: false,
      data: null,
      visual: { element: marker, parent: destination },
    }),
    drop: () => assert.fail('invalid drop'),
  });
  try {
    f.setHit(destination);
    f.pointer(f.node, 'pointerdown');
    assert.equal(marker.isConnected, true);
    targetHandle.dispose();
    targetHandle.dispose();
    assert.equal(marker.isConnected, false);
    source.dispose();
    source.dispose();
    assert.equal(f.runtime.active, false);
    assert.equal(f.runtime.registrationCount, 0);
    f.runtime.registerSource({ element: f.node, payload: () => f.payload });
    f.pointer(f.node, 'pointerdown');
    f.node.remove();
    assert.equal(f.runtime.registrationCount, 0);
    assert.equal(f.runtime.active, false);
    f.runtime.registerTarget({
      element: destination,
      preview: () => ({ valid: true, data: null }),
      drop: () => {},
    });
    destination.remove();
    assert.equal(f.runtime.registrationCount, 0);
    f.runtime.dispose();
    f.runtime.dispose();
    assert.equal(f.doc.querySelector('.carried-item'), null);
    assert.throws(
      () =>
        f.runtime.registerSource({ element: f.node, payload: () => f.payload }),
      /Disposed/,
    );
  } finally {
    f.runtime.dispose();
    f.manager.dispose();
  }
});
test('page repaint detaches a latched source without retaining DOM or cancelling its opaque payload', () => {
  const f = fixture();
  const handle = f.runtime.registerSource({
    element: f.node,
    payload: () => f.payload,
  });
  f.pointer(f.node, 'pointerdown');
  f.pointer(f.node, 'pointerup');
  handle.dispose();
  f.node.remove();
  assert.equal(f.runtime.active, true);
  assert.equal(f.runtime.registrationCount, 0);
  f.runtime.cancel();
  f.runtime.dispose();
  f.manager.dispose();
});
test('production policies preserve exact routes, quick receive, slot drops and rejection authority', async () => {
  const f = fixture(),
    invRoot = target(),
    storageRoot = target(),
    equipmentRoot = target();
  f.doc.body.append(invRoot, storageRoot, equipmentRoot);
  const commands: { type: string; payload: unknown }[] = [];
  const result = async (type: string, payload: unknown) => {
    commands.push({ type, payload });
    return { ok: false, error: 'test_rejected' };
  };
  const storage = mountStorage(storageRoot, {
    manager: f.manager,
    drag: f.runtime,
    resolveItemIcon: () => null,
    onClose: () => {},
    transfer: (command) => result('storage.transfer', command),
  });
  const equipment = mountEquipment(equipmentRoot, {
    manager: f.manager,
    drag: f.runtime,
    unequipItem: (command) => result('equipment.unequip', command),
    equipItem: (command) => result('equipment.equip', command),
  });
  const inventory = mountInventory(invRoot, {
    manager: f.manager,
    drag: f.runtime,
    moveItem: (command) => result('inventory.move_item', command),
    activateItem: (command) => result('item.activate', command),
    quickDeposit: (item) => storage.receiveFromInventory(item),
    withdrawItem: (item, position) =>
      storage.withdrawToInventory(item, position),
    receiveEquipped: (item) => equipment.unequip(item),
  });
  const invGrid = invRoot.querySelector<HTMLElement>('.inventory-grid'),
    storageGrid = storageRoot.querySelector<HTMLElement>('.storage-grid');
  assert.ok(invGrid);
  assert.ok(storageGrid);
  invGrid.style.setProperty('--slot-size', '40px');
  const stored = { ...bagItem, id: 'stored-item', revision: 5 };
  const reset = () => {
    inventory.setState({
      inventory: { columns: 5, rows: 9, pages: 4, items: [bagItem] },
    });
    storage.setState({ columns: 15, rows: 9, pages: 2, items: [stored] });
    equipment.setState({
      equipment: { items: [equippedItem], stats: { attack: 10 } },
    });
  };
  reset();
  const item = (root: HTMLElement, id: string) => {
    const element = root.querySelector<HTMLElement>(`[data-id="${id}"]`);
    assert.ok(element);
    capture(element);
    return element;
  };
  const weapon = equipmentRoot.querySelector<HTMLElement>('[data-slot=weapon]');
  assert.ok(weapon);
  async function drop(
    source: HTMLElement,
    target: HTMLElement,
    x = 90,
    y = 130,
    valid = true,
  ) {
    f.setHit(null);
    f.pointer(source, 'pointerdown');
    f.setHit(target);
    f.pointer(f.doc, 'pointermove', x, y);
    assert.equal(
      target
        .querySelector('.placement-preview, .item-drop-highlight')
        ?.classList.contains('invalid'),
      !valid,
    );
    f.pointer(source, 'pointerup', x, y);
    await flush();
  }
  try {
    await drop(item(invRoot, bagItem.id), invGrid);
    assert.deepEqual(commands.pop(), {
      type: 'inventory.move_item',
      payload: { id: bagItem.id, revision: 3, x: 2, y: 3, page: 0 },
    });
    assert.match(
      invRoot.querySelector('[role=status]')?.textContent ?? '',
      /Move rejected/,
    );
    assert.ok(item(invRoot, bagItem.id)); // Result alone cannot replace domain state.
    await drop(item(invRoot, bagItem.id), storageGrid);
    assert.deepEqual(commands.pop(), {
      type: 'storage.transfer',
      payload: {
        id: bagItem.id,
        revision: 3,
        from: 'inventory',
        to: 'storage',
        x: 2,
        y: 3,
        page: 0,
        quick: false,
      },
    });
    assert.match(
      storageRoot.querySelector('.storage-status')?.textContent ?? '',
      /Transfer rejected/,
    );
    assert.match(
      storageRoot.querySelector('.storage-capacity')?.textContent ?? '',
      /135 slots/,
    );
    await drop(item(storageRoot, stored.id), invGrid);
    assert.deepEqual(commands.pop(), {
      type: 'storage.transfer',
      payload: {
        id: stored.id,
        revision: 5,
        from: 'storage',
        to: 'inventory',
        x: 2,
        y: 3,
        page: 0,
        quick: false,
      },
    });
    await drop(item(storageRoot, stored.id), storageGrid);
    assert.deepEqual(commands.pop(), {
      type: 'storage.transfer',
      payload: {
        id: stored.id,
        revision: 5,
        from: 'storage',
        to: 'storage',
        x: 2,
        y: 3,
        page: 0,
        quick: false,
      },
    });
    await drop(item(invRoot, bagItem.id), weapon, 300, 90);
    assert.deepEqual(commands.pop(), {
      type: 'equipment.equip',
      payload: { id: bagItem.id, revision: 3 },
    });
    capture(weapon);
    await drop(weapon, invGrid);
    assert.deepEqual(commands.pop(), {
      type: 'equipment.unequip',
      payload: { id: equippedItem.id, revision: 4 },
    });
    await drop(item(storageRoot, stored.id), weapon, 300, 90, false);
    assert.equal(commands.length, 0);
    for (const [root, id, from, to] of [
      [invRoot, bagItem.id, 'inventory', 'storage'],
      [storageRoot, stored.id, 'storage', 'inventory'],
    ] as const) {
      f.pointer(item(root, id), 'pointerdown', 10, 10, 0, 7, true);
      await flush();
      const command = commands.pop();
      assert.equal(command?.type, 'storage.transfer');
      const expected: StorageTransferCommand = {
        id,
        revision: from === 'inventory' ? 3 : 5,
        from,
        to,
        x: 0,
        y: 0,
        page: 0,
        quick: true,
      };
      assert.deepEqual(command?.payload, expected);
      assert.equal(f.runtime.active, false);
    }
    f.pointer(item(invRoot, bagItem.id), 'pointerdown', 10, 10, 2);
    await flush();
    assert.deepEqual(commands.pop(), {
      type: 'item.activate',
      payload: { id: bagItem.id, revision: 3 },
    });
    // A latched payload survives page repaint; exact selected cell/page is preserved.
    f.setHit(null);
    const source = item(invRoot, bagItem.id);
    f.pointer(source, 'pointerdown');
    f.pointer(source, 'pointerup');
    const tab =
      storageRoot.querySelectorAll<HTMLButtonElement>('[role=tab]')[1];
    assert.ok(tab);
    tab.click();
    f.setHit(storageGrid);
    f.pointer(storageGrid, 'pointerdown', 130, 170);
    await flush();
    assert.deepEqual(commands.pop(), {
      type: 'storage.transfer',
      payload: {
        id: bagItem.id,
        revision: 3,
        from: 'inventory',
        to: 'storage',
        x: 3,
        y: 4,
        page: 1,
        quick: false,
      },
    });
    const firstTab = storageRoot.querySelector<HTMLButtonElement>('[role=tab]');
    assert.ok(firstTab);
    firstTab.click();
    inventory.setState({
      inventory: { columns: 5, rows: 9, pages: 4, items: [] },
    });
    assert.equal(invRoot.querySelector('.inventory-item'), null);
    reset();
    const count = f.runtime.registrationCount;
    for (let i = 0; i < 10; i++) reset();
    assert.equal(f.runtime.registrationCount, count);
    await drop(item(invRoot, bagItem.id), invGrid, 90, 350, false);
    assert.equal(commands.length, 0); // Invalid footprint, no first-free fallback.
  } finally {
    inventory.dispose();
    storage.dispose();
    equipment.dispose();
    assert.equal(f.runtime.registrationCount, 0);
    f.runtime.dispose();
    f.manager.dispose();
  }
});
test('runtime architecture has no feature routing, server commands or item definition knowledge', async () => {
  const source = await readFile(
    new URL('../ts/game-ui/drag/item-drag-runtime.ts', import.meta.url),
    'utf8',
  );
  assert.doesNotMatch(
    source,
    /\b(?:inventory|storage|equipment|shop|trade)\b/i,
  );
  assert.doesNotMatch(
    source,
    /primary_action|ItemInstance|ItemDefinition|bridge\.request|command_id/,
  );
});

test('disposal before a queued drop prevents dispatch', async () => {
  const f = fixture(),
    destination = target();
  f.doc.body.append(destination);
  let drops = 0;
  f.runtime.registerSource({ element: f.node, payload: () => f.payload });
  f.runtime.registerTarget({
    element: destination,
    preview: () => ({ valid: true, data: null }),
    drop: () => {
      drops++;
    },
  });
  f.setHit(destination);
  f.pointer(f.node, 'pointerdown');
  f.pointer(f.node, 'pointerup', 100, 100);
  f.runtime.dispose();
  await flush();
  assert.equal(drops, 0);
  assert.equal(f.runtime.active, false);
  f.manager.dispose();
});

test('unregistering a target before its queued drop prevents dispatch', async () => {
  const f = fixture(),
    destination = target();
  f.doc.body.append(destination);
  let drops = 0;
  f.runtime.registerSource({ element: f.node, payload: () => f.payload });
  const handle = f.runtime.registerTarget({
    element: destination,
    preview: () => ({ valid: true, data: null }),
    drop: () => {
      drops++;
    },
  });
  try {
    f.setHit(destination);
    f.pointer(f.node, 'pointerdown');
    f.pointer(f.node, 'pointerup', 100, 100);
    handle.dispose();
    await flush();
    assert.equal(drops, 0);
  } finally {
    f.runtime.dispose();
    f.manager.dispose();
  }
});
