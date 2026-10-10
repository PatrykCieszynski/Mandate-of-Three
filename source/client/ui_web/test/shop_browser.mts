// Optional real-browser milestone check. No screenshot/pixel assertions or accounts.
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import type { Browser, BrowserType } from 'playwright-core';
import type { DomainSnapshot, Envelope } from '../web/protocol/contracts.js';
import type { ShopSnapshot } from '../web/screens/shop/shop-model.js';
import type { NpcInteractionSnapshot } from '../web/screens/npc/npc-model.js';
declare global {
  interface Window {
    shopFixture: DomainSnapshot;
    acceptShopBuy: boolean;
  }
}
const [playwrightModule, browserExecutable, screenshotDirectory] =
  process.argv.slice(2);
if (!playwrightModule || !browserExecutable)
  throw Error('Pass installed Playwright module and browser executable');
const { chromium }: { chromium: BrowserType } = createRequire(import.meta.url)(
  playwrightModule,
);
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
    if (!file.startsWith(root + path.sep)) throw Error('Outside UI root');
    const types: Record<string, string> = {
      '.html': 'text/html',
      '.js': 'text/javascript',
      '.css': 'text/css',
      '.png': 'image/png',
    };
    res.setHeader(
      'Content-Type',
      types[path.extname(file)] ?? 'application/octet-stream',
    );
    res.end(await readFile(file));
  } catch {
    res.statusCode = 404;
    res.end();
  }
});
const npc: Extract<NpcInteractionSnapshot, { active: true }> = {
  active: true,
  npcInstanceId: 'spike-blacksmith-01',
  npcDefinitionId: 'blacksmith',
  name: 'Blacksmith',
  selectedServiceId: '',
  services: [
    { id: 'upgrade', kind: 1, label: 'Upgrade', enabled: true },
    { id: 'weapon_shop', kind: 0, label: 'Weapon Shop', enabled: true },
  ],
};
const shop: Extract<ShopSnapshot, { active: true }> = {
  active: true,
  npcInstanceId: npc.npcInstanceId,
  serviceId: 'weapon_shop',
  shopId: 'blacksmith_weapon_shop',
  name: 'Blacksmith Weapons',
  currency: 'yang',
  offers: [
    {
      offerId: 'iron_sword',
      itemDefinitionId: 'iron_sword',
      name: 'Iron Sword',
      iconId: 'iron_sword',
      height: 2,
      quantity: 1,
      price: 1000,
      description: 'Forged steel.',
    },
  ],
};
const snapshot: DomainSnapshot = {
  npc,
  shop: { active: false },
  hud: {
    inventory_open: false,
    equipment_open: false,
    storage_open: false,
    ui_scale: 1,
  },
  wallet: { balance: 2500, ready: true },
  inventory: {
    columns: 5,
    rows: 9,
    pages: 4,
    items: [
      {
        id: 'existing',
        revision: 0,
        name: 'Iron Sword +0',
        icon_id: 'iron_sword',
        height: 2,
        quantity: 1,
        x: 0,
        y: 0,
        page: 0,
      },
    ],
  },
};
async function verify(browser: Browser, url: string, fallback: boolean) {
  const page = await browser.newPage({
      viewport: { width: 1280, height: 720 },
    }),
    errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  try {
    if (fallback)
      await page.route('**/legacy_skin/skin.js', (route) =>
        route.fulfill({ status: 404, body: '' }),
      );
    await page.addInitScript((shop) => {
      window.sent = [];
      window.acceptShopBuy = false;
      const receivers: ((raw: unknown) => void)[] = [];
      window.ipcMessage = { addListener: (fn) => receivers.push(fn) };
      window.emit = (type, payload, id) =>
        receivers.forEach((fn) =>
          fn(JSON.stringify({ v: 1, type, payload, ...(id ? { id } : {}) })),
        );
      window.sendIpcMessage = (raw) => {
        const message = JSON.parse(raw) as Envelope;
        sent.push(message);
        if (!message.id) return;
        queueMicrotask(() => {
          const state = window.shopFixture;
          switch (message.type) {
            case 'npc.select_service':
              if (state.npc?.active) {
                state.npc.selectedServiceId = String(
                  message.payload.service_id,
                );
                emit('npc.updated', state.npc);
              }
              break;
            case 'shop.open':
              state.shop = state.shop?.active ? state.shop : shop;
              state.hud = { ...state.hud, inventory_open: true };
              emit('hud.updated', state.hud);
              emit('shop.updated', state.shop);
              break;
            case 'npc.clear_service':
              state.shop = { active: false };
              if (state.npc?.active) state.npc.selectedServiceId = '';
              emit('shop.updated', state.shop);
              emit('npc.updated', state.npc ?? { active: false });
              break;
            case 'npc.close':
              state.shop = { active: false };
              state.npc = { active: false };
              emit('shop.updated', state.shop);
              emit('npc.updated', state.npc);
              break;
          }
          emit(
            'command.result',
            message.type === 'shop.buy' && !window.acceptShopBuy
              ? { ok: false, error: 'funds' }
              : { ok: true },
            message.id,
          );
        });
      };
    }, shop);
    await page.goto(url);
    await page.waitForFunction(() => sent.some((m) => m.type === 'ui.ready'));
    const send = (state: DomainSnapshot) =>
      page.evaluate((state) => {
        window.shopFixture = state;
        emit('ui.snapshot', state);
      }, state);
    const clear = () =>
      page.evaluate(() => {
        sent = [];
      });
    const buys = () =>
      page.evaluate(() => sent.filter((m) => m.type === 'shop.buy'));
    const frame = () =>
      page.evaluate(
        () => new Promise<number>((resolve) => requestAnimationFrame(resolve)),
      );
    const capture = async (name: string) => {
      if (screenshotDirectory) {
        await mkdir(screenshotDirectory, { recursive: true });
        await page.screenshot({
          path: path.join(screenshotDirectory, name + '.png'),
        });
      }
    };
    await send(snapshot);
    await page
      .getByRole('button', { name: 'Weapon Shop', exact: true })
      .waitFor();
    const menuBounds = await page
      .locator('#npc-menu-window')
      .evaluate((panel) => {
        const rect = panel.getBoundingClientRect(),
          style = getComputedStyle(panel),
          scale = rect.width / (panel as HTMLElement).offsetWidth;
        return [...panel.querySelectorAll('.npc-service')].every((row) => {
          const box = row.getBoundingClientRect();
          return (
            box.left >= rect.left + parseFloat(style.paddingLeft) * scale - 1 &&
            box.right <=
              rect.right - parseFloat(style.paddingRight) * scale + 1 &&
            box.bottom <=
              rect.bottom - parseFloat(style.paddingBottom) * scale + 1
          );
        });
      });
    assert.equal(menuBounds, true, 'Every service stays inside its frame');
    await page.evaluate(() => {
      document.body.style.background = '#253540';
    });
    await capture('npc-services-' + (fallback ? 'fallback' : 'legacy'));
    await page
      .getByRole('button', { name: 'Weapon Shop', exact: true })
      .click();
    await page.locator('#shop-window').waitFor({ state: 'visible' });
    assert.equal(
      await page.locator('#inventory-window').isVisible(),
      true,
      'Shop opens Inventory',
    );
    assert.equal(
      await page.locator('#npc-service').isVisible(),
      false,
      'SHOP has its own window',
    );
    assert.equal(
      await page.locator('.shop-price').count(),
      0,
      'Price belongs to the offer tooltip',
    );
    assert.equal(await page.locator('.shop-quantity').textContent(), '×1');
    assert.equal(
      await page.locator('#shop .ui-currency strong').textContent(),
      '2,500',
    );
    // Check real content against its shared frame padding, without exact geometry assertions.
    const checkBounds = async () => {
      const valid = await page.locator('#shop-window').evaluate((panel) => {
        const rect = panel.getBoundingClientRect(),
          style = getComputedStyle(panel),
          scale = rect.width / (panel as HTMLElement).offsetWidth;
        const left = rect.left + parseFloat(style.paddingLeft) * scale,
          right = rect.right - parseFloat(style.paddingRight) * scale,
          bottom = rect.bottom - parseFloat(style.paddingBottom) * scale;
        return [
          ...panel.querySelectorAll(
            '.shop-offers,.shop-hint,.ui-currency,.shop-status',
          ),
        ].every((node) => {
          const box = node.getBoundingClientRect();
          return (
            box.left >= left - 1 &&
            box.right <= right + 1 &&
            box.bottom <= bottom + 1
          );
        });
      });
      assert.equal(
        valid,
        true,
        'Offer, quantity, wallet and feedback stay inside the frame',
      );
    };
    await clear();
    await page.locator('#shop .shop-item').click({ button: 'right' });
    await page.waitForFunction(() => sent.some((m) => m.type === 'shop.buy'));
    assert.deepEqual((await buys())[0]?.payload, {
      npc_instance_id: npc.npcInstanceId,
      service_id: 'weapon_shop',
      offer_id: 'iron_sword',
    });
    await page.getByText('Not enough Yang.', { exact: true }).waitFor();
    await checkBounds();
    assert.equal(await page.locator('.inventory-item').count(), 1);
    // Real hit testing chooses the deeper grid, preserving exact placement.
    const scale = 1,
      grid = await page.locator('.inventory-grid').boundingBox();
    assert.ok(grid);
    const source = () => page.locator('#shop .shop-item');
    const drag = async (x: number, y: number, fromRight = false) => {
      const box = await source().boundingBox();
      assert.ok(box);
      await page.mouse.move(
        fromRight ? box.x + box.width - 10 : box.x + 10 * scale,
        box.y + 10 * scale,
      );
      await page.mouse.down();
      await page.mouse.move(x, y, { steps: 6 });
    };
    await clear();
    await drag(grid.x + 90, grid.y + 130);
    assert.equal(await page.locator('.placement-preview.invalid').count(), 0);
    await page.mouse.up();
    await page.waitForFunction(() => sent.some((m) => m.type === 'shop.buy'));
    assert.deepEqual((await buys())[0]?.payload, {
      npc_instance_id: npc.npcInstanceId,
      service_id: 'weapon_shop',
      offer_id: 'iron_sword',
      x: 2,
      y: 3,
      page: 0,
    });
    await clear();
    await drag(grid.x + 90, grid.y + 130, true);
    const ghost = await page.locator('.carried-item').boundingBox();
    assert.ok(
      ghost && ghost.x <= grid.x + 90 && ghost.x + ghost.width >= grid.x + 90,
      'Offer carried from the far edge stays under the cursor',
    );
    if (!fallback) {
      assert.equal(
        await page
          .locator('.carried-item .item-icon')
          .evaluate(
            (image) =>
              image instanceof HTMLImageElement &&
              image.complete &&
              image.naturalWidth > 0,
          ),
        true,
      );
    }
    await page.mouse.up();
    await page.waitForFunction(() => sent.some((m) => m.type === 'shop.buy'));
    assert.deepEqual((await buys())[0]?.payload, {
      npc_instance_id: npc.npcInstanceId,
      service_id: 'weapon_shop',
      offer_id: 'iron_sword',
      x: 2,
      y: 3,
      page: 0,
    });
    await clear();
    await drag(grid.x + 10, grid.y + 10);
    assert.equal(
      await page.locator('.placement-preview.invalid').isVisible(),
      true,
    );
    await page.mouse.up();
    await frame();
    assert.equal((await buys()).length, 0);
    await clear();
    await drag(grid.x + 90, grid.y + 330);
    assert.equal(
      await page.locator('.placement-preview.invalid').isVisible(),
      true,
    );
    await page.mouse.up();
    await frame();
    assert.equal((await buys()).length, 0);
    const wallet = await page.locator('#inventory .wallet').boundingBox();
    assert.ok(wallet);
    await drag(wallet.x + wallet.width / 2, wallet.y + wallet.height / 2);
    assert.equal(
      await page.locator('.inventory-receive-preview').isVisible(),
      true,
    );
    await capture('shop-receive-' + (fallback ? 'fallback' : 'legacy'));
    await page.mouse.up();
    await page.waitForFunction(() => sent.some((m) => m.type === 'shop.buy'));
    assert.deepEqual((await buys())[0]?.payload, {
      npc_instance_id: npc.npcInstanceId,
      service_id: 'weapon_shop',
      offer_id: 'iron_sword',
    });
    // A successful acknowledgement still waits for authoritative Inventory publication.
    await page.evaluate(() => {
      window.acceptShopBuy = true;
    });
    await source().click({ button: 'right' });
    await frame();
    assert.equal(await page.locator('.inventory-item').count(), 1);
    await send({ ...snapshot, npc: { active: false } });
    const selected: DomainSnapshot = {
      ...snapshot,
      npc: { ...npc, selectedServiceId: 'weapon_shop' },
      shop,
      hud: { ...snapshot.hud, inventory_open: true },
    };
    for (const [width, height, scale] of [
      [1920, 1080, 1],
      [1280, 720, 0.9],
      [1280, 720, 1],
      [960, 540, 1.25],
      [960, 540, 1.5],
    ] as const) {
      await page.setViewportSize({ width, height });
      await send({ ...selected, hud: { ...selected.hud, ui_scale: scale } });
      await frame();
      await checkBounds();
      const box = await page.locator('#shop-window').boundingBox(),
        inventory = await page.locator('#inventory-window').boundingBox();
      assert.ok(box);
      assert.ok(inventory);
      assert.ok(
        box.x >= -1 &&
          box.y >= -1 &&
          box.x + box.width <= width + 1 &&
          box.y + box.height <= height + 1,
        'Shop remains reachable in viewport',
      );
      assert.ok(
        box.x + box.width <= inventory.x + 1,
        'Initial Shop placement leaves Inventory unobscured',
      );
      if (
        (width === 1280 && scale === 1) ||
        (width === 960 && scale === 1.25)
      ) {
        await page.evaluate(() => {
          document.body.style.background = '#253540';
        });
        await capture(
          `shop-${width}-${scale}-${fallback ? 'fallback' : 'legacy'}`,
        );
      }
    }
    await page.setViewportSize({ width: 1280, height: 720 });
    await send(selected);
    await frame();
    await source().hover();
    await page.locator('#shop .item-tooltip').waitFor({ state: 'visible' });
    assert.equal(
      await page.locator('#shop .item-tooltip-price').textContent(),
      'Buy price: 1,000 Yang',
    );
    assert.equal(
      await page.locator('#shop .item-tooltip p').textContent(),
      'Forged steel.',
    );
    const tooltipOrder = await page
      .locator('#shop .item-tooltip')
      .evaluate((tip) =>
        tip.lastElementChild?.classList.contains('item-tooltip-price'),
      );
    assert.equal(tooltipOrder, true, 'Offer price is the tooltip footer');
    await capture('shop-tooltip-' + (fallback ? 'fallback' : 'legacy'));
    await page.mouse.move(0, 0);
    await page.locator('#shop .window-close').click();
    await page
      .getByRole('button', { name: 'Weapon Shop', exact: true })
      .waitFor();
    assert.equal(await page.locator('#inventory-window').isVisible(), true);
    await page
      .getByRole('button', { name: 'Weapon Shop', exact: true })
      .click();
    await page.locator('#shop-window').waitFor({ state: 'visible' });
    await source().click();
    await page.keyboard.press('Escape');
    assert.equal(
      await page.locator('#shop-window').isVisible(),
      true,
      'Escape cancels carry first',
    );
    await page.keyboard.press('Escape');
    await page
      .getByRole('button', { name: 'Weapon Shop', exact: true })
      .waitFor();
    await page.keyboard.press('Escape');
    await page.locator('#npc-menu').waitFor({ state: 'hidden' });
    await send({ ...snapshot, npc: { ...npc, services: [npc.services[1]!] } });
    await page.locator('#shop-window').waitFor({ state: 'visible' });
    await page.locator('#shop .window-close').click();
    await page.locator('#npc-menu').waitFor({ state: 'hidden' });
    assert.equal(await page.locator('#shop-window').isVisible(), false);
    // Many authored offers scroll within the same shell; no separate layout content.
    await send({
      ...selected,
      shop: {
        ...shop,
        offers: Array.from({ length: 12 }, (_, i) => ({
          ...shop.offers[0]!,
          offerId: 'offer_' + i,
          name: 'Tempered Iron Sword ' + i,
          quantity: i + 1,
          price: 1000 + i,
        })),
      },
    });
    await frame();
    assert.equal(await page.locator('.shop-offer').count(), 12);
    await page.locator('.shop-offer').last().scrollIntoViewIfNeeded();
    assert.equal(
      await page.locator('.shop-offers').evaluate((list) => list.scrollTop > 0),
      true,
      'Last offer requires scrolling inside the list',
    );
    await checkBounds();
    assert.equal(await page.locator('.shop-offer').last().isVisible(), true);
    await capture('shop-many-offers-' + (fallback ? 'fallback' : 'legacy'));
    assert.deepEqual(errors, []);
    console.log(
      `Shop real browser: PASS (${fallback ? 'CSS fallback' : 'legacy skin'}, service/offer lists, bounds/scales, right-click, exact/receive drops, tooltip, scroll and back)`,
    );
  } finally {
    await page.close();
  }
}
await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
let browser: Browser | undefined;
try {
  browser = await chromium.launch({
    executablePath: browserExecutable,
    headless: true,
  });
  const address = server.address();
  if (!address || typeof address === 'string')
    throw Error('Missing local port');
  const url = `http://127.0.0.1:${address.port}/inventory/game.html`;
  await verify(browser, url, false);
  await verify(browser, url, true);
} finally {
  await browser?.close();
  await new Promise<void>((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
}
