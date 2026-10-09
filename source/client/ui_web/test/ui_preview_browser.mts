// Optional browser acceptance for the actual development host, with no injected test IPC.
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
import type { Browser, BrowserType } from 'playwright-core';
import { createPreviewServer } from '../scripts/preview-server.mjs';
const [playwrightModule, browserExecutable] = process.argv.slice(2);
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
  await ui.locator('#inventory .inventory-item').first().waitFor();
  assert.equal(await ui.locator('#inventory .inventory-item').count(), 3);
  assert.equal(await ui.locator('.wallet strong').textContent(), '12,345');
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
  await ui.locator('.inventory-item').first().click({ button: 'right' });
  await ui
    .locator('#inventory .inventory-status')
    .filter({ hasText: 'preview_rejected' })
    .waitFor();
  assert.match(
    (await page.locator('pre').textContent()) ?? '',
    /equipment.equip/,
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
  assert.equal(await ui.locator('#inventory .inventory-item').count(), 3);
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
  await storage.locator('[data-id=stored-page-two]').click();
  await page.waitForFunction(() =>
    document.querySelector('pre')?.textContent?.includes('storage.item_action'),
  );
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
  await storage.locator('[data-id=stored-page-two-stack]').click();
  await page.waitForFunction(() =>
    document
      .querySelector('pre')
      ?.textContent?.includes('stored-page-two-stack'),
  );
  await page.getByRole('button', { name: 'Hide Storage', exact: true }).click();
  await ui.locator('#storage-window').waitFor({ state: 'hidden' });
  await page.setViewportSize({ width: 1600, height: 1000 });
  await page.reload();
  await page
    .getByText('Ready — production UI with fixture IPC', { exact: true })
    .waitFor();
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
