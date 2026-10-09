// Optional UI milestone check. Uses an already installed browser and Playwright.
// No accounts, Godot/CEF subprocess, screenshot assertions or balance expectations.
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import type {Browser, BrowserType} from 'playwright-core';
import type {Envelope, DomainSnapshot, RawObject} from '../web/protocol/contracts.js';
import type {WindowManager} from '../web/core/window/window-manager.js';
import type {mountStorageFixture} from './storage.fixture.mjs';
import {bagItem,equippedItem} from './fixtures.mjs';
declare global {
 interface Window {
  storageFixture?: ReturnType<typeof mountStorageFixture>; storageManager?: WindowManager;
  storageActions: string[]; storageCloses: number; storageReports: number;
  storageReporter?: ReturnType<typeof import('../web/bridge.js').reportInteractiveRegions>;
  sent: Envelope[]; emit(type: string,payload: object,id?: string): void }
 interface HTMLElement { testPointer?: number }
 var sent: Envelope[];
 function emit(type: string,payload: object,id?: string): void;
}
const [playwrightModule,browserExecutable]=process.argv.slice(2);
if(!playwrightModule||!browserExecutable)throw new Error('Pass Playwright module directory and installed browser executable');
// Trusted, explicitly supplied local Playwright package; native require is the external boundary.
const {chromium}: {chromium: BrowserType}=createRequire(import.meta.url)(playwrightModule);
const root=fileURLToPath(new URL('../web/',import.meta.url)).replace(/[\\/]$/,'');
const server=createServer(async(req,res)=>{
 try {
  let pathname=decodeURIComponent((req.url ?? '/').split('?')[0] ?? '/');
  // This single compiled fixture is served only by the opt-in test server. Its
  // relative ../web imports use the same committed runtime as the production page.
  const fixture=pathname==='/__fixtures/storage.fixture.mjs';
  if(pathname.startsWith('/web/'))pathname=pathname.slice(4);
  const file=fixture?fileURLToPath(new URL('./storage.fixture.mjs',import.meta.url)):path.resolve(root,'.'+pathname);
  if(!fixture&&!file.startsWith(root+path.sep))throw Error('Outside UI root');
  const types: Record<string,string>={'.mjs':'text/javascript','.js':'text/javascript','.css':'text/css','.png':'image/png','.html':'text/html'};
  res.setHeader('Content-Type',types[path.extname(file)]||'application/octet-stream');res.end(await readFile(file));
 }catch{res.statusCode=404;res.end();}
});
const snapshot={hud:{inventory_open:true,equipment_open:true,ui_scale:1},wallet:{balance:1234},
 inventory:{columns:5,rows:9,pages:4,items:[bagItem]},equipment:{items:[equippedItem],stats:{attack:10}}} satisfies DomainSnapshot;
