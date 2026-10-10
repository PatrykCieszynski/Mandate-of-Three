import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target } from './fixtures.mjs';
import { mountUpgrade } from '../web/screens/upgrade/upgrade-view.js';
import { ItemDragRuntime } from '../web/game-ui/drag/item-drag-runtime.js';
import { upgradeExample } from '../web/screens/upgrade/upgrade-preview.js';
import type { NpcInteractionSnapshot } from '../web/screens/npc/npc-model.js';
const npc: NpcInteractionSnapshot = {
  active: true,
  npcInstanceId: 'smith',
  npcDefinitionId: 'blacksmith',
  name: 'Smith',
  selectedServiceId: 'upgrade',
  services: [{ id: 'upgrade', kind: 1, label: 'Upgrade', enabled: true }],
};
test('Upgrade preview leaves the input item intact and resets local confirmation on context loss', () => {
  const { manager, host } = environment(),
    root = target();
  document.body.append(root);
  const drag = new ItemDragRuntime({
    scale: () => 1,
    onRegionsChanged: () => {},
  });
  let closed = 0;
  const view = mountUpgrade(root, {
    manager,
    drag,
    devPreview: true,
    resolveItemIcon: () => null,
    onClose: () => closed++,
  });
  const before = structuredClone(upgradeExample);
  view.setNpcState(npc);
  const button = (label: string) =>
    Array.from(root.querySelectorAll<HTMLButtonElement>('button')).find(
      (node) => node.textContent === label,
    )!;
  button('Preview Iron Sword').click();
  button('Upgrade').click();
  assert.equal(view.closeIfActive(), true);
  assert.equal(closed, 0, 'Escape first cancels confirmation');
  button('Upgrade').click();
  button('Confirm').click();
  assert.deepEqual(
    upgradeExample,
    before,
    'Preview never changes source item/revision',
  );
  view.setNpcState({ active: false });
  view.setNpcState(npc);
  assert.equal(
    button('Upgrade').disabled,
    true,
    'Reopening requires a fresh selection',
  );
  view.closeIfActive();
  assert.equal(closed, 1);
  view.dispose();
  assert.equal(drag.registrationCount, 0);
  assert.equal(manager.registeredCount, 0);
  drag.dispose();
  manager.dispose();
  host.close();
});

