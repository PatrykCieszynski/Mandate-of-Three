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
  button('Preview upgrade').click();
  assert.equal(view.closeIfActive(), true);
  assert.equal(closed, 0, 'Escape first cancels confirmation');
  button('Preview upgrade').click();
  button('Confirm').click();
  assert.deepEqual(
    upgradeExample,
    before,
    'Preview never changes source item/revision',
  );
  view.setNpcState({ active: false });
  view.setNpcState(npc);
  assert.equal(
    button('Preview upgrade').disabled,
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
