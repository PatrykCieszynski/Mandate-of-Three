// Optional UI milestone check. Uses an already installed browser and Playwright.
// No accounts, Godot/CEF subprocess, screenshot assertions or balance expectations.
const {createServer}=require('node:http');
const {readFile}=require('node:fs/promises');
const path=require('node:path');
const assert=require('node:assert/strict');
const [playwrightModule,browserExecutable]=process.argv.slice(2);
if(!playwrightModule||!browserExecutable)throw new Error('Pass Playwright module directory and installed browser executable');
const {chromium}=require(playwrightModule);
const root=path.resolve(__dirname,'../source/client/ui_web/web');
const server=createServer(async(req,res)=>{
 try {
  const file=path.resolve(root,'.'+decodeURIComponent(req.url.split('?')[0]));
  if(!file.startsWith(root+path.sep))throw Error('Outside UI root');
  const types={'.js':'text/javascript','.css':'text/css','.png':'image/png','.html':'text/html'};
  res.setHeader('Content-Type',types[path.extname(file)]||'application/octet-stream');res.end(await readFile(file));
 }catch{res.statusCode=404;res.end();}
});
const snapshot={hud:{inventory_open:true,equipment_open:true,ui_scale:1},wallet:{balance:1234},
 inventory:{columns:5,rows:9,pages:4,items:[{id:'bag-item',revision:3,name:'Sword',icon_id:'iron_sword',x:0,y:0,page:0,height:3,quantity:2,description:'Example'}]},
 equipment:{items:[{id:'equipped-item',revision:4,name:'Equipped sword',icon_id:'iron_sword',slot:'weapon'}],stats:{attack:10}}};
