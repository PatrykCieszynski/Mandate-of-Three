import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target, capture, measure, bagItem } from './fixtures.mjs';
import { DomainStore } from '../web/store.js';
import { decode, encode, isStateMessage } from '../web/protocol.js';
import { ItemTooltip } from '../web/game-ui/items/item-tooltip.js';
import { shopOfferLayout } from '../web/screens/shop/shop-layout.js';
import { mountShop } from '../web/screens/shop/shop-view.js';
import { mountInventory } from '../web/screens/inventory/inventory-view.js';
import { mountNpcInteraction } from '../web/screens/npc/npc-interaction.js';
import { NpcServiceKind } from '../web/screens/npc/npc-model.js';
import type { NpcInteractionSnapshot } from '../web/screens/npc/npc-model.js';
import { ItemDragRuntime } from '../web/game-ui/drag/item-drag-runtime.js';
import type {
  ShopSnapshot,
  ShopBuyCommand,
} from '../web/screens/shop/shop-model.js';
const shop: ShopSnapshot = {
  active: true,
  npcInstanceId: 'spike-blacksmith-01',
  serviceId: 'weapon_shop',
  shopId: 'blacksmith_weapon_shop',
  name: 'Weapons',
  currency: 'yang',
  offers: [
    {
      offerId: 'sword',
      itemDefinitionId: 'iron_sword',
      name: 'Sword',
      iconId: 'iron_sword',
      height: 2,
      quantity: 1,
      price: 1000,
    },
    {
      offerId: 'sword_pack',
      itemDefinitionId: 'iron_sword',
      name: 'Pack',
      iconId: 'iron_sword',
      height: 2,
      quantity: 2,
      price: 2000,
    },
  ],
};
function message(type: string, payload: object) {
  const result = decode(encode(type, payload));
  if (!isStateMessage(result)) throw Error('state');
  return result;
}
const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
test('Shop snapshots validate all offers before atomic replacement and survive full snapshots', () => {
  const store = new DomainStore();
  assert.equal(store.apply(message('shop.updated', shop)), true);
  for (const bad of [
    { price: 0 },
    { quantity: 0 },
    { height: 4 },
    { offerId: 'bad/id' },
    { itemDefinitionId: 'missing/path' },
    { revision: 0 },
    { uid: 'fake' },
  ]) {
    assert.equal(
      store.apply(
        message('shop.updated', {
          ...shop,
          offers: [shop.offers[0], { ...shop.offers[1], ...bad }],
        }),
      ),
      false,
    );
    assert.deepEqual(store.state.shop, shop);
  }
  assert.equal(
    store.apply(
      message('shop.updated', {
        ...shop,
        offers: [shop.offers[0], shop.offers[0]],
      }),
    ),
    false,
  );
  assert.equal(
    store.apply(message('ui.snapshot', { shop, wallet: { balance: 5000 } })),
    true,
  );
  assert.deepEqual(store.state.shop, shop);
  assert.equal(store.apply(message('shop.updated', { active: false })), true);
  assert.deepEqual(store.state.shop, { active: false });
});
function fixture() {
  const env = environment();
  Object.assign(globalThis, {
    HTMLElement: env.host.HTMLElement,
    getComputedStyle: env.host.getComputedStyle.bind(env.host),
  });
  let hit: Element | null = null;
  Object.defineProperty(env.doc, 'elementFromPoint', {
    configurable: true,
    value: () => hit,
  });
  const drag = new ItemDragRuntime({
      scale: () => 1,
      onRegionsChanged: () => {},
    }),
    shopRoot = target(),
    invRoot = target();
  env.doc.body.append(shopRoot, invRoot);
  const commands: ShopBuyCommand[] = [];
  let success = false;
  const view = mountShop(shopRoot, {
    manager: env.manager,
    drag,
    resolveItemIcon: () => null,
    onClose: () => {},
    buy: async (command) => {
      commands.push(command);
      return success ? { ok: true } : { ok: false, error: 'funds' };
    },
  });
  const inventory = mountInventory(invRoot, {
    manager: env.manager,
    drag,
    moveItem: async () => ({ ok: true }),
    buyShopOffer: (subject, position) => view.buyOffer(subject, position),
  });
  view.setState(shop);
  view.setWallet({ balance: 5000, ready: true });
  inventory.setState({
    inventory: { columns: 5, rows: 9, pages: 4, items: [bagItem] },
  });
  const grid = invRoot.querySelector<HTMLElement>('.inventory-grid')!;
  grid.style.setProperty('--slot-size', '40px');
  [
    grid,
    ...view.regions,
    ...inventory.regions,
    invRoot.querySelector<HTMLElement>('.window-content')!,
  ]
    .filter(Boolean)
    .forEach((element) => measure(element));
  // Measure every ancestor used by runtime hit testing independently of real layout.
  invRoot
    .querySelectorAll<HTMLElement>('*')
    .forEach((element) => measure(element));
  shopRoot
    .querySelectorAll<HTMLElement>('*')
    .forEach((element) => measure(element));
  function pointer(
    element: EventTarget,
    type: string,
    x = 10,
    y = 10,
    button = 0,
  ) {
    const event = new env.host.MouseEvent(type, {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      button,
    });
    Object.defineProperty(event, 'pointerId', { value: 7 });
    element.dispatchEvent(event);
  }
  function source() {
    const node = shopRoot.querySelector<HTMLElement>('.shop-item')!;
    capture(node);
    return node;
  }
  async function drop(destination: HTMLElement, x = 90, y = 130) {
    hit = null;
    const node = source();
    pointer(node, 'pointerdown');
    hit = destination;
    pointer(env.doc, 'pointermove', x, y);
    pointer(node, 'pointerup', x, y);
    await flush();
  }
  return {
    ...env,
    drag,
    shopRoot,
    invRoot,
    grid,
    view,
    inventory,
    commands,
    pointer,
    source,
    drop,
    setSuccess: () => {
      success = true;
    },
    cleanup() {
      view.dispose();
      inventory.dispose();
      assert.equal(drag.registrationCount, 0);
      drag.dispose();
      env.manager.dispose();
      env.host.close();
    },
  };
}
test('Shop renders server offer order and quantity, exposes offer price in tooltip and right-click sends only offer authority', async () => {
  const f = fixture();
  try {
    assert.deepEqual(
      [...f.shopRoot.querySelectorAll<HTMLElement>('.shop-offer')].map(
        (e) => e.dataset.offerId,
      ),
      ['sword', 'sword_pack'],
    );
    const rows = [...f.shopRoot.querySelectorAll<HTMLElement>('.shop-offer')];
    for (const [index, row] of rows.entries()) {
      f.pointer(row, 'pointermove');
      assert.equal(
        f.shopRoot.querySelector('.item-tooltip-price')?.textContent,
        ['Buy price: 1,000 Yang', 'Buy price: 2,000 Yang'][index],
      );
    }
    f.pointer(rows[1]!, 'pointerleave');
    assert.deepEqual(
      [...f.shopRoot.querySelectorAll('.shop-offer .quantity')].map(
        (e) => e.textContent,
      ),
      ['2'],
    );
    f.pointer(f.source(), 'pointerdown', 10, 10, 2);
    await flush();
    assert.deepEqual(f.commands, [
      {
        npc_instance_id: 'spike-blacksmith-01',
        service_id: 'weapon_shop',
        offer_id: 'sword',
      },
    ]);
    assert.match(
      f.shopRoot.querySelector('[role=status]')?.textContent ?? '',
      /Not enough Yang/,
    );
    assert.equal(f.invRoot.querySelectorAll('.inventory-item').length, 1);
    f.setSuccess();
    f.pointer(f.source(), 'pointerdown', 10, 10, 2);
    await flush();
    assert.equal(
      f.invRoot.querySelectorAll('.inventory-item').length,
      1,
      'Success result cannot insert an item optimistically',
    );
    f.inventory.setState({
      inventory: {
        columns: 5,
        rows: 9,
        pages: 4,
        items: [
          bagItem,
          { ...bagItem, id: 'committed', x: 2, y: 3, height: 2 },
        ],
      },
    });
    assert.equal(
      f.invRoot.querySelectorAll('.inventory-item').length,
      2,
      'Authoritative snapshot adds item',
    );
  } finally {
    f.cleanup();
  }
});
test('Shop drag uses exact grid targets, rejects invalid footprints locally and falls back only outside the grid', async () => {
  const f = fixture();
  try {
    await f.drop(f.grid);
    assert.deepEqual(f.commands.pop(), {
      npc_instance_id: 'spike-blacksmith-01',
      service_id: 'weapon_shop',
      offer_id: 'sword',
      x: 2,
      y: 3,
      page: 0,
    });
    await f.drop(f.grid, 10, 10);
    assert.equal(
      f.commands.length,
      0,
      'Occupied exact target never becomes first fit',
    );
    await f.drop(f.grid, 170, 330);
    assert.equal(f.commands.length, 0, 'Tall item cannot cross page bottom');
    const wallet = f.invRoot.querySelector<HTMLElement>('.wallet')!;
    await f.drop(wallet);
    assert.deepEqual(f.commands.pop(), {
      npc_instance_id: 'spike-blacksmith-01',
      service_id: 'weapon_shop',
      offer_id: 'sword',
    });
    const full = Array.from({ length: 180 }, (_, i) => ({
      ...bagItem,
      id: 'full-' + i,
      height: 1,
      x: i % 5,
      y: Math.floor((i % 45) / 5),
      page: Math.floor(i / 45),
    }));
    f.inventory.setState({
      inventory: { columns: 5, rows: 9, pages: 4, items: full },
    });
    await f.drop(wallet);
    assert.equal(
      f.commands.length,
      0,
      'Known full receive area rejects locally',
    );
  } finally {
    f.cleanup();
  }
});
test('NPC composition routes selected SHOP to its feature and close returns to menu or closes single-service context', () => {
  const env = environment(),
    menu = target(),
    placeholder = target();
  document.body.append(menu, placeholder);
  let clear = 0,
    closed = 0,
    opened = 0;
  const state: NpcInteractionSnapshot = {
    active: true,
    npcInstanceId: 'spike-blacksmith-01',
    npcDefinitionId: 'blacksmith',
    name: 'Blacksmith',
    selectedServiceId: 'weapon_shop',
    services: [
      {
        id: 'upgrade',
        kind: NpcServiceKind.UPGRADE,
        label: 'Upgrade',
        enabled: true,
      },
      {
        id: 'weapon_shop',
        kind: NpcServiceKind.SHOP,
        label: 'Shop',
        enabled: true,
      },
    ],
  };
  const view = mountNpcInteraction(menu, placeholder, {
    manager: env.manager,
    selectService: async () => ({ ok: true }),
    handlesService: (kind) => kind === NpcServiceKind.SHOP,
    onServiceOpened: (selection) => {
      assert.equal(selection.service.kind, NpcServiceKind.SHOP);
      opened++;
    },
    clearService: () => clear++,
    onClose: () => closed++,
  });
  try {
    view.setState(state);
    view.setState(state);
    assert.equal(opened, 1);
    assert.equal(menu.hidden, true);
    assert.equal(placeholder.hidden, true);
    view.serviceFailed(
      { npcInstanceId: state.npcInstanceId, service: state.services[1]! },
      'out_of_range',
    );
    assert.equal(menu.hidden, false);
    assert.match(menu.textContent ?? '', /out_of_range/);
    assert.equal(opened, 1, 'Open rejection does not recursively reopen');
    view.closeIfActive();
    assert.equal(clear, 1);
    assert.equal(closed, 0);
    view.setState({ ...state, selectedServiceId: '' });
    assert.equal(menu.hidden, false);
    view.closeIfActive();
    assert.equal(closed, 1);
    view.setState({ ...state, services: [state.services[1]!] });
    view.closeIfActive();
    assert.equal(closed, 2);
  } finally {
    view.dispose();
    env.manager.dispose();
    env.host.close();
  }
});

