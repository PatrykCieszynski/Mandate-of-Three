// Optional real-browser UI milestone; SQL authority is covered by market_network.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { chromium } from 'playwright-core';
const root = path.resolve(fileURLToPath(new URL('../web/', import.meta.url)));
const server = createServer(async (req, res) => {
  try {
    const file = path.resolve(
      root,
      '.' +
        decodeURIComponent(
          new URL(req.url ?? '/', 'http://localhost').pathname,
        ),
    );
    if (!file.startsWith(root + path.sep)) throw Error('path');
    res.setHeader(
      'Content-Type',
      (
        {
          '.js': 'text/javascript',
          '.html': 'text/html',
          '.css': 'text/css',
          '.svg': 'image/svg+xml',
          '.png': 'image/png',
        } as Record<string, string>
      )[path.extname(file)] ?? 'application/octet-stream',
    );
    res.end(await readFile(file));
  } catch {
    res.statusCode = 404;
    res.end();
  }
});
await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
const browser = await chromium.launch({
  executablePath:
    process.argv[2] ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
try {
  const page = await browser.newPage();
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(() => {
    const w = window as any;
    w.sent = [];
    const listeners: ((s: string) => void)[] = [];
    w.ipcMessage = {
      addListener: (f: (s: string) => void) => listeners.push(f),
    };
    w.emit = (type: string, payload: object, id?: string) =>
      listeners.forEach((f) =>
        f(JSON.stringify({ v: 1, type, payload, ...(id ? { id } : {}) })),
      );
    w.sendIpcMessage = (raw: string) => {
      const m = JSON.parse(raw);
      w.sent.push(m);
      if (m.id)
        queueMicrotask(() => w.emit('command.result', { ok: true }, m.id));
    };
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw Error('port');
  const item = {
    id: 'a'.repeat(32),
    revision: 2,
    name: 'Iron Sword',
    icon_id: 'iron_sword',
    x: 0,
    y: 0,
    page: 0,
    height: 2,
    quantity: 1,
  };
  const state = {
    inventory: { columns: 5, rows: 9, pages: 4, items: [item] },
    market: {
      active: true,
      shopId: 1,
      name: 'Bread Shop',
      status: 'active',
      revision: 0,
      columns: 5,
      rows: 8,
      offers: [],
      claims: [],
    },
    wallet: { balance: 1500, ready: true },
    hud: {
      inventory_open: true,
      ui_scale: 1,
      viewport: { width: 1920, height: 1080 },
    },
  };
  await page.goto(`http://127.0.0.1:${address.port}/inventory/game.html`);
  await page.waitForFunction(() =>
    (window as any).sent.some((m: any) => m.type === 'ui.ready'),
  );
  for (const [width, height, scale] of [
    [1280, 720, 0.8],
    [1280, 720, 0.9],
    [1920, 1080, 1],
    [2560, 1440, 1],
    [2560, 1440, 1.1],
    [2560, 1440, 1.25],
    [3440, 1440, 1],
    [3440, 1440, 1.1],
    [3840, 2160, 1.25],
    [3840, 2160, 1.5],
  ] as const) {
    await page.setViewportSize({ width, height });
    state.hud = { ...state.hud, ui_scale: scale, viewport: { width, height } };
    await page.evaluate((s) => (window as any).emit('ui.snapshot', s), state);
    await page.waitForFunction(
      () => !document.querySelector<HTMLElement>('#market')?.hidden,
    );
    const rect = await page
      .locator('#market .player-shop-window')
      .boundingBox();
    assert.ok(
      rect &&
        rect.x >= -1 &&
        rect.y >= -1 &&
        rect.x + rect.width <= width + 1 &&
        rect.y + rect.height <= height + 1,
    );
  }
  await page
    .getByRole('textbox', { name: 'Shop name', exact: true })
    .fill('New Shop');
  assert.ok(
    await page.evaluate(() =>
      (window as any).sent.some(
        (m: any) => m.type === 'ui.text_focus' && m.payload.active,
      ),
    ),
  );
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await page.waitForFunction(() =>
    (window as any).sent.some((m: any) => m.type === 'market.configure'),
  );
  await page.evaluate(
    () =>
      document.activeElement instanceof HTMLElement &&
      document.activeElement.blur(),
  );
  assert.ok(
    await page.evaluate(() =>
      (window as any).sent.some(
        (m: any) => m.type === 'ui.text_focus' && !m.payload.active,
      ),
    ),
  );

  const publicItem = { ...item, name: 'Iron Sword +9', upgrade_level: 9 };
  const browserState = {
    active: true,
    catalog: [
      {
        definition_id: 'iron_sword',
        name: 'Iron Sword',
        icon_id: 'iron_sword',
      },
    ],
    stats: {
      monster_damage: { label: 'Monsters', unit: 'percent', min: 0, max: 100 },
      critical_chance: { label: 'Critical', unit: 'percent', min: 0, max: 100 },
    },
    results: [
      {
        offerId: 'b'.repeat(32),
        shopId: 2,
        shopName: 'Offline Shop',
        revision: 0,
        price: 500,
        item: publicItem,
      },
    ],
    cursor: '',
    shop: {},
    highlight: '',
    error: '',
  };
  await page.evaluate(
    (s) => (window as any).emit('market_browser.updated', s),
    browserState,
  );
  await page.getByLabel('Upgrade from', { exact: true }).selectOption('7');
  await page.getByLabel('Upgrade to', { exact: true }).selectOption('9');
  await page
    .getByLabel('Bonus stat', { exact: true })
    .selectOption('monster_damage');
  await page.getByLabel('Minimum bonus', { exact: true }).fill('10');
  await page
    .getByRole('button', { name: 'Add AND bonus', exact: true })
    .click();
  await page
    .getByLabel('Bonus stat', { exact: true })
    .selectOption('critical_chance');
  await page.getByLabel('Minimum bonus', { exact: true }).fill('5');
  await page
    .getByRole('button', { name: 'Add AND bonus', exact: true })
    .click();
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  const sentSearch = await page.evaluate(() =>
    (window as any).sent.findLast(
      (m: any) => m.type === 'market.browser.search',
    ),
  );
  assert.equal(sentSearch.payload.upgrade_min, 7);
  assert.equal(sentSearch.payload.upgrade_max, 9);
  assert.equal(sentSearch.payload.affix_filters.length, 2);
  await page.locator('.market-results tbody tr').click();
  assert.equal(
    await page.evaluate(
      () =>
        (window as any).sent.filter((m: any) => m.type === 'market.buy').length,
    ),
    0,
    'result selection never purchases',
  );
  const offer = {
    id: 'b'.repeat(32),
    revision: 0,
    price: 500,
    item: publicItem,
  };
  await page.evaluate(
    (s) => (window as any).emit('market_browser.updated', s),
    {
      ...browserState,
      shop: {
        active: true,
        shopId: 2,
        name: 'Offline Shop',
        status: 'active',
        revision: 0,
        columns: 5,
        rows: 8,
        offers: [offer],
        claims: [],
      },
      highlight: offer.id,
    },
  );
  assert.equal(await page.locator('.market-highlight').count(), 1);
  await page
    .getByRole('button', { name: 'Buy selected item', exact: true })
    .click();
  await page.waitForFunction(() =>
    (window as any).sent.some((m: any) => m.type === 'market.buy'),
  );
  const purchase = await page.evaluate(() =>
    (window as any).sent.find((m: any) => m.type === 'market.buy'),
  );
  assert.equal(purchase.payload.shop_id, 2);
  assert.equal(purchase.payload.offer_id, offer.id);
  assert.equal(purchase.payload.price, 500);
  console.log(
    'MARKET_SEARCH_BROWSER_OK +7..+9 AND filters, result opens shop, highlight, explicit purchase',
  );

  await page.evaluate((s) => (window as any).emit('exchange.updated', s), {
    active: true,
    yang: 1500,
    reservedYang: 200,
    assets: [
      {
        asset_id: 'upgrade_ore',
        name: 'Upgrade Ore',
        stack_limit: 200,
        free: 100,
        reserved: 40,
      },
    ],
    orders: [],
    depth: [],
    fills: [],
    busy: false,
    retryAvailable: false,
  });
  await page.getByLabel('Ore quantity', { exact: true }).fill('60');
  await page.getByLabel('Yang numerator', { exact: true }).fill('12');
  await page
    .getByRole('button', { name: 'Place limit order', exact: true })
    .click();
  await page.waitForFunction(() =>
    (window as any).sent.some((m: any) => m.type === 'exchange.order'),
  );
  const order = await page.evaluate(() =>
    (window as any).sent.find((m: any) => m.type === 'exchange.order'),
  );
  assert.equal(order.payload.have_asset, 'yang');
  assert.equal(order.payload.want_asset, 'upgrade_ore');
  assert.equal(order.payload.quantity, 60);
  assert.equal(order.payload.price_num, 12);
  assert.equal(order.payload.price_den, 1);
  await page.getByLabel('Withdraw amount', { exact: true }).fill('35');
  await page.getByRole('button', { name: 'Withdraw', exact: true }).click();
  await page.waitForFunction(() =>
    (window as any).sent.some((m: any) => m.type === 'exchange.withdraw'),
  );
  console.log(
    'EXCHANGE_BROWSER_OK integer order/withdraw commands and free/reserved presentation',
  );

  const criteria = {
    definition_id: 'iron_sword',
    upgrade_min: 7,
    upgrade_max: 9,
    price_min: 0,
    price_max: 5000,
    affix_filters: [
      { stat_id: 'monster_damage', minimum: 10 },
      { stat_id: 'critical_chance', minimum: 5 },
    ],
    sort: 'price_asc',
    cursor: '',
    limit: 20,
  };
  await page.reload();
  await page.waitForFunction(() =>
    (window as any).sent.some((m: any) => m.type === 'ui.ready'),
  );
  await page.evaluate((s) => (window as any).emit('ui.snapshot', s), {
    ...state,
    market_browser: {
      ...browserState,
      criteria,
      catalogQuery: 'Miecz',
      shop: {
        active: true,
        shopId: 2,
        name: 'Offline Shop',
        status: 'active',
        revision: 0,
        columns: 5,
        rows: 8,
        offers: [offer],
        claims: [],
      },
      highlight: offer.id,
    },
    exchange: {
      active: true,
      yang: 1500,
      reservedYang: 200,
      assets: [
        {
          asset_id: 'upgrade_ore',
          name: 'Ore',
          stack_limit: 200,
          free: 100,
          reserved: 0,
        },
      ],
      orders: [],
      depth: [],
      fills: [],
      busy: false,
      retryAvailable: false,
    },
  });
  assert.equal(
    await page.getByLabel('Upgrade from', { exact: true }).inputValue(),
    '7',
  );
  assert.equal(
    await page.getByLabel('Upgrade to', { exact: true }).inputValue(),
    '9',
  );
  assert.equal(
    await page.getByLabel('Base item', { exact: true }).inputValue(),
    'Miecz',
  );
  assert.ok(
    (await page.locator('.market-bonuses').textContent())?.includes('AND'),
  );
  console.log(
    'MARKET_RELOAD_BROWSER_OK criteria/cursor context restored with results',
  );
  for (const [width, height, scale] of [
    [1280, 720, 0.8],
    [1280, 720, 0.9],
    [1920, 1080, 1],
    [2560, 1440, 1],
    [2560, 1440, 1.1],
    [2560, 1440, 1.25],
    [3440, 1440, 1],
    [3440, 1440, 1.1],
    [3840, 2160, 1.25],
    [3840, 2160, 1.5],
  ] as const) {
    await page.setViewportSize({ width, height });
    await page.evaluate((s) => (window as any).emit('hud.updated', s), {
      ...state.hud,
      ui_scale: scale,
      viewport: { width, height },
    });
    await page.waitForTimeout(30);
    for (const selector of [
      '.market-browser-window',
      '.market-visitor-window',
      '.exchange-window',
    ]) {
      const rect = await page.locator(selector).boundingBox();
      assert.ok(
        rect &&
          rect.x >= -1 &&
          rect.y >= -1 &&
          rect.x + rect.width <= width + 1 &&
          rect.y + rect.height <= height + 1,
        selector + ' fits ' + width + ' @ ' + scale,
      );
    }
  }
  assert.deepEqual(errors, []);
  console.log(
    'MARKET_BROWSER_OK module boot, text focus, configure, 10 viewport/scale cases',
  );
} finally {
  await browser.close();
  await new Promise<void>((r) => server.close(() => r()));
}