async function verify(browser,url,fallback){
 const page=await browser.newPage({viewport:{width:1920,height:1080}}),errors=[];
 try{
  page.on('pageerror',error=>errors.push(error.message));
  if(fallback)await page.route('**/legacy_skin/skin.js',route=>route.fulfill({status:404,body:''}));
  await page.addInitScript(()=>{
   window.sent=[];const receivers=[];window.ipcMessage={addListener:fn=>receivers.push(fn)};
   window.emit=(type,payload,id)=>receivers.forEach(fn=>fn(JSON.stringify({v:1,type,payload,...(id?{id}:{})})));
   window.sendIpcMessage=raw=>{const message=JSON.parse(raw);sent.push(message);
    if(message.id)queueMicrotask(()=>emit('command.result',{ok:false,error:'test_rejected'},message.id));};
  });
  await page.goto(url);await page.waitForFunction(()=>sent.some(message=>message.type==='ui.ready'));
  const send=state=>page.evaluate(state=>emit('ui.snapshot',state),state);
  const commands=()=>page.evaluate(()=>sent.filter(message=>message.id));
  const clear=()=>page.evaluate(()=>{sent=[];});
  const frame=()=>page.evaluate(()=>new Promise(requestAnimationFrame));
  await send(snapshot);await frame();
  const dimensions=await page.locator('#inventory-window').evaluate(node=>({width:node.offsetWidth,height:node.offsetHeight}));
  assert.equal(await page.locator('html').evaluate(node=>node.classList.contains('has-close-asset')),!fallback);
  await clear();await page.locator('.inventory-item').click({button:'right'});
  await page.waitForFunction(()=>sent.some(message=>message.type==='equipment.equip'));
  assert.deepEqual((await commands())[0].payload,{id:'bag-item',revision:3});
  await page.locator('.equipment-slot[data-slot=weapon]').click();
  assert.deepEqual((await commands()).at(-1).payload,{id:'equipped-item',revision:4});
  // A rejected command does not remove the item before an authoritative update.
  assert.equal(await page.locator('.inventory-item').getAttribute('data-id'),'bag-item');
  await clear();await page.locator('.inventory-item').click();
  await page.evaluate(()=>emit('wallet.updated',{balance:888}));assert.equal(await page.locator('.carried-item').isVisible(),true);
  await frame();assert.ok(await page.evaluate(()=>sent.filter(message=>message.type==='ui.interactive_regions').at(-1).payload.regions.some(region=>region.id==='carry-surface')));
  await page.evaluate(()=>emit('ui.shortcut',{key:'Escape'}));
  assert.equal(await page.locator('.carried-item').isVisible(),false);assert.equal((await commands()).length,0);
  await page.locator('.inventory-item').click();await page.keyboard.press('Escape');
  assert.equal(await page.locator('.carried-item').isVisible(),false);assert.equal((await commands()).length,0);
  const size=await page.locator('.inventory-grid').evaluate(node=>parseFloat(getComputedStyle(node).getPropertyValue('--slot-size')));
  await page.locator('.inventory-item').click();await page.setViewportSize({width:1900,height:1080});
  await page.waitForFunction(()=>document.querySelector('.carried-item').hidden);
  assert.equal(await page.locator('.carried-item').isVisible(),false);await page.setViewportSize({width:1920,height:1080});
  // Click-to-carry survives a page change and keeps the original UID/revision.
  await page.locator('.inventory-item').click({position:{x:size/2,y:size/2}});await page.getByRole('tab',{name:'II',exact:true}).click();
  const grid=await page.locator('.inventory-grid').boundingBox();
  await page.mouse.click(grid.x+2*size+size/2,grid.y+3*size+size/2);
  await page.waitForFunction(()=>sent.some(message=>message.type==='inventory.move_item'));
  assert.deepEqual((await commands()).at(-1).payload,{id:'bag-item',revision:3,x:2,y:3,page:1});
  await page.getByRole('tab',{name:'I',exact:true}).click();
  assert.equal(await page.locator('.inventory-item').getAttribute('data-id'),'bag-item');
  // Drag/drop retains grab offset even when grabbing near the bottom of a tall item.
  await clear();const item=await page.locator('.inventory-item').boundingBox();
  await page.mouse.move(item.x+size/2,item.y+item.height-5);await page.mouse.down();
  await page.mouse.move(grid.x+3*size+size/2,grid.y+4*size+item.height-5,{steps:4});await page.mouse.up();
  await page.waitForFunction(()=>sent.some(message=>message.type==='inventory.move_item'));
  assert.deepEqual((await commands()).at(-1).payload,{id:'bag-item',revision:3,x:3,y:4,page:0});
  // Window interaction activates its root and uses pointer capture until release.
  for(const id of ['inventory','equipment']){
   const header=page.locator('#'+id+' .window-header');
   await header.evaluate(node=>node.addEventListener('pointerdown',event=>node.testPointer=event.pointerId,{once:true}));
   const rect=await header.boundingBox();await page.mouse.move(rect.x+rect.width/2,rect.y+rect.height/2);await page.mouse.down();
   assert.equal(await header.evaluate(node=>node.hasPointerCapture(node.testPointer)),true);
   const other=id==='inventory'?'equipment':'inventory';
   assert.ok(await page.evaluate(({id,other})=>Number(getComputedStyle(document.getElementById(id)).zIndex)>Number(getComputedStyle(document.getElementById(other)).zIndex),{id,other}));
   await page.mouse.move(30,30,{steps:3});await page.mouse.up();await frame();
   assert.equal(await header.evaluate(node=>node.hasPointerCapture(node.testPointer)),false);
  }
  const matrix=[[1280,720,.8],[1280,720,.9],[1920,1080,1],[2560,1440,1],[2560,1440,1.1],[2560,1440,1.25],[3440,1440,1],[3440,1440,1.1],[3840,2160,1.25],[3840,2160,1.5]];
  for(const [width,height,scale] of matrix){
   await page.setViewportSize({width,height});await send({...snapshot,hud:{...snapshot.hud,ui_scale:scale}});await frame();
   for(const id of ['inventory','equipment']){
    const box=await page.locator('#'+id+'-window').boundingBox();
    assert.ok(box.x>=-.01&&box.y>=-.01&&box.x+box.width<=width+.01&&box.y+box.height<=height+.01,'window remains inside physical viewport');
   }
   assert.deepEqual(await page.locator('#inventory-window').evaluate(node=>({width:node.offsetWidth,height:node.offsetHeight})),dimensions);
  }
  // Runtime skin replacement needs no changes to either view, including broken images.
  await page.evaluate(async()=>{const {applySkin}=await import('/core/skin.js');await applySkin(document.documentElement,{assets:{'button.close.normal':'/missing.png','inventory.columns':'/missing.png'}});});
  assert.equal(await page.locator('html').evaluate(node=>node.classList.contains('has-close-asset')),false);
  assert.deepEqual(await page.locator('#inventory-window').evaluate(node=>({width:node.offsetWidth,height:node.offsetHeight})),dimensions);
  // A third simple window composes only the shared shell and tooltip.
  const storage=await page.evaluate(async()=>{
   const {UiWindow}=await import('/core/ui-window.js'),{WindowManager}=await import('/core/window-manager.js'),{UiTooltip}=await import('/core/ui-tooltip.js');
   const root=document.createElement('main');document.body.append(root);const manager=new WindowManager();manager.setViewport({width:innerWidth,height:innerHeight},1);
   let closes=0;const shell=new UiWindow(root,{manager,window_id:'storage',title:'Storage',content:'<p>Storage content</p>',onClose:()=>closes++});
   const tip=UiTooltip(root,{geometry:()=>manager});shell.refresh();const close=root.querySelector('.window-close');close.click();
   const registered=manager.windows.has('storage');tip.dispose();shell.dispose();close.click();manager.dispose();root.remove();return {registered,closes};
  });assert.deepEqual(storage,{registered:true,closes:1});
  await send(snapshot);await clear();await page.locator('#inventory .window-close').click();
  assert.equal((await commands()).at(-1).type,'inventory.close');
  await send({...snapshot,hud:{...snapshot.hud,inventory_open:false}});await clear();await page.locator('#equipment .window-close').click();
  assert.equal((await commands()).at(-1).type,'equipment.close');
  assert.deepEqual(errors,[]);console.log('Core UI real DOM: PASS ('+(fallback?'CSS fallback':'legacy skin')+')');
 }finally{await page.close();}
}
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
 try{browser=await chromium.launch({executablePath:browserExecutable,headless:true});
  const url=`http://127.0.0.1:${server.address().port}/inventory/game.html`;
  await verify(browser,url,false);await verify(browser,url,true);
 }finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