// Offer pricing is presentation context, independent of an authored item description.
test('Item tooltip preserves descriptions and clears offer pricing for owned items', () => {
  const env = environment(),
    root = target();
  env.doc.body.append(root);
  const tip = ItemTooltip(root, { geometry: () => env.manager });
  try {
    tip.show(
      { clientX: 10, clientY: 10 },
      {
        name: 'Sword',
        description: 'Forged steel.',
        kind: 'shop-offer',
        price: 1000,
        currency: 'yang',
      },
    );
    assert.equal(tip.element.querySelector('p')?.textContent, 'Forged steel.');
    const footer = tip.element.querySelector('footer')!;
    assert.equal(footer.textContent, 'Buy price: 1,000 Yang');
    assert.equal(footer.hidden, false);
    tip.show(
      { clientX: 10, clientY: 10 },
      { name: 'Owned Sword', description: 'Already yours.' },
    );
    assert.equal(tip.element.querySelector('p')?.textContent, 'Already yours.');
    assert.equal(footer.hidden, true);
    assert.equal(footer.textContent, '');
  } finally {
    tip.dispose();
    env.manager.dispose();
    env.host.close();
  }
});

test('Shop catalog packs mixed footprints without overlap, preserving offers when it grows', () => {
  const offers = Array.from({ length: 40 }, (_, i) => ({
    ...shop.offers[i % 2]!,
    offerId: 'offer_' + i,
    height: (i % 3) + 1,
  }));
  const layout = shopOfferLayout(offers),
    occupied = new Set<string>();
  assert.deepEqual(
    layout.items.map((item) => item.offerId),
    offers.map((offer) => offer.offerId),
  );
  for (const item of layout.items) {
    assert.ok(
      item.x >= 0 &&
        item.x < layout.columns &&
        item.y >= 0 &&
        item.y + item.height <= layout.rows,
    );
    for (let dy = 0; dy < item.height; dy++) {
      const cell = `${item.x}:${item.y + dy}`;
      assert.equal(occupied.has(cell), false, 'Catalog offers cannot overlap');
      occupied.add(cell);
    }
  }
  assert.equal(
    occupied.size,
    offers.reduce((sum, offer) => sum + offer.height, 0),
  );
});
