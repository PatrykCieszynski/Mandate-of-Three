// Optional browser QA. Install Playwright separately; this is not a frontend dependency.
const assert=require('node:assert/strict');
const {chromium}=require(process.env.MANDATE_PLAYWRIGHT||'playwright');
const base=process.env.MANDATE_PREVIEW_URL||'http://127.0.0.1:18741';
const matrix=[[1280,720,.8],[1280,720,.9],[1920,1080,1],[2560,1440,1],[2560,1440,1.1],[2560,1440,1.25],[3440,1440,1],[3440,1440,1.1],[3840,2160,1.25],[3840,2160,1.5]];
(async()=>{
 const browser=await chromium.launch({channel:process.env.MANDATE_BROWSER||'msedge',headless:true});
 try {
  for(const [width,height,scale] of matrix){
   const page=await browser.newPage({viewport:{width,height}}),errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   await page.addInitScript(({scale})=>{
    let listener;window.commands=[];window.regions=[];window.rejectNext=false;
    window.state={inventory:{columns:5,rows:9,pages:4,items:[
     {id:'a'.repeat(32),revision:0,name:'Potion',icon:'potion',quantity:15,height:1,x:0,y:0,page:0,description:'One cell.'},
     {id:'b'.repeat(32),revision:0,name:'Short sword',icon:'short_sword',height:2,x:1,y:0,page:0,description:'Two cells.'},
     {id:'c'.repeat(32),revision:0,name:'Iron sword',icon:'iron_sword',height:3,x:2,y:0,page:0,description:'Three cells.'}
    ]},wallet:{balance:100090},hud:{inventory_open:true,ui_scale:scale}};
    window.ipcMessage={addListener(fn){listener=fn}};
    window.emit=(type,payload)=>listener(JSON.stringify({v:1,type,payload}));
    window.sendIpcMessage=json=>{
     const m=JSON.parse(json);window.commands.push(m);
     if(m.type==='ui.ready')window.emit('ui.snapshot',window.state);
     if(m.type==='ui.interactive_regions')window.regions=m.payload.regions;
     if(m.type==='inventory.close'){window.state.hud.inventory_open=false;window.emit('hud.updated',window.state.hud);}
     if(m.type==='inventory.move_item'){
      const p=m.payload,i=window.state.inventory.items.find(i=>i.id===p.id);
      const valid=!window.rejectNext&&i&&i.revision===p.revision&&p.x>=0&&p.x<5&&p.y>=0&&p.y+i.height<=9&&p.page>=0&&p.page<4&&!window.state.inventory.items.some(o=>o.id!==i.id&&o.page===p.page&&o.x===p.x&&p.y<o.y+o.height&&p.y+i.height>o.y);
      window.rejectNext=false;if(valid)Object.assign(i,{x:p.x,y:p.y,page:p.page,revision:i.revision+1});
      window.emit('inventory.updated',window.state.inventory);
      listener(JSON.stringify({v:1,type:'command.result',id:m.id,payload:valid?{ok:true}:{ok:false,error:'occupied'}}));
     }
     if(m.type==='inventory.close')listener(JSON.stringify({v:1,type:'command.result',id:m.id,payload:{ok:true}}));
    };
   },{scale});
   if(width===1280&&scale===.8)await page.route('**/legacy_skin/skin.js',route=>route.abort());
   await page.goto(base+'/source/client/ui_web/web/inventory/game.html');
   await page.waitForSelector('.inventory-item');
   const panel=await page.locator('.window').boundingBox(),grid=await page.locator('.inventory-grid').boundingBox();
   assert(Math.abs(panel.width-266*scale)<.1,'fixed logical window');assert(Math.abs(grid.width-200*scale)<.1,'five 40px cells');
   assert(panel.x>=0&&panel.y>=0&&panel.x+panel.width<=width+.1&&panel.y+panel.height<=height+.1,'visible window');
   if(width===1920)await page.screenshot({path:'.godot/verification/inventory-contract.png',omitBackground:true});
   for(const h of [1,2,3]){const r=await page.locator(`[data-height="${h}"]`).boundingBox();assert(Math.abs(r.height-(h*40-2)*scale)<.1,'item footprint');}
   async function drag(id,x,y){
    const r=await page.locator(`[data-id="${id.repeat(32)}"]`).boundingBox(),g=await page.locator('.inventory-grid').boundingBox();
    await page.mouse.move(r.x+8*scale,r.y+8*scale);await page.mouse.down();
    await page.mouse.move(g.x+(x*40+8)*scale,g.y+(y*40+8)*scale,{steps:4});
   }
   for(const [id,row] of [['a',3],['b',4],['c',6]]){
    await drag(id,4,row);assert(!await page.locator('.placement-preview').evaluate(n=>n.classList.contains('invalid')),'green valid');
    await page.mouse.up();await page.waitForFunction(()=>!document.querySelector('.inventory-status').textContent.includes('Moving'));
   }
   // A covered non-anchor cell must show red, submit through the bridge, and restore state.
   await drag('a',4,5);assert(await page.locator('.placement-preview').evaluate(n=>n.classList.contains('invalid')),'red overlap');
   await page.mouse.up();await page.waitForFunction(()=>document.querySelector('.inventory-status').textContent.includes('rejected'));
   assert.equal(await page.evaluate(()=>window.state.inventory.items[0].y),3,'rejection preserves authoritative origin');
   await drag('a',-2,3);assert(await page.locator('.placement-preview').isVisible(),'capture survives leaving window');
   await page.mouse.up();await page.waitForFunction(()=>document.querySelector('.inventory-status').textContent.includes('rejected'));
   // Authoritative rejection can disagree with a green advisory preview.
   await page.evaluate(()=>window.rejectNext=true);await drag('a',0,4);await page.mouse.up();
   await page.waitForFunction(()=>document.querySelector('.inventory-status').textContent.includes('rejected'));
   assert.equal(await page.evaluate(()=>window.state.inventory.items[0].y),3);
   await page.locator('[data-id="'+ 'a'.repeat(32)+'"]').click();
   await page.evaluate(()=>window.emit('wallet.updated',{balance:42}));
   assert(await page.locator('.carried-item').isVisible(),'wallet update retains carry');
   await page.keyboard.press('Escape');assert(!await page.locator('.carried-item').isVisible(),'escape cancels carry first');
   assert(await page.locator('.window').isVisible(),'first escape keeps window');
   await page.locator('[data-page="3"]').click();assert.equal(await page.locator('.inventory-item').count(),0,'page IV');
   await page.locator('[data-page="0"]').click();
   await page.locator('[data-id="'+ 'a'.repeat(32)+'"]').click();
   await page.locator('[data-page="3"]').click();
   const destination=await page.locator('.inventory-grid').boundingBox();
   await page.mouse.click(destination.x+8*scale,destination.y+8*scale);
   await page.waitForFunction(()=>window.state.inventory.items[0].page===3);
   await page.locator('[data-page="0"]').click();

   if(width===1920){
    const original=await page.locator('.window').boundingBox(),h=await page.locator('.window-header').boundingBox();
    await page.mouse.move(h.x+40*scale,h.y+10*scale);await page.mouse.down();
    await page.locator('.window-header').evaluate(node=>node.releasePointerCapture(1));
    await page.mouse.move(h.x-100,h.y-100);await page.mouse.up();
    const afterLoss=await page.locator('.window').boundingBox();
    assert.equal(afterLoss.x,original.x,'lost header capture cancels drag');assert.equal(afterLoss.y,original.y);
   }
   const header=await page.locator('.window-header').boundingBox();
   await page.mouse.move(header.x+40*scale,header.y+10*scale);await page.mouse.down();await page.mouse.move(0,0,{steps:5});await page.mouse.up();
   const clamped=await page.locator('.window').boundingBox();assert(clamped.x>=0&&clamped.y>=0,'header drag clamps');
   const movedHeader=await page.locator('.window-header').boundingBox();
   await page.mouse.move(movedHeader.x+40*scale,movedHeader.y+10*scale);await page.mouse.down();
   await page.mouse.move(width-1,height-1,{steps:5});await page.mouse.up();
   const farEdge=await page.locator('.window').boundingBox();
   assert(farEdge.x+farEdge.width<=width+.1&&farEdge.y+farEdge.height<=height+.1,'bottom/right drag clamps');
   await page.setViewportSize({width:1280,height:720});
   await page.waitForFunction(()=>{const r=document.querySelector('.window').getBoundingClientRect();return r.right<=innerWidth+.1&&r.bottom<=innerHeight+.1;});
   const resized=await page.locator('.window').boundingBox();assert(resized.x+resized.width<=1280+.1&&resized.y+resized.height<=720+.1,'resize clamps');
   await page.locator('[data-id="'+ 'c'.repeat(32)+'"]').hover();
   const tip=await page.locator('.item-tooltip').boundingBox();assert(tip&&tip.x>=0&&tip.y>=0&&tip.x+tip.width<=1280+.1&&tip.y+tip.height<=720+.1,'tooltip clamps/flips');
   await page.locator('.window-close').click();await page.waitForFunction(()=>window.regions.length===0);
   assert(!await page.locator('.window').isVisible(),'close hides window and releases regions');
   await page.reload();await page.waitForSelector('.inventory-item');
   assert(await page.evaluate(()=>window.commands.some(m=>m.type==='ui.ready')),'reload ready snapshot');
   assert.equal(await page.locator('.cell').count(),45);assert.deepEqual(errors,[]);
   console.log(`PASS ${width}x${height} @ ${Math.round(scale*100)}%: geometry, 3 heights, commands/rejection, capture, tabs, clamp, tooltip, close, reload`);
   await page.close();
  }
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