import type { UpgradeSnapshot } from '../web/screens/upgrade/upgrade-model.js';
import type { InventoryItem } from '../web/protocol/contracts.js';
import { DomainStore } from '../web/store.js';
import { mountNpcWorldDrop } from '../web/screens/upgrade/npc-world-drop.js';
import { ownedItemPayload } from '../web/game-ui/items/item-drag-policy.js';
import { capture, fire } from './fixtures.mjs';
const sword: InventoryItem = {
  id: 'a'.repeat(32),
  revision: 0,
  name: 'Sword +0',
  definition_id: 'iron_sword',
  upgrade_level: 0,
  icon_id: 'iron_sword',
  height: 2,
  quantity: 1,
  x: 0,
  y: 0,
  page: 0,
  tooltip: { properties: ['Attack: 10'] },
};
const quote: UpgradeSnapshot = {
  active: true,
  npcInstanceId: 'smith',
  serviceId: 'upgrade',
  upgradeId: 'basic_upgrade',
  itemDefinitionId: 'iron_sword',
  fromLevel: 0,
  toLevel: 1,
  yangCost: 1000,
  materialDefinitionId: 'upgrade_ore',
  materialName: 'Upgrade Ore',
  materialAmount: 1,
  materialOwned: 1,
  successRate: 100,
  candidate: {
    id: sword.id,
    revision: 0,
    level: 0,
    attack: 10,
    nextAttack: 12,
  },
};
test('Production Upgrade sends UID/revision only and waits for authoritative +1; rejected state and reload recover', async () => {
  const { manager, host } = environment(),
    root = target();
  document.body.append(root);
  const drag = new ItemDragRuntime({
    scale: () => 1,
    onRegionsChanged: () => {},
  });
  const commands: unknown[] = [];
  const view = mountUpgrade(root, {
    manager,
    drag,
    resolveItemIcon: () => null,
    onClose: () => {},
    execute: async (command) => {
      commands.push(command);
      return { ok: false, error: 'stale' };
    },
  });
  const button = (label: string) =>
    Array.from(root.querySelectorAll<HTMLButtonElement>('button')).find(
      (n) => n.textContent === label,
    )!;
  const inventory = { columns: 5, rows: 9, pages: 4, items: [sword] };
  view.setNpcState(npc);
  view.setInventory(inventory);
  view.setState(quote);
  view.setWallet({ ready: true, balance: 1000 });
  button('Upgrade').click();
  button('Confirm').click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(commands, [
    {
      npc_instance_id: 'smith',
      service_id: 'upgrade',
      id: sword.id,
      revision: 0,
    },
  ]);
  assert.equal(
    root.querySelector('.upgrade-name')?.textContent,
    'Sword +0',
    'No optimistic level increment',
  );
  assert.match(root.querySelector('.upgrade-notice')!.textContent!, /stale/);
  assert.deepEqual(
    inventory.items,
    [sword],
    'Selection/upgrade never changes source inventory',
  );
  view.setInventory({
    ...inventory,
    items: [{ ...sword, revision: 1, name: 'Sword +1', upgrade_level: 1 }],
  });
  view.setState({
    ...quote,
    candidate: {
      id: sword.id,
      revision: 1,
      level: 1,
      attack: 12,
      nextAttack: 14,
    },
    materialOwned: 0,
  });
  assert.equal(root.querySelector('.upgrade-name')?.textContent, 'Sword +1');
  assert.equal(button('Upgrade').disabled, true, 'Only +0 to +1 allowed');
  view.setNpcState({ active: false });
  view.setState({ active: false });
  view.setNpcState(npc);
  view.setInventory(inventory);
  view.setState(quote);
  assert.equal(
    root.querySelector('.upgrade-name')?.textContent,
    'Sword +0',
    'Server selection recovers on UI_READY',
  );
  const store = new DomainStore();
  assert.equal(
    store.apply({ v: 1, type: 'upgrade.updated', payload: quote }),
    true,
  );
  const before = structuredClone(store.state);
  assert.equal(
    store.apply({
      v: 1,
      type: 'upgrade.updated',
      payload: { ...quote, successRate: 50 },
    }),
    false,
  );
  assert.deepEqual(store.state, before);
  view.dispose();
  drag.dispose();
  manager.dispose();
  host.close();
});
test('Inventory drop on world NPC selects through explicit command and releases gesture without losing queued target', async () => {
  const { manager, host, doc } = environment();
  Object.assign(globalThis, { HTMLElement: host.HTMLElement });
  let worldDrop: ReturnType<typeof mountNpcWorldDrop>;
  const drag = new ItemDragRuntime({
    scale: () => 1,
    onRegionsChanged: () => worldDrop?.setCarrying(drag.active),
  });
  const commands: unknown[] = [];
  worldDrop = mountNpcWorldDrop(
    drag,
    async (npc, item) => {
      commands.push({ npc, item });
    },
    () => {},
  );
  worldDrop.setState({
    width: host.innerWidth,
    height: host.innerHeight,
    targets: [{ id: 'smith', x: 0, y: 0, w: 40, h: 80 }],
  });
  const source = target();
  doc.body.append(source);
  capture(source);
  const binding = drag.registerSource({
    element: source,
    payload: () => ownedItemPayload('inventory', sword, 40, () => null),
  });
  const hit = doc.querySelector<HTMLElement>('.npc-world-drop-target')!;
  Object.defineProperty(doc, 'elementFromPoint', {
    configurable: true,
    value: () => hit,
  });
  fire(source, 'pointerdown', 10, 10);
  fire(doc, 'pointermove', 50, 50);
  fire(doc, 'pointerup', 50, 50);
  worldDrop.setState({
    width: host.innerWidth,
    height: host.innerHeight,
    targets: [{ id: 'smith', x: 1, y: 1, w: 40, h: 80 }],
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(commands, [
    { npc: 'smith', item: { id: sword.id, revision: 0 } },
  ]);
  assert.equal(drag.active, false);
  assert.equal(
    doc.querySelector<HTMLElement>('.npc-world-drop')!.dataset.carrying,
    'false',
  );
  assert.equal(sword.upgrade_level, 0);
  binding.dispose();
  worldDrop.dispose();
  drag.dispose();
  manager.dispose();
  host.close();
});
