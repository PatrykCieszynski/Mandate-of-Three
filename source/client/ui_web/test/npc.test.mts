import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target, measure } from './fixtures.mjs';
import { mountNpcServiceMenu } from '../web/screens/npc/npc-service-menu.js';
import { mountNpcInteraction } from '../web/screens/npc/npc-interaction.js';
import { npcOpening, NpcServiceKind } from '../web/screens/npc/npc-model.js';
import type {
  NpcInteractionSnapshot,
  NpcServiceSelection,
} from '../web/screens/npc/npc-model.js';
import { DomainStore } from '../web/store.js';
import { encode, decode, isStateMessage } from '../web/protocol.js';
function message(type: string, payload: object) {
  const value = decode(encode(type, payload));
  if (!isStateMessage(value)) throw Error('Expected state');
  return value;
}
const blacksmith: NpcInteractionSnapshot = {
  active: true,
  npcInstanceId: 'spike-blacksmith-01',
  npcDefinitionId: 'blacksmith',
  name: 'Blacksmith',
  selectedServiceId: '',
  services: [
    {
      id: 'upgrade',
      kind: NpcServiceKind.UPGRADE,
      label: 'Upgrade',
      iconId: 'upgrade',
      enabled: true,
    },
    {
      id: 'weapon_shop',
      kind: NpcServiceKind.SHOP,
      label: 'Weapon Shop',
      iconId: 'shop',
      enabled: true,
    },
  ],
};
test('NPC routing uses enabled services and authoritative selection', () => {
  assert.deepEqual(npcOpening({ active: false }), { mode: 'none' });
  assert.equal(npcOpening({ ...blacksmith, services: [] }).mode, 'none');
  assert.equal(npcOpening(blacksmith).mode, 'menu');
  assert.equal(
    npcOpening({
      ...blacksmith,
      services: blacksmith.services.map((service) => ({
        ...service,
        enabled: false,
      })),
    }).mode,
    'none',
  );
  assert.equal(
    npcOpening({
      ...blacksmith,
      services: blacksmith.services.map((service, index) => ({
        ...service,
        enabled: index === 1,
      })),
    }).mode,
    'select',
  );
  assert.equal(
    npcOpening({ ...blacksmith, services: [blacksmith.services[0]!] }).mode,
    'select',
  );
  assert.equal(
    npcOpening({ ...blacksmith, selectedServiceId: 'weapon_shop' }).mode,
    'service',
  );
});
test('service menu preserves server order and returns typed ID/kind, disposal removes handlers', () => {
  const { manager, host } = environment(),
    root = target(),
    selected: NpcServiceSelection['service'][] = [];
  document.body.append(root);
  const menu = mountNpcServiceMenu(root, {
    manager,
    onSelect: (service) => selected.push(service),
    onClose: () => {},
  });
  measure(menu.regions[0]!);
  menu.setState(blacksmith);
  const buttons = Array.from(
    root.querySelectorAll<HTMLButtonElement>('.npc-service'),
  );
  assert.deepEqual(
    buttons.map((button) => button.textContent),
    ['Upgrade', 'Weapon Shop'],
  );
  buttons[1]!.click();
  assert.equal(selected[0]?.id, 'weapon_shop');
  assert.equal(selected[0]?.kind, NpcServiceKind.SHOP);
  menu.dispose();
  buttons[0]!.click();
  assert.equal(selected.length, 1);
  manager.dispose();
  host.close();
});
test('composition auto-selects once, hides menu on selection, supports optional intent and closes cleanly', async () => {
  const { manager, host } = environment(),
    menuRoot = target(),
    serviceRoot = target(),
    calls: NpcServiceSelection[] = [],
    opened: NpcServiceSelection[] = [];
  document.body.append(menuRoot, serviceRoot);
  let closed = 0,
    reject = false;
  const view = mountNpcInteraction(menuRoot, serviceRoot, {
    manager,
    selectService: async (selection) => {
      calls.push(selection);
      return reject ? { ok: false, error: 'too_fast' } : { ok: true };
    },
    onClose: () => closed++,
    onServiceOpened: (selection) => opened.push(selection),
  });
  view.regions.forEach((panel) => measure(panel));
  view.setState(blacksmith);
  assert.equal(menuRoot.hidden, false);
  assert.equal(serviceRoot.hidden, true);
  await view.openService(blacksmith.services[1]!, {
    preselectedItem: { id: 'item', revision: 3 },
  });
  view.setState({ ...blacksmith, selectedServiceId: 'weapon_shop' });
  assert.equal(menuRoot.hidden, true);
  assert.equal(serviceRoot.hidden, false);
  assert.equal(opened[0]?.context?.preselectedItem?.revision, 3);
  view.setState({ active: false });
  assert.equal(menuRoot.hidden, true);
  assert.equal(serviceRoot.hidden, true);
  const single = { ...blacksmith, services: [blacksmith.services[0]!] };
  view.setState(single);
  view.setState(single);
  await Promise.resolve();
  assert.equal(calls.filter((call) => call.service.id === 'upgrade').length, 1);
  assert.equal(view.closeIfActive(), true);
  assert.equal(closed, 1);
  view.setState({ active: false });
  assert.equal(view.closeIfActive(), false);
  reject = true;
  view.setState(single);
  await Promise.resolve();
  assert.equal(
    menuRoot.hidden,
    false,
    'Rejected auto-open offers a visible retry/close',
  );
  assert.match(menuRoot.textContent ?? '', /too_fast/);
  view.dispose();
  assert.equal(manager.registeredCount, 0);
  manager.dispose();
  host.close();
});
test('NPC snapshots replace/clear cleanly and invalid kinds/references never enter the store', () => {
  const store = new DomainStore();
  assert.equal(store.apply(message('npc.updated', blacksmith)), true);
  const invalid = {
    ...blacksmith,
    services: [{ ...blacksmith.services[0], kind: 88 }],
  };
  assert.equal(store.apply(message('npc.updated', invalid)), false);
  assert.deepEqual(store.state.npc, blacksmith);
  assert.equal(
    store.apply(
      message('npc.updated', {
        ...blacksmith,
        services: [blacksmith.services[0], blacksmith.services[0]],
      }),
    ),
    false,
  );
  assert.equal(store.apply(message('npc.updated', { active: false })), true);
  assert.deepEqual(store.state.npc, { active: false });
  assert.equal(store.apply(message('ui.snapshot', { npc: blacksmith })), true);
  assert.deepEqual(store.state.npc, blacksmith);
});
