import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ItemTooltip,
  setItemTooltipDetails,
} from '../web/game-ui/items/item-tooltip.js';
import {
  isItemTooltipDetails,
  itemRarity,
} from '../web/game-ui/items/item-tooltip-model.js';
import type { TooltipAffix } from '../web/game-ui/items/item-tooltip-model.js';
import { environment, target, measure, bagItem } from './fixtures.mjs';
import { DomainStore } from '../web/store.js';
import { WebBridge } from '../web/bridge.js';
import { encode, decodeAndValidate } from '../web/protocol.js';
function fixture() {
  const f = environment(),
    root = target();
  f.doc.body.append(root);
  const tip = ItemTooltip(root, { geometry: () => f.manager });
  return {
    ...f,
    root,
    tip,
    dispose() {
      tip.dispose();
      f.manager.dispose();
      f.dom.window.close();
    },
  };
}
const bonuses: TooltipAffix[] = [
  { kind: 'prefix', lines: ['+15 Strength', '+20 maximum health'] },
  { kind: 'prefix', lines: ['+18% physical damage'] },
  { kind: 'prefix', lines: ['+120 maximum health'] },
  { kind: 'suffix', lines: ['+8% attack speed'] },
  { kind: 'suffix', lines: ['+12% fire resistance'] },
  { kind: 'suffix', lines: ['+6% movement speed'] },
];
test('rarity counts affixes rather than lines and clears sections/offer data on item replacement', () => {
  const f = fixture();
  try {
    for (let count = 0; count <= 6; count++) {
      f.tip.show(
        { clientX: 20, clientY: 20 },
        { name: 'Sword', tooltip: { affixes: bonuses.slice(0, count) } },
      );
      assert.equal(
        f.tip.element.dataset.rarity,
        ['normal', 'magic', 'magic', 'rare', 'rare', 'legendary', 'legendary'][
          count
        ],
      );
      assert.equal(
        f.tip.element.querySelectorAll('.item-tooltip-affix').length,
        count,
      );
    }
    assert.equal(itemRarity(1), 'magic');
    f.tip.show(
      { clientX: 20, clientY: 20 },
      {
        kind: 'shop-offer',
        name: '<img src=x>',
        price: 1200,
        currency: 'yang',
        description: '<script>danger</script>',
        tooltip: {
          category: 'Sword',
          properties: ['Attack: 24–32'],
          requirements: ['Requires level 12'],
          affixes: bonuses,
        },
      },
    );
    assert.equal(f.tip.element.querySelector('img,script'), null);
    assert.match(f.tip.element.textContent ?? '', /1,200 Yang/);
    assert.equal(
      f.tip.element.querySelectorAll('.item-tooltip-affix-kind:not([hidden])')
        .length,
      0,
    );
    f.tip.show({ clientX: 20, clientY: 20 }, { name: 'Plain material' });
    assert.equal(f.tip.element.dataset.rarity, 'normal');
    assert.equal(
      f.tip.element.querySelectorAll('.item-tooltip-affix').length,
      0,
    );
    for (const selector of [
      '.item-tooltip-category',
      '.item-tooltip-properties',
      '.item-tooltip-requirements',
      '.item-tooltip-description',
      '.item-tooltip-price',
    ]) {
      assert.equal(
        f.tip.element.querySelector<HTMLElement>(selector)?.hidden,
        true,
      );
    }
  } finally {
    f.dispose();
  }
});
test('Alt changes a stationary tooltip and repositions expanded content; blur/hide/dispose never resurrect it', () => {
  const f = fixture();
  const height = () =>
    f.tip.element.querySelectorAll('.item-tooltip-affix-kind:not([hidden])')
      .length
      ? 180
      : 100;
  measure(f.tip.element, 260, 100);
  Object.defineProperty(f.tip.element, 'offsetHeight', {
    configurable: true,
    get: height,
  });
  f.manager.setViewport({ width: 800, height: 600 }, 1.25);
  try {
    f.tip.show(
      { clientX: 780, clientY: 580 },
      { name: 'Sword', tooltip: { affixes: bonuses.slice(0, 2) } },
    );
    const originalTop = parseFloat(f.tip.element.style.top);
    f.doc.dispatchEvent(
      new f.host.KeyboardEvent('keydown', { key: 'Alt', altKey: true }),
    );
    assert.equal(
      f.tip.element.querySelectorAll('.item-tooltip-affix-kind:not([hidden])')
        .length,
      2,
    );
    assert.ok(parseFloat(f.tip.element.style.top) < originalTop);
    f.doc.dispatchEvent(new f.host.KeyboardEvent('keyup', { key: 'Alt' }));
    assert.equal(
      f.tip.element.querySelectorAll('.item-tooltip-affix-kind:not([hidden])')
        .length,
      0,
    );
    setItemTooltipDetails(f.doc, true, 'native');
    // Mouse events in a pointer-only CEF need not carry a keyboard modifier.
    f.tip.show(
      { clientX: 780, clientY: 580, altKey: false },
      { name: 'Sword', tooltip: { affixes: bonuses.slice(0, 2) } },
    );
    assert.equal(
      f.tip.element.querySelectorAll('.item-tooltip-affix-kind:not([hidden])')
        .length,
      2,
    );
    f.host.dispatchEvent(new f.host.Event('blur'));
    assert.equal(f.tip.element.hidden, true);
    setItemTooltipDetails(f.doc, true);
    assert.equal(f.tip.element.hidden, true);
    f.tip.dispose();
    f.tip.dispose();
    const before = f.tip.element.textContent;
    f.tip.show({ clientX: 0, clientY: 0 }, { name: 'Disposed' });
    assert.equal(f.tip.element.isConnected, false);
    assert.equal(f.tip.element.textContent, before);
  } finally {
    f.dispose();
  }
});
test('tooltip IPC validates bounded presentation metadata and preserves last valid domain', () => {
  const store = new DomainStore();
  const inventory = {
    columns: 5,
    rows: 9,
    pages: 4,
    items: [{ ...bagItem, tooltip: { affixes: bonuses } }],
  };
  assert.equal(
    store.apply(
      decodeAndValidate({
        v: 1,
        type: 'inventory.updated',
        payload: inventory,
      }),
    ),
    true,
  );
  const previous = store.state;
  for (const bad of [
    null,
    { affixes: Array(7).fill(bonuses[0]) },
    { affixes: Array(4).fill(bonuses[0]) },
    { affixes: [{ kind: 'other', lines: ['bonus'] }] },
    { affixes: [{ kind: 'prefix', lines: [] }] },
    { affixes: [{ kind: 'suffix', lines: ['a', 'b', 'c', 'd'] }] },
    { properties: [Infinity] },
    { category: 'a'.repeat(257) },
    { requirements: Array(5).fill('x') },
    { affixes: [{ kind: 'prefix', lines: ['x'], value: NaN }] },
  ]) {
    assert.equal(isItemTooltipDetails(bad), false);
    assert.equal(
      store.apply(
        decodeAndValidate({
          v: 1,
          type: 'inventory.updated',
          payload: { ...inventory, items: [{ ...bagItem, tooltip: bad }] },
        }),
      ),
      false,
    );
    assert.equal(store.state, previous);
  }
  assert.equal(
    isItemTooltipDetails({ affixes: [{ lines: ['+3 Attack'] }] }),
    true,
  ); // Legacy has no kind metadata.
  assert.equal(
    store.apply(
      decodeAndValidate({
        v: 1,
        type: 'wallet.updated',
        payload: { balance: 50 },
      }),
    ),
    true,
  );
});
test('native Alt messages are boolean-only presentation input and never domain updates or commands', () => {
  const sent: string[] = [],
    updates: unknown[] = [],
    values: boolean[] = [];
  const bridge = new WebBridge({
    send: (message) => sent.push(message),
    subscribe: () => {},
    onState: (message) => updates.push(message),
    onTooltipDetails: (alt) => values.push(alt),
  });
  for (const payload of [
    { alt: 1 },
    { alt: 'true' },
    { alt: null },
    { alt: true, extra: 1 },
    {},
  ])
    bridge.receive(encode('ui.tooltip_details', payload));
  bridge.receive(encode('ui.tooltip_details', { alt: true }, 'request-id'));
  assert.deepEqual(values, []);
  bridge.receive(encode('ui.tooltip_details', { alt: true }));
  bridge.receive(encode('ui.tooltip_details', { alt: false }));
  assert.deepEqual(values, [true, false]);
  assert.deepEqual(sent, []);
  assert.deepEqual(updates, []);
});

test('Shop validates the same tooltip contract independently of owned item identities', () => {
  const shop = {
    active: true,
    npcInstanceId: 'merchant',
    serviceId: 'shop',
    shopId: 'starter',
    name: 'Merchant',
    currency: 'yang',
    offers: [
      {
        offerId: 'sword',
        itemDefinitionId: 'iron_sword',
        name: 'Sword',
        iconId: 'iron_sword',
        height: 2,
        quantity: 1,
        price: 100,
        tooltip: { affixes: bonuses },
      },
    ],
  };
  const store = new DomainStore();
  assert.equal(
    store.apply(
      decodeAndValidate({ v: 1, type: 'shop.updated', payload: shop }),
    ),
    true,
  );
  const before = store.state;
  const offer = shop.offers[0];
  assert.ok(offer);
  assert.equal(
    store.apply(
      decodeAndValidate({
        v: 1,
        type: 'shop.updated',
        payload: {
          ...shop,
          offers: [
            {
              ...offer,
              tooltip: {
                affixes: Array(4).fill({ kind: 'suffix', lines: ['bonus'] }),
              },
            },
          ],
        },
      }),
    ),
    false,
  );
  assert.equal(store.state, before);
});