async function verify(browser: Browser,url: string,fallback: boolean){
 const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors: string[]=[];
 try{
  page.on('pageerror',error=>errors.push(error.message));
  if(fallback)await page.route('**/legacy_skin/skin.js',route=>route.fulfill({status:404,body:''}));
  await page.addInitScript(()=>{
   window.sent=[];const receivers: ((raw: unknown) => void)[]=[];window.ipcMessage={addListener:fn=>receivers.push(fn)};
   window.emit=(type,payload,id)=>receivers.forEach(fn=>fn(JSON.stringify({v:1,type,payload,...(id?{id}:{})})));
   window.sendIpcMessage=raw=>{const parsed: unknown=JSON.parse(raw);
    function object(value: unknown): value is RawObject{return value!==null&&typeof value==='object'&&!Array.isArray(value);}
    function envelope(value: unknown): value is Envelope{return object(value)&&value.v===1&&typeof value.type==='string'&&object(value.payload)&&(!('id' in value)||typeof value.id==='string');}
    if(!envelope(parsed))throw new Error('Invalid outgoing fixture IPC');
    const message=parsed;sent.push(message);
    if(message.id)queueMicrotask(()=>emit('command.result',{ok:false,error:'test_rejected'},message.id));};
  });
  await page.goto(url);await page.waitForFunction(()=>sent.some(message=>message.type==='ui.ready'));
  const send=(state: DomainSnapshot)=>page.evaluate(state=>emit('ui.snapshot',state),state);
  const commands=()=>page.evaluate(()=>sent.filter(message=>message.id));
  const clear=()=>page.evaluate(()=>{sent=[];});
  const frame=()=>page.evaluate(()=>new Promise<number>(resolve=>requestAnimationFrame(resolve)));
  await send(snapshot);await frame();
  // A bad domain cannot suppress subsequent rendering of a valid unrelated update.
  await page.evaluate(()=>emit('inventory.updated',{columns:1e100,rows:9,pages:4,items:[]}));
  await page.evaluate(()=>emit('wallet.updated',{balance:4321}));
  assert.equal(await page.locator('.wallet strong').textContent(),'4,321');
  assert.equal(await page.locator('.inventory-item').getAttribute('data-id'),'bag-item');
  await send(snapshot);await frame();
  const dimensions=await page.locator('#inventory-window').evaluate(node=>{if(!(node instanceof HTMLElement))throw Error('Expected HTML window');return {width:node.offsetWidth,height:node.offsetHeight};});
  assert.equal(await page.locator('html').evaluate(node=>node.classList.contains('has-close-asset')),!fallback);
  await clear();await page.locator('.inventory-item').click({button:'right'});
  await page.waitForFunction(()=>sent.some(message=>message.type==='item.activate'));
  assert.deepEqual((await commands())[0]?.payload,{id:'bag-item',revision:3});
  assert.equal((await commands()).some(message=>message.type==='equipment.equip'),false);
  await page.locator('.equipment-slot[data-slot=weapon]').click({button:'right'});
  assert.deepEqual((await commands()).at(-1)?.payload,{id:'equipped-item',revision:4});
  // A rejected command does not remove the item before an authoritative update.
  assert.equal(await page.locator('.inventory-item').getAttribute('data-id'),'bag-item');
  await clear();await page.locator('.inventory-item').click();
  await page.evaluate(()=>emit('wallet.updated',{balance:888}));assert.equal(await page.locator('.carried-item').isVisible(),true);
  await frame();assert.ok(await page.evaluate(()=>(()=>{const regions=sent.filter(message=>message.type==='ui.interactive_regions').at(-1)?.payload.regions;return Array.isArray(regions)&&regions.some((region: unknown)=>region!==null&&typeof region==='object'&&'id' in region&&region.id==='carry-surface');})()));
  await page.evaluate(()=>emit('ui.shortcut',{key:'Escape'}));
  assert.equal(await page.locator('.carried-item').isVisible(),false);assert.equal((await commands()).length,0);
  await page.locator('.inventory-item').click();await page.keyboard.press('Escape');
  assert.equal(await page.locator('.carried-item').isVisible(),false);assert.equal((await commands()).length,0);
  const size=await page.locator('.inventory-grid').evaluate(node=>parseFloat(getComputedStyle(node).getPropertyValue('--slot-size')));
  await page.locator('.inventory-item').click();await page.setViewportSize({width:1900,height:1080});
  await page.waitForFunction(()=>document.querySelector<HTMLElement>('.carried-item')?.hidden);
  assert.equal(await page.locator('.carried-item').isVisible(),false);await page.setViewportSize({width:1920,height:1080});
  // Click-to-carry survives a page change and keeps the original UID/revision.
  await page.locator('.inventory-item').click({position:{x:size/2,y:size/2}});await page.getByRole('tab',{name:'II',exact:true}).click();
  const grid=await page.locator('.inventory-grid').boundingBox();assert.ok(grid);
  await page.mouse.click(grid.x+2*size+size/2,grid.y+3*size+size/2);
  await page.waitForFunction(()=>sent.some(message=>message.type==='inventory.move_item'));
  assert.deepEqual((await commands()).at(-1)?.payload,{id:'bag-item',revision:3,x:2,y:3,page:1});
  await page.getByRole('tab',{name:'I',exact:true}).click();
  assert.equal(await page.locator('.inventory-item').getAttribute('data-id'),'bag-item');
  // Drag/drop retains grab offset even when grabbing near the bottom of a tall item.
  await clear();const item=await page.locator('.inventory-item').boundingBox();assert.ok(item);
  await page.mouse.move(item.x+size/2,item.y+item.height-5);await page.mouse.down();
  await page.mouse.move(grid.x+3*size+size/2,grid.y+4*size+item.height-5,{steps:4});await page.mouse.up();
  await page.waitForFunction(()=>sent.some(message=>message.type==='inventory.move_item'));
  assert.deepEqual((await commands()).at(-1)?.payload,{id:'bag-item',revision:3,x:3,y:4,page:0});
  // Slot drops use explicit equip; an equipped item preserves exact Inventory placement.
  for (const scale of [1, 1.25]) {
    await send({...snapshot,hud:{...snapshot.hud,ui_scale:scale}});await frame();await clear();
    const source=await page.locator('.inventory-item').boundingBox(),slot=await page.locator('[data-slot=weapon]').boundingBox();
    assert.ok(source);assert.ok(slot);
    await page.mouse.move(source.x+10*scale,source.y+10*scale);await page.mouse.down();
    await page.mouse.move(slot.x+slot.width/2,slot.y+slot.height/2,{steps:5});
    assert.equal(await page.locator('[data-slot=weapon] .item-drop-highlight').isVisible(),true);
    await page.mouse.up();await page.waitForFunction(()=>sent.some(message=>message.type==='equipment.equip'));
    assert.deepEqual((await commands()).at(-1)?.payload,{id:'bag-item',revision:3});
    await clear();const equipped=await page.locator('[data-slot=weapon]').boundingBox(),destination=await page.locator('.inventory-grid').boundingBox();
    assert.ok(equipped);assert.ok(destination);
    await page.mouse.move(equipped.x+10*scale,equipped.y+10*scale);await page.mouse.down();
    await page.mouse.move(destination.x+2*size*scale+10*scale,destination.y+3*size*scale+10*scale,{steps:5});
    assert.equal(await page.locator('.inventory-grid .placement-preview').isVisible(),true);
    await page.mouse.up();await page.waitForFunction(()=>sent.some(message=>message.type==='equipment.unequip'));
    assert.deepEqual((await commands()).at(-1)?.payload,{id:'equipped-item',revision:4,x:2,y:3,page:0});
    // A rejection keeps both authoritative items and removes gesture visuals.
    assert.equal(await page.locator('.carried-item').isVisible(),false);
    assert.equal(await page.locator('.inventory-item').count(),1);
  }
  await send(snapshot);await frame();await clear();
  await page.locator('.inventory-item').click();
  await page.locator('.inventory-item').click({button:'right'});
  assert.equal(await page.locator('.carried-item').isVisible(),false);assert.equal((await commands()).length,0);
  await page.locator('.inventory-item').click();await page.evaluate(()=>window.dispatchEvent(new Event('blur')));
  assert.equal(await page.locator('.carried-item').isVisible(),false);assert.equal((await commands()).length,0);
  // Reference artwork hover targets remain aligned at every supported UI scale.
  const equipmentProbes = [
    [22, 86, 'Weapon'], [58, 21, 'Helmet'], [58, 72, 'Armor'],
    [94, 54, 'Shield'], [94, 86, 'Bracelet'], [133, 20, 'Arrows'],
    [133, 71, 'Earrings'], [133, 103, 'Necklace'], [58, 164, 'Shoes'],
    [21, 132, 'Special slot I'], [94, 132, 'Special slot II'],
    [133, 170, null],
  ] satisfies [number, number, string | null][];
  for (const scale of [.8, .9, 1, 1.1, 1.25, 1.4, 1.5]) {
    await send({...snapshot, hud: {...snapshot.hud, ui_scale: scale}});
    await frame();
    const targets = await page.locator('.equipment-body').evaluate((body, probes) => {
      const bounds = body.getBoundingClientRect();
      if (!(body instanceof HTMLElement)) throw Error('Expected equipment body');
      return probes.map(([x, y]) => document.elementFromPoint(
        bounds.x + x * bounds.width / body.offsetWidth,
        bounds.y + y * bounds.height / body.offsetHeight,
      )?.closest('.equipment-slot')?.getAttribute('aria-label') ?? null);
    }, equipmentProbes);
    assert.deepEqual(targets, equipmentProbes.map(([, , label]) => label));
  }
  await send(snapshot);
  await frame();
  // Dragging from either outer side of the title row works for every shared shell.
  for (const id of ['inventory', 'equipment']) {
    const header = page.locator('#' + id + ' .window-header');
    const panel = page.locator('#' + id + '-window');
    for (const grab of ['left', 'right', 'center']) {
      await header.evaluate((node) => {
        if (!(node instanceof HTMLElement))
          throw Error('Expected HTML header');
        node.addEventListener(
          'pointerdown',
          (event) => {
            node.testPointer = event.pointerId;
          },
          { once: true },
        );
      });
      const title = await header.boundingBox(),
        before = await panel.boundingBox();
      assert.ok(title);
      assert.ok(before);
      const x =
        grab === 'left'
          ? before.x + 5
          : grab === 'right'
            ? before.x + before.width - 2
            : title.x + title.width / 2;
      const y = title.y + title.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      assert.equal(
        await header.evaluate(
          (node) =>
            node instanceof HTMLElement &&
            node.testPointer !== undefined &&
            node.hasPointerCapture(node.testPointer),
        ),
        true,
        id + ' captures from ' + grab,
      );
      const other = id === 'inventory' ? 'equipment' : 'inventory';
      assert.ok(
        await page.evaluate(
          ({ id, other }) =>
            Number(
              getComputedStyle(
                document.getElementById(id) ?? document.documentElement,
              ).zIndex,
            ) >
            Number(
              getComputedStyle(
                document.getElementById(other) ?? document.documentElement,
              ).zIndex,
            ),
          { id, other },
        ),
      );
      await page.mouse.move(x - 30, y + 10, { steps: 3 });
      await page.mouse.up();
      await frame();
      assert.equal(
        await header.evaluate(
          (node) =>
            node instanceof HTMLElement &&
            node.testPointer !== undefined &&
            node.hasPointerCapture(node.testPointer),
        ),
        false,
      );
      const after = await panel.boundingBox();
      assert.ok(after);
      assert.ok(after.x < before.x, id + ' moves when grabbed from ' + grab);
    }
  }
  const matrix=[[1280,720,.8],[1280,720,.9],[1920,1080,1],[2560,1440,1],[2560,1440,1.1],[2560,1440,1.25],[3440,1440,1],[3440,1440,1.1],[3840,2160,1.25],[3840,2160,1.5]] satisfies [number,number,number][];
  for(const [width,height,scale] of matrix){
   await page.setViewportSize({width,height});await send({...snapshot,hud:{...snapshot.hud,ui_scale:scale}});await frame();
   for(const id of ['inventory','equipment']){
    const box=await page.locator('#'+id+'-window').boundingBox();assert.ok(box);
    assert.ok(box.x>=-.01&&box.y>=-.01&&box.x+box.width<=width+.01&&box.y+box.height<=height+.01,'window remains inside physical viewport');
   }
   assert.deepEqual(await page.locator('#inventory-window').evaluate(node=>{if(!(node instanceof HTMLElement))throw Error('Expected HTML window');return {width:node.offsetWidth,height:node.offsetHeight};}),dimensions);
  }
  // Runtime skin replacement needs no changes to either view, including broken images.
  await page.evaluate(async()=>{const modulePath='/core/assets/skin.js';const {applySkin}: typeof import('../web/core/assets/skin.js')=await import(modulePath);
   // @ts-expect-error Malformed layout key is intentionally tested at runtime.
   await applySkin(document.documentElement,{assets:{'button.close.normal':'/missing.png','inventory.columns':'/missing.png'}});});
  assert.equal(await page.locator('html').evaluate(node=>node.classList.contains('has-close-asset')),false);
  assert.deepEqual(await page.locator('#inventory-window').evaluate(node=>{if(!(node instanceof HTMLElement))throw Error('Expected HTML window');return {width:node.offsetWidth,height:node.offsetHeight};}),dimensions);
  // Storage uses the same typed composition fixture as the default headless test.
  await page.evaluate(async()=>{
   const fixturePath='/__fixtures/storage.fixture.mjs',managerPath='/core/window/window-manager.js',bridgePath='/bridge.js';
   const {mountStorageFixture}: typeof import('./storage.fixture.mjs')=await import(fixturePath);
   const {WindowManager}: typeof import('../web/core/window/window-manager.js')=await import(managerPath);
   const {reportInteractiveRegions}: typeof import('../web/bridge.js')=await import(bridgePath);
   const root=document.createElement('main');root.id='storage-fixture';document.body.append(root);
   const manager=new WindowManager();manager.setViewport({width:innerWidth,height:innerHeight},1);
   window.storageActions=[];window.storageCloses=0;window.storageReports=0;window.storageManager=manager;
   const fixture=mountStorageFixture(root,{manager,resolveItemIcon:()=>null,onClose:()=>{window.storageCloses++;},
    onItemAction:(_event,item)=>window.storageActions.push(item.id),onRegionsChanged:()=>window.storageReporter?.refresh()});
   window.storageFixture=fixture;window.storageReporter=reportInteractiveRegions({event:()=>{window.storageReports++;}},fixture.regions);
   fixture.setState({columns:4,rows:5,items:[{id:'stored-material',name:'Stored material',icon_id:'material',height:2,quantity:7,x:1,y:1,description:'Storage description'}]});
  });await frame();
  const stored=page.locator('#storage-fixture .ui-item-slot');await stored.click();assert.deepEqual(await page.evaluate(()=>window.storageActions),['stored-material']);
  await stored.hover();assert.equal(await page.locator('#storage-fixture .item-tooltip').isVisible(),true);
  assert.equal(await page.locator('#storage-fixture .item-tooltip p').textContent(),'Storage description');
  await page.locator('#storage-fixture .cell').first().hover();assert.equal(await page.locator('#storage-fixture .item-tooltip').isVisible(),false);
  await stored.hover();assert.equal(await page.locator('#storage-fixture .item-tooltip').isVisible(),true);
  assert.ok(await page.evaluate(()=>window.storageReports>0));
  const storageHeader=page.locator('#storage-fixture .window-header');
  await storageHeader.evaluate(node=>{if(!(node instanceof HTMLElement))throw Error('Expected header');node.addEventListener('pointerdown',event=>{node.testPointer=event.pointerId;},{once:true});});
  const header=await storageHeader.boundingBox();assert.ok(header);await page.mouse.move(header.x+header.width/2,header.y+header.height/2);await page.mouse.down();
  assert.equal(await storageHeader.evaluate(node=>node instanceof HTMLElement&&node.testPointer!==undefined&&node.hasPointerCapture(node.testPointer)),true);
  await page.mouse.move(300,200,{steps:3});await page.mouse.up();await frame();
  assert.equal(await page.evaluate(()=>window.storageManager?.activeWindowId),'storage');
  await page.setViewportSize({width:960,height:720});await page.evaluate(()=>window.storageManager?.setScale(1.25));await frame();
  const box=await page.locator('#storage-fixture #storage-window').boundingBox();assert.ok(box);assert.ok(box.x>=0&&box.y>=0&&box.x+box.width<=960+.01&&box.y+box.height<=720+.01);
  assert.equal(await page.locator('#storage-fixture .item-tooltip').isVisible(),false);
  await page.evaluate(()=>window.storageFixture?.setState({columns:4,rows:5,items:[{id:'updated-material',name:'Updated material',icon_id:'material',height:1,quantity:9,x:2,y:2}]}));
  assert.equal(await stored.getAttribute('data-id'),'updated-material');assert.equal(await stored.locator('.quantity').textContent(),'9');
  await page.locator('#storage-fixture .window-close').click();assert.equal(await page.evaluate(()=>window.storageCloses),1);
  await page.evaluate(()=>{window.storageFixture?.dispose();window.storageReporter?.dispose();window.storageManager?.dispose();document.getElementById('storage-fixture')?.remove();});
  assert.equal(await page.evaluate(()=>window.storageManager?.registeredCount),0);
  await page.setViewportSize({width:1920,height:1080});
  await send(snapshot);await clear();await page.locator('#inventory .window-close').click();
  assert.equal((await commands()).at(-1)?.type,'inventory.close');
  await send({...snapshot,hud:{...snapshot.hud,inventory_open:false}});await clear();await page.locator('#equipment .window-close').click();
  assert.equal((await commands()).at(-1)?.type,'equipment.close');
  assert.deepEqual(errors,[]);console.log('Core UI real DOM: PASS ('+(fallback?'CSS fallback':'legacy skin')+')');
 }finally{await page.close();}
}
(async()=>{
 await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));let browser: Browser | undefined;
 try{browser=await chromium.launch({executablePath:browserExecutable,headless:true});
  const address=server.address();if(!address||typeof address==='string')throw Error('Missing HTTP address');
  const url=`http://127.0.0.1:${address.port}/inventory/game.html`;
  await verify(browser,url,false);await verify(browser,url,true);
 }finally{await browser?.close();await new Promise<void>((resolve,reject)=>server.close(error=>error?reject(error):resolve()));}
})().catch(error=>{console.error(error);process.exitCode=1;});
