// Optional browser acceptance for the actual development host, with no injected test IPC.
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import type { Browser, BrowserType } from 'playwright-core';
import { createPreviewServer } from '../scripts/preview-server.mjs';
const [playwrightModule, browserExecutable, screenshot] = process.argv.slice(2);
if (!playwrightModule || !browserExecutable)
  throw Error('Supply installed Playwright and browser');
const { chromium }: { chromium: BrowserType } = createRequire(import.meta.url)(
  playwrightModule,
);
const server = createPreviewServer();
await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
let browser: Browser | undefined;
try {
  const address = server.address();
  if (!address || typeof address === 'string') throw Error('Missing port');
  const url = `http://127.0.0.1:${address.port}`;
  const directEntry = await fetch(url + '/inventory/game.html', {
    redirect: 'manual',
  });
  assert.equal(directEntry.status, 302);
  assert.equal(directEntry.headers.get('location'), '/web/inventory/game.html');
  assert.equal((await fetch(url + '/..%2fpackage.json')).status, 404);
  assert.equal((await fetch(url + '/__dev/runtime.ts')).status, 404);
  browser = await chromium.launch({
    executablePath: browserExecutable,
    headless: true,
  });
  const page = await browser.newPage({
      viewport: { width: 1600, height: 1000 },
    }),
    errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto(url);
  await page
    .getByText('Ready — production UI with fixture IPC', { exact: true })
    .waitFor();
  const ui = page.frameLocator('iframe');
  for (const close of await ui
    .locator('#private-chat:visible button')
    .filter({ hasText: /^Minimize$/ })
    .all())
    await close.click();
  await page
    .getByRole('button', { name: 'Open Character', exact: true })
    .click();
  await ui.locator('#stats-window').waitFor();
  assert.equal(
    await ui.locator('#stats [data-stat=available_points]').textContent(),
    '4',
  );
  await page.locator('#accept').check();
  await ui.getByRole('button', { name: 'Increase STR', exact: true }).click();
  await ui
    .locator('#stats [data-stat=available_points]')
    .filter({ hasText: '3' })
    .waitFor();
  assert.equal(await ui.locator('#stats [data-stat=STR]').textContent(), '13');
  await page.locator('#accept').uncheck();
  await page
    .getByRole('button', { name: 'Hide Character', exact: true })
    .click();
  const dragItem = ui.locator('#inventory [data-id=preview-use]');
  const dragBox = await dragItem.boundingBox(),
    hotbarBox = await ui.locator('#bottom-hud [data-slot="15"]').boundingBox();
  assert.ok(dragBox && hotbarBox);
  const swordBox = await ui
    .locator('#inventory [data-id=preview-sword]')
    .boundingBox();
  assert.ok(swordBox);
  await page.mouse.move(
    swordBox.x + swordBox.width / 2,
    swordBox.y + swordBox.height / 2,
  );
  await page.mouse.down();
  await page.mouse.move(
    hotbarBox.x + hotbarBox.width / 2,
    hotbarBox.y + hotbarBox.height / 2,
    { steps: 12 },
  );
  await page.mouse.up();
  assert.equal(
    await ui
      .getByRole('button', { name: 'Quick slot F8, empty', exact: true })
      .count(),
    1,
    'EQUIP drop is rejected',
  );

  await page.mouse.move(
    dragBox.x + dragBox.width / 2,
    dragBox.y + dragBox.height / 2,
  );
  await page.mouse.down();
  await page.mouse.move(
    hotbarBox.x + hotbarBox.width / 2,
    hotbarBox.y + hotbarBox.height / 2,
    { steps: 12 },
  );
  await page.mouse.up();
  await ui
    .getByRole('button', {
      name: 'Quick slot F8: Potion (preview)',
      exact: true,
    })
    .waitFor();
  assert.equal(
    await ui.locator('#inventory [data-id=preview-sword]').count(),
    1,
  );
  await ui
    .getByRole('button', {
      name: 'Quick slot F8: Potion (preview)',
      exact: true,
    })
    .click({ button: 'right' });
  await ui
    .getByRole('button', { name: 'Quick slot F8, empty', exact: true })
    .waitFor();
  await ui.locator('#inventory .inventory-item').first().waitFor();
  assert.equal(await ui.locator('#inventory .inventory-item').count(), 4);
  assert.equal(await ui.locator('.wallet strong').textContent(), '12,345');
  await ui.locator('#inventory [data-id=preview-sword]').hover();
  await ui.locator('#inventory .item-tooltip').waitFor({ state: 'visible' });
  assert.equal(
    await ui.locator('#inventory .item-tooltip').getAttribute('data-rarity'),
    'legendary',
  );
  assert.equal(
    await ui
      .locator('#inventory .item-tooltip')
      .evaluate((element) => element.matches(':popover-open')),
    true,
  );
  const focusBeforeDetails = await page.evaluate(
    () => document.activeElement?.tagName,
  );

  assert.equal(
    await ui.locator('#inventory .item-tooltip-affix-kind:visible').count(),
    0,
  );
  await page.keyboard.down('Alt');
  await ui
    .locator('#inventory .item-tooltip-affix-kind')
    .first()
    .waitFor({ state: 'visible' });
  assert.equal(
    await ui.locator('#inventory .item-tooltip-affix-kind:visible').count(),
    6,
  );
  assert.equal(
    await page.evaluate(() => document.activeElement?.tagName),
    focusBeforeDetails,
  );
  await page.keyboard.up('Alt');
  await ui
    .locator('#inventory .item-tooltip-affix-kind')
    .first()
    .waitFor({ state: 'hidden' });

  await page
    .getByRole('button', { name: 'Wallet update', exact: true })
    .click();
  await ui.locator('.wallet strong').filter({ hasText: '54,321' }).waitFor();
  await page
    .getByRole('button', { name: 'Hide Inventory', exact: true })
    .click();
  await ui.locator('#inventory-window').waitFor({ state: 'hidden' });
  await page
    .getByRole('button', { name: 'Open Inventory', exact: true })
    .click();
  await ui.locator('#inventory-window').waitFor({ state: 'visible' });
  await page.selectOption('#scale', '1.25');
  await page.waitForFunction(
    () =>
      document
        .querySelector('iframe')
        ?.contentDocument?.querySelector<HTMLElement>('#inventory')
        ?.style.getPropertyValue('--ui-scale') === '1.25',
  );
  // The persistent HUD shares the snapshot scale and reports only its actual panel as an input region.
  await page.waitForFunction(
    () =>
      document
        .querySelector('iframe')
        ?.contentDocument?.querySelector<HTMLElement>('#bottom-hud')
        ?.style.getPropertyValue('--ui-scale') === '1.25',
  );
  assert.equal(
    await ui.locator('#bottom-hud').evaluate((root) => {
      const style = getComputedStyle(root);
      return (
        style.pointerEvents === 'none' &&
        new DOMMatrixReadOnly(style.transform).a === 1.25
      );
    }),
    true,
  );
  await ui.locator('.inventory-item').first().click({ button: 'right' });
  await ui
    .locator('#inventory .inventory-status')
    .filter({ hasText: 'preview_rejected' })
    .waitFor();
  await page.locator('pre').filter({ hasText: 'item.activate' }).waitFor();
  assert.match(
    (await page.locator('pre').textContent()) ?? '',
    /item.activate/,
  );
  await page.locator('#accept').check();
  await ui.locator('#inventory .window-close').click();
  await ui.locator('#inventory-window').waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Empty items', exact: true }).click();
  await page.waitForFunction(
    () =>
      document
        .querySelector('iframe')
        ?.contentDocument?.querySelectorAll('#inventory .inventory-item')
        .length === 0,
  );
  await page
    .getByRole('button', { name: 'Reset fixtures', exact: true })
    .click();
  await ui.locator('#inventory-window').waitFor({ state: 'visible' });
  assert.equal(await ui.locator('#inventory .inventory-item').count(), 4);
  assert.equal(await page.locator('#scale').inputValue(), '1');
  const storage = ui.locator('#storage');
  await ui.locator('#storage-window').waitFor({ state: 'visible' });
  assert.equal(await storage.locator('.cell').count(), 135);
  assert.equal(await storage.locator('.ui-item-slot').count(), 3);
  await storage.locator('.ui-item-slot').first().hover();
  assert.equal(await storage.locator('.ui-tooltip').isVisible(), true);
  await storage.getByRole('tab', { name: 'II', exact: true }).click();
  assert.equal(await storage.locator('.ui-tooltip').isVisible(), false);
  assert.equal(await storage.locator('.ui-item-slot').count(), 2);
  await storage.locator('.window-close').click();
  await ui.locator('#storage-window').waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Open Storage', exact: true }).click();
  await ui.locator('#storage-window').waitFor({ state: 'visible' });
  assert.ok(
    await ui
      .locator('#storage')
      .evaluate(
        (node) =>
          Number(getComputedStyle(node).zIndex) >
          Number(
            getComputedStyle(document.getElementById('inventory') ?? node)
              .zIndex,
          ),
      ),
  );
  await page.setViewportSize({ width: 1100, height: 700 });
  await page.selectOption('#scale', '1.5');
  await page.waitForFunction(
    () =>
      document
        .querySelector('iframe')
        ?.contentDocument?.querySelector<HTMLElement>('#storage')
        ?.style.getPropertyValue('--ui-scale') === '1.5',
  );
  const storageBounds = await ui.locator('#storage-window').boundingBox();
  const viewportBounds = await page.locator('iframe').boundingBox();
  assert.ok(storageBounds);
  assert.ok(viewportBounds);
  assert.ok(
    storageBounds.x >= viewportBounds.x - 1 &&
      storageBounds.x + storageBounds.width <=
        viewportBounds.x + viewportBounds.width + 1,
  );
  await storage.locator('.storage-grid-viewport').evaluate((node) => {
    node.scrollLeft = node.scrollWidth;
  });
  // Restore full viewport for transfer gestures; scaled narrow-grid scrolling checked above.
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.selectOption('#scale', '1');
  await page
    .getByRole('button', { name: 'Reset fixtures', exact: true })
    .click();
  await storage.getByRole('tab', { name: 'I', exact: true }).click();
  const inventory = ui.locator('#inventory');
  // With Storage open, a bag-only move must use the normal Inventory command.
  const bagItem = inventory.locator('[data-id=preview-armor]');
  const bagOrigin = await bagItem.boundingBox(),
    bagGrid = await inventory.locator('.inventory-grid').boundingBox();
  assert.ok(bagOrigin);
  assert.ok(bagGrid);
  await page
    .getByRole('button', { name: 'Clear command log', exact: true })
    .click();
  await page.mouse.move(bagOrigin.x + 10, bagOrigin.y + 10);
  await page.mouse.down();
  await page.mouse.move(bagGrid.x + 4 * 40 + 10, bagGrid.y + 4 * 40 + 10, {
    steps: 5,
  });
  await page.mouse.up();
  await page.waitForFunction(() =>
    document.querySelector('pre')?.textContent?.includes('inventory.move_item'),
  );
  assert.equal(await bagItem.evaluate((node) => node.style.left), '161px');
  assert.equal(
    (await page.locator('pre').textContent())?.includes('storage.transfer'),
    false,
  );
  await inventory
    .locator('[data-id=preview-material]')
    .click({ modifiers: ['Control'] });
  await storage.locator('[data-id=preview-material]').waitFor();
  assert.equal(
    await inventory.locator('[data-id=preview-material]').count(),
    0,
  );
  await storage
    .locator('[data-id=preview-material]')
    .click({ modifiers: ['Control'] });
  await inventory.locator('[data-id=preview-material]').waitFor();
  assert.equal(await storage.locator('[data-id=preview-material]').count(), 0);
  const sword = storage.locator('[data-id=stored-sword]');
  async function dragToCell(x: number, y: number) {
    const origin = await sword.boundingBox(),
      destination = await storage.locator('.storage-grid').boundingBox();
    assert.ok(origin);
    assert.ok(destination);
    await page.mouse.move(origin.x + 10, origin.y + 10);
    await page.mouse.down();
    await page.mouse.move(
      destination.x + x * 40 + 10,
      destination.y + y * 40 + 10,
      { steps: 5 },
    );
    await page.mouse.up();
  }
  // Tall footprint cannot cross bottom edge; item remains anchored.
  await dragToCell(4, 8);
  assert.equal(await sword.evaluate((node) => node.style.left), '1px');
  await dragToCell(4, 3);
  assert.equal(await sword.evaluate((node) => node.style.left), '161px');
  // Click-to-carry, change page, then click a valid cell.
  await sword.click({ position: { x: 10, y: 10 } });
  await storage.getByRole('tab', { name: 'II', exact: true }).click();
  const gridBox = await storage.locator('.storage-grid').boundingBox();
  assert.ok(gridBox);
  await page.mouse.click(gridBox.x + 5 * 40 + 10, gridBox.y + 1 * 40 + 10);
  await storage.locator('[data-id=stored-sword]').waitFor();
  assert.equal(await sword.evaluate((node) => node.style.top), '41px');
  // Cross-window drag uses the same footprint and updates both snapshots.
  const material = inventory.locator('[data-id=preview-material]');
  const materialBox = await material.boundingBox(),
    storageBox = await storage.locator('.storage-grid').boundingBox();
  assert.ok(materialBox);
  assert.ok(storageBox);
  await page.mouse.move(materialBox.x + 10, materialBox.y + 10);
  await page.mouse.down();
  await page.mouse.move(storageBox.x + 8 * 40 + 10, storageBox.y + 10, {
    steps: 8,
  });
  await page.mouse.up();
  await storage.locator('[data-id=preview-material]').waitFor();
  assert.equal(
    await inventory.locator('[data-id=preview-material]').count(),
    0,
  );
  await page.selectOption('#scale', '1.25');
  await page.waitForFunction(
    () =>
      document
        .querySelector('iframe')
        ?.contentDocument?.querySelector<HTMLElement>('#storage')
        ?.style.getPropertyValue('--ui-scale') === '1.25',
  );
  const scaledSword = await sword.boundingBox(),
    scaledGrid = await storage.locator('.storage-grid').boundingBox();
  assert.ok(scaledSword);
  assert.ok(scaledGrid);
  await page.mouse.move(scaledSword.x + 10 * 1.25, scaledSword.y + 10 * 1.25);
  await page.mouse.down();
  await page.mouse.move(
    scaledGrid.x + (9 * 40 + 10) * 1.25,
    scaledGrid.y + (2 * 40 + 10) * 1.25,
    { steps: 5 },
  );
  await page.mouse.up();
  assert.equal(await sword.evaluate((node) => node.style.left), '361px');
  // Exact withdrawal hits the real Inventory grid at the current scale.
  const withdrawing = await storage
      .locator('[data-id=preview-material]')
      .boundingBox(),
    receiving = await inventory.locator('.inventory-grid').boundingBox();
  assert.ok(withdrawing);
  assert.ok(receiving);
  await page.mouse.move(withdrawing.x + 10 * 1.25, withdrawing.y + 10 * 1.25);
  await page.mouse.down();
  await page.mouse.move(
    receiving.x + (3 * 40 + 10) * 1.25,
    receiving.y + (5 * 40 + 10) * 1.25,
    { steps: 5 },
  );
  assert.equal(
    await inventory.locator('.placement-preview.invalid').count(),
    0,
  );
  assert.equal(await inventory.locator('.placement-preview').isVisible(), true);
  await page.mouse.up();
  await inventory.locator('[data-id=preview-material]').waitFor();
  assert.equal(
    await inventory
      .locator('[data-id=preview-material]')
      .evaluate((node) => node.style.left),
    '121px',
  );
  assert.equal(
    await inventory
      .locator('[data-id=preview-material]')
      .evaluate((node) => node.style.top),
    '201px',
  );
  await page.selectOption('#scale', '1');
  await page.waitForFunction(
    () =>
      document
        .querySelector('iframe')
        ?.contentDocument?.querySelector<HTMLElement>('#storage')
        ?.style.getPropertyValue('--ui-scale') === '1',
  );
  // Escape cancels before applying a transfer.
  await sword.click({ position: { x: 10, y: 10 } });
  await page.keyboard.press('Escape');
  assert.equal(await ui.locator('.carried-item').isVisible(), false);
  assert.equal(await sword.evaluate((node) => node.style.top), '81px');
  await sword.click({ position: { x: 10, y: 10 } });
  await storage.locator('.window-close').click();
  assert.equal(await ui.locator('.carried-item').isVisible(), false);
  await ui.locator('#storage-window').waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Hide Storage', exact: true }).click();
  await ui.locator('#storage-window').waitFor({ state: 'hidden' });
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.reload();
  await page
    .getByText('Ready — production UI with fixture IPC', { exact: true })
    .waitFor();
  // Preview composition enforces the same lifecycle as the native client.
  await page
    .getByRole('button', { name: 'Hide Inventory', exact: true })
    .click();
  await ui.locator('#inventory-window').waitFor({ state: 'hidden' });
  await ui.locator('#storage-window').waitFor({ state: 'hidden' });
  await page.getByRole('button', { name: 'Open Storage', exact: true }).click();
  await ui.locator('#inventory-window').waitFor({ state: 'visible' });
  await ui.locator('#storage-window').waitFor({ state: 'visible' });
  await page.locator('#accept').check();
  await ui.locator('#inventory .window-close').click();
  await ui.locator('#inventory-window').waitFor({ state: 'hidden' });
  await ui.locator('#storage-window').waitFor({ state: 'hidden' });
  await page
    .getByRole('button', { name: 'Reset fixtures', exact: true })
    .click();
  await page
    .getByRole('button', { name: 'Hide Inventory', exact: true })
    .click();
  await page
    .getByRole('button', { name: 'Hide Equipment', exact: true })
    .click();
  await ui.locator('#private-chat-window').waitFor({ state: 'visible' });
  assert.equal(await ui.locator('.chat-whisper').count(), 1);
  const chatInput = ui.getByRole('textbox', {
    name: 'Chat message',
    exact: true,
  });
  await chatInput.fill('Hello from offline preview');
  await chatInput.press('Enter');
  await ui
    .locator('#chat .chat-line')
    .filter({ hasText: 'Hello from offline preview' })
    .waitFor();
  await ui
    .locator('#private-chat')
    .getByRole('button', { name: 'Minimize', exact: true })
    .click();
  await ui.locator('.whisper-envelope').waitFor({ state: 'visible' });
  await page
    .getByRole('button', { name: 'Incoming whisper', exact: true })
    .click();
  await ui.locator('.whisper-envelope[title="Baek: 2"]').waitFor();
  await ui.locator('.whisper-envelope').click();
  const whisper = ui.getByRole('textbox', {
    name: 'Message Baek',
    exact: true,
  });
  await whisper.fill('Private preview reply');
  await whisper.press('Enter');
  await ui
    .locator('#whisper-3 .chat-line')
    .filter({ hasText: 'Private preview reply' })
    .waitFor();
  await whisper.press('Escape');
  assert.equal(
    await whisper.evaluate((el) => document.activeElement === el),
    false,
  );
  await ui
    .getByRole('button', { name: 'Find whisper player', exact: true })
    .click();
  const name = ui.getByRole('textbox', {
    name: 'Whisper player name',
    exact: true,
  });
  await name.fill('Yuna');
  await name.press('Enter');
  await ui.locator('#private-chat-window').waitFor({ state: 'visible' });
  assert.equal(await ui.locator('#whisper-2').count(), 1);
  const yunaDraft = ui.getByRole('textbox', {
    name: 'Message Yuna',
    exact: true,
  });
  await yunaDraft.fill('Draft for Yuna');
  const privateWindow = ui.locator('#private-chat-window');
  const beforeDrag = await privateWindow.boundingBox();
  const dragSpace = await ui
    .locator('#private-chat .whisper-tabs')
    .boundingBox();
  assert.ok(beforeDrag && dragSpace);
  await page.mouse.move(
    dragSpace.x + dragSpace.width - 8,
    dragSpace.y + dragSpace.height / 2,
  );
  await page.mouse.down();
  await page.mouse.move(dragSpace.x + dragSpace.width + 32, dragSpace.y - 25, {
    steps: 5,
  });
  await page.mouse.up();
  const afterDrag = await privateWindow.boundingBox();
  assert.ok(
    afterDrag && afterDrag.x > beforeDrag.x && afterDrag.y < beforeDrag.y,
    'empty tab rail drags the private window',
  );

  await ui.getByRole('tab', { name: 'Baek', exact: true }).click();
  await whisper.waitFor({ state: 'visible' });
  await whisper.fill('Draft for Baek');
  await ui.getByRole('tab', { name: 'Yuna', exact: true }).click();
  await yunaDraft.waitFor({ state: 'visible' });
  assert.equal(await yunaDraft.inputValue(), 'Draft for Yuna');
  await yunaDraft.focus();
  await page
    .getByRole('button', { name: 'Incoming whisper', exact: true })
    .click();
  await ui.getByRole('tab', { name: 'Baek · 1', exact: true }).waitFor();
  assert.equal(
    await ui
      .getByRole('tab', { name: 'Yuna', exact: true })
      .getAttribute('aria-selected'),
    'true',
  );
  await ui.getByRole('tab', { name: 'Baek · 1', exact: true }).click();
  await whisper.waitFor({ state: 'visible' });
  assert.equal(await whisper.inputValue(), 'Draft for Baek');
  await ui.getByRole('tab', { name: 'Yuna', exact: true }).click();

  await page
    .getByRole('button', { name: 'Incoming chat', exact: true })
    .click();
  await ui
    .locator('#chat .chat-line')
    .filter({ hasText: 'A new public message' })
    .waitFor();
  await ui.locator('#bottom-hud .bottom-hud-slot').first().waitFor();
  assert.equal(await ui.locator('#bottom-hud .bottom-hud-slot').count(), 16);
  await page
    .getByRole('button', { name: 'Sample hotbar', exact: true })
    .click();
  await ui
    .getByRole('button', {
      name: 'Quick slot 1: Potion (preview)',
      exact: true,
    })
    .waitFor();
  await page.getByRole('button', { name: 'Empty hotbar', exact: true }).click();
  await ui
    .locator('#bottom-hud .assigned')
    .first()
    .waitFor({ state: 'hidden' });
  assert.equal(await ui.locator('#bottom-hud .assigned').count(), 0);
  await page
    .getByRole('button', { name: 'Sample hotbar', exact: true })
    .click();
  await ui
    .getByRole('button', {
      name: 'Quick slot 1: Potion (preview)',
      exact: true,
    })
    .waitFor();

  await page
    .getByRole('button', { name: 'Sample vendor', exact: true })
    .click();
  await ui.locator('#vendor-window').waitFor({ state: 'visible' });
  await ui
    .locator('#inventory')
    .getByRole('tab', { name: 'I', exact: true })
    .click();
  const beforeBooks = await ui.locator('#inventory .inventory-item').count();
  for (let i = 0; i < 5; i++) {
    const source = await ui
      .locator(`#inventory [data-id="preview-book-${i}"]`)
      .boundingBox();
    const destination = await ui
      .locator('#vendor .vendor-basket')
      .boundingBox();
    assert.ok(source && destination);
    await page.mouse.move(
      source.x + source.width / 2,
      source.y + source.height / 2,
    );
    await page.mouse.down();
    await page.mouse.move(
      destination.x + destination.width / 2,
      destination.y + destination.height / 2,
      { steps: 12 },
    );
    await page.mouse.up();
    await ui.locator('#vendor .vendor-item').nth(i).waitFor();
  }
  assert.equal(
    await ui.locator('#inventory .inventory-item').count(),
    beforeBooks,
    'basket assignment never removes Inventory items',
  );
  await ui
    .getByRole('img', { name: 'Random Skill Book ×1', exact: true })
    .waitFor();
  await ui
    .getByRole('img', { name: 'Random Skill Book ×1', exact: true })
    .hover();
  await ui
    .locator('#vendor .item-tooltip')
    .filter({ hasText: 'drawn only when the sale commits' })
    .waitFor();
  const offerOrder = await ui
    .locator('#vendor .vendor-item')
    .evaluateAll((nodes) => nodes.map((n) => n.getAttribute('aria-label')));
  await ui
    .locator('#inventory [data-id="preview-book-0"]')
    .click({ modifiers: ['Control'] });
  assert.deepEqual(
    await ui
      .locator('#vendor .vendor-item')
      .evaluateAll((nodes) => nodes.map((n) => n.getAttribute('aria-label'))),
    offerOrder,
  );
  await ui
    .locator('#vendor .vendor-item')
    .first()
    .click({ modifiers: ['Control'] });
  assert.equal(await ui.locator('#vendor .vendor-item').count(), 4);
  await ui
    .locator('#inventory [data-id="preview-book-0"]')
    .click({ modifiers: ['Control'] });
  await ui.locator('#vendor .vendor-item').nth(4).waitFor();
  await ui.getByRole('button', { name: 'Confirm sale', exact: true }).click();
  await ui
    .locator('#vendor [role=status]')
    .filter({ hasText: 'preview_native_only' })
    .waitFor();
  await ui
    .getByRole('button', { name: 'Offered Skill Book 1', exact: true })
    .click({ button: 'right' });
  assert.equal(await ui.locator('#vendor .vendor-item').count(), 4);
  await ui
    .locator('#inventory [data-id="preview-book-0"]')
    .click({ modifiers: ['Control'] });
  await ui.locator('#vendor .vendor-item').nth(4).waitFor();

  assert.equal(
    await ui.locator('#inventory .inventory-item').count(),
    beforeBooks,
  );
  if (screenshot) await page.screenshot({ path: screenshot, fullPage: true });
  await ui.locator('#bottom-hud').waitFor({ state: 'visible' });
  assert.deepEqual(errors, []);
  console.log(
    'Browser development preview: PASS (CSP, fixtures, selective updates, commands, reload)',
  );
} finally {
  await browser?.close();
  await new Promise<void>((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
}
