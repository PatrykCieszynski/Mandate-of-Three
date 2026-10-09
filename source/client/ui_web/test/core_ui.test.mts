import test from 'node:test';
import assert from 'node:assert/strict';
import {WindowManager} from '../web/core/window/window-manager.js';
import {UiWindow} from '../web/core/window/ui-window.js';
import {UiTooltip,tooltipPosition} from '../web/core/primitives/ui-tooltip.js';
import {applySkin,skinVariable} from '../web/core/assets/skin.js';
import {UiIconRegistry,uiIconDomains} from '../web/core/assets/ui-icons.js';
import {ItemIconResolver} from '../web/content/item-icons.js';
import {paintItemIcon} from '../web/game-ui/items/item-icon.js';
import {UiEquipmentSlot} from '../web/game-ui/equipment/ui-equipment-slot.js';
import {UiItemGrid} from '../web/game-ui/items/ui-item-grid.js';
import {UiItemSlot} from '../web/game-ui/items/ui-item-slot.js';
import {ItemTooltip} from '../web/game-ui/items/item-tooltip.js';
import {UiCurrency} from '../web/core/primitives/ui-currency.js';
import {element as findElement} from '../web/core/dom.js';
import {mountStorageFixture} from './storage.fixture.mjs';
import {environment,target,measure,capture,fire,equippedItem} from './fixtures.mjs';

test('registration, activation, hidden windows, resize and scale stay in the manager',()=>{
 const {host,manager}=environment(),one=target(),two=target();let cancelled=0,activated=0;
 const handle=manager.register({id:'one',element:one});
 handle.onLayoutChanged(event=>{if(event.cancelTransient)cancelled++;});handle.onActivate(()=>{activated++;});
 manager.register({id:'two',element:two});assert.throws(()=>manager.register({id:'one',element:one}),/Duplicate/);
 manager.activate('one');assert.equal(manager.activeWindowId,'one');assert.ok(Number(one.style.zIndex)>Number(two.style.zIndex));assert.equal(activated,1);
 one.hidden=true;manager.refresh('one');assert.equal(manager.activeWindowId,'two');assert.ok(cancelled>0);
 one.hidden=false;manager.move('one',{x:9999,y:9999});manager.setScale(1.5);Object.defineProperties(host,{innerWidth:{value:600,configurable:true},innerHeight:{value:500,configurable:true}});host.dispatchEvent(new host.Event('resize'));
 const p=manager.place('one');assert.ok(p.x>=0&&p.x+one.offsetWidth<=host.innerWidth/manager.scale);assert.ok(p.y>=0);
 assert.throws(()=>manager.setScale(0),/Invalid/);manager.unregister('two');assert.equal(manager.activeWindowId,'one');
 manager.dispose();Object.defineProperty(host,'innerWidth',{value:100});host.dispatchEvent(new host.Event('resize'));assert.equal(manager.viewport.width,600);assert.equal(manager.registeredCount,0);
});

test('shared shell captures drag, cancels on lifecycle changes and removes listeners',()=>{
 const {host,doc,manager,frames}=environment(),root=target();let regions=0,closes=0,cancels=0;
 doc.body.append(root);
 const shell=new UiWindow(root,{manager,id:'storage',title:'Storage',onClose:()=>{closes++;},onCancel:()=>{cancels++;},onRegionsChanged:()=>{regions++;}});
 const {panel}=shell,header=findElement(root,'.window-header','header'),close=findElement(root,'.window-close','button');measure(panel);capture(header);
 shell.refresh();fire(header,'pointerdown');assert.ok(header.hasPointerCapture(1));
 fire(doc,'pointermove',250,150,2);assert.equal(frames.size,0);
 fire(doc,'pointermove',250,150);assert.equal(frames.size,1);
 fire(doc,'pointerup');assert.equal(frames.size,0);assert.equal(header.hasPointerCapture(1),false);assert.ok(regions>1);
 fire(header,'pointerdown');manager.setScale(.9);assert.equal(header.hasPointerCapture(1),false);
 fire(header,'pointerdown');host.dispatchEvent(new host.Event('blur'));assert.equal(header.hasPointerCapture(1),false);
 close.click();assert.equal(closes,1);assert.ok(cancels>0);
 shell.dispose();shell.dispose();const savedRegions=regions,savedCancels=cancels;
 close.click();fire(header,'pointerdown');fire(doc,'pointermove');fire(doc,'pointerup');host.dispatchEvent(new host.Event('blur'));
 assert.equal(header.hasPointerCapture(1),false);assert.equal(closes,1);assert.equal(regions,savedRegions);assert.equal(cancels,savedCancels);assert.equal(frames.size,0);
 assert.equal(manager.registeredCount,0);manager.dispose();
});

test('tooltip geometry flips and stays reachable at all scales and in small viewports',()=>{
 for(const scale of [.8,.9,1,1.1,1.25,1.4,1.5]){
  const viewport={width:1280,height:720},size={width:200,height:80};
  const near={x:viewport.width/scale-5,y:viewport.height/scale-5};const p=tooltipPosition(near,size,viewport,scale);
  assert.ok(p.x<near.x&&p.x>=0&&p.x+size.width<=viewport.width/scale);assert.ok(p.y>=0&&p.y+size.height<=viewport.height/scale);
 }
 assert.deepEqual(tooltipPosition({x:20,y:20},{width:200,height:80},{width:50,height:50},1),{x:0,y:0});
});

test('skin swapping clears stale assets, detects missing images and cannot change geometry',async()=>{
 environment();const root=target(),options={baseUrl:'https://example.test/skin/',loadAsset:async(url: string)=>!url.includes('missing')};
 // Deliberately exercise a malformed skin at runtime; TS also rejects the extra key.
 // @ts-expect-error Layout keys are outside the skin contract.
 await applySkin(root,{assets:{'window.frame':'frame.png','button.close.normal':'close.png','equipment.background':'missing.png','inventory.columns':'999'}},options);
 const value=(key: Parameters<typeof skinVariable>[0])=>root.style.getPropertyValue(skinVariable(key));
 assert.ok(value('window.frame').includes('frame.png'));assert.equal(root.classList.contains('has-close-asset'),true);
 assert.equal(value('button.close.hover'),value('button.close.normal'));assert.equal(value('equipment.background'),'none');assert.equal(root.style.getPropertyValue('--skin-inventory-columns'),'');
 await applySkin(root,{assets:{'window.frame':'replacement.png'}},options);
 assert.ok(value('window.frame').includes('replacement.png'));assert.equal(root.classList.contains('has-close-asset'),false);assert.equal(value('button.close.normal'),'none');
});

test('structured UI icons are replaceable and isolated from item content',()=>{
 const registry=new UiIconRegistry();let changes=0;const remove=registry.subscribe(()=>{changes++;});
 registry.replace(Object.fromEntries(uiIconDomains.map(domain=>[domain,{test:'glyph.png'}])),'https://example.test/ui/');
 for(const domain of uiIconDomains)assert.equal(registry.resolve(`${domain}.test`),'https://example.test/ui/glyph.png');
 // @ts-expect-error Unknown namespaces remain rejected at runtime too.
 assert.throws(()=>registry.replace({items:{sword:'sword.png'}}),/domain/);
 // @ts-expect-error Unqualified identifiers cannot address UI icons.
 assert.equal(registry.resolve('missing'),null);
 const items=new ItemIconResolver({sword:'sword.png'},'https://example.test/content/');assert.equal(items.resolve('sword'),'https://example.test/content/sword.png');
 // @ts-expect-error Item identities do not belong to the UI registry.
 assert.equal(registry.resolve('sword'),null);
 registry.replace({currencies:{yang:'coin.png'}},'https://example.test/new/');assert.equal(registry.resolve('skills.test'),null);assert.equal(changes,2);
 remove();registry.replace({});assert.equal(changes,2);assert.equal(items.resolve('unknown'),null);
});

test('item icons preserve labels and quantity on missing images; equipment interactivity belongs to the caller',()=>{
 const {host}=environment(),element=target(),item={...equippedItem,name:'<Sword>',quantity:5};
 paintItemIcon(element,item,{resolveItemIcon:()=>'/broken.png'});findElement(element,'img','img').dispatchEvent(new host.Event('error'));
 assert.equal(element.children[0]?.textContent,item.name);assert.equal(element.children[1]?.textContent,'5');
 const tile=UiEquipmentSlot({slot:'any-slot',label:'Any',height:32,x:0,y:0,resolveItemIcon:()=>null});
 tile.setItem(item);assert.equal(tile.element.disabled,true);tile.setItem(item,{enabled:true});assert.equal(tile.element.disabled,false);assert.equal(tile.element.children[0]?.textContent,item.name);
 assert.equal(tile.element.hasAttribute('title'),false);tile.setItem(undefined);assert.equal(tile.element.title,'Any');assert.equal(tile.element.disabled,true);
});

test('currency uses semantic UI icons, refreshes on replacement and unsubscribes on disposal',async()=>{
 environment();const icons=new UiIconRegistry(),element=target();icons.replace({currencies:{test:'coin.png'}},'https://example.test/');
 const currency=UiCurrency(element,{label:'Test currency',iconId:'currencies.test',icons,loadAsset:async()=>true});
 currency.setValue(1234);await Promise.resolve();assert.equal(element.children[2]?.textContent,'1,234');
 const icon=findElement(element,'.currency-icon','span');assert.ok(icon.style.backgroundImage.includes('coin.png'));icons.replace({});assert.equal(icon.style.backgroundImage,'none');assert.equal(icons.listeners.size,1);
 currency.dispose();assert.equal(icons.listeners.size,0);
});

test('relative placement rejects cycles and unknown or empty IDs',()=>{
 environment();const manager=new WindowManager({host:null});manager.setViewport({width:1200,height:800});
 // @ts-expect-error The missing identity is deliberately invalid at the runtime boundary.
 assert.throws(()=>manager.register({element:target()}),/stable id/);
 manager.register({id:'a',element:target(),placement:{kind:'relative',target:'b',side:'left'}});manager.register({id:'b',element:target(),placement:{kind:'relative',target:'a',side:'left'}});
 assert.throws(()=>manager.place('a'),/Cyclic/);assert.throws(()=>manager.place('missing'),/Unknown/);manager.dispose();
});

test('relative placement supports all sides and alignment, reset restores declared placement',()=>{
 const {manager}=environment(),anchor=target(),other=target();measure(anchor,200,100);measure(other,80,40);
 manager.register({id:'anchor',element:anchor,placement:{kind:'viewport',anchor:'top-left',offset:{x:300,y:250}}});
 const cases=[
  ['left','start',{x:208,y:250}],['left','center',{x:208,y:280}],['left','end',{x:208,y:310}],
  ['right','end',{x:512,y:310}],['top','center',{x:360,y:198}],['bottom','end',{x:420,y:362}]
 ] satisfies [import('../web/core/window/window-types.js').RelativePlacement['side'],import('../web/core/window/window-types.js').RelativePlacement['align'],{x:number;y:number}][];
 for(const [side,align,expected] of cases){
  const handle=manager.register({id:'other',element:other,placement:{kind:'relative',target:'anchor',side,align,gap:12}});
  assert.deepEqual(handle.place(),expected);handle.move({x:20,y:30});assert.deepEqual(handle.place(),{x:20,y:30});
  handle.resetPosition();assert.deepEqual(handle.place(),expected);
  anchor.hidden=true;assert.deepEqual(handle.place(),expected,'cached target geometry survives hiding');anchor.hidden=false;
  handle.dispose();handle.dispose();assert.throws(()=>handle.move({x:0,y:0}),/Disposed/);
 }
 const replacement=manager.register({id:'other',element:other});replacement.dispose();manager.dispose();
});

test('idle windows install no global drag move/up listeners; every termination removes them',()=>{
 const {doc,host,manager,frames}=environment();
 const active=new Map<string,Set<EventListenerOrEventListenerObject>>();
 const add=doc.addEventListener.bind(doc),remove=doc.removeEventListener.bind(doc);
 doc.addEventListener=(type: string,listener: EventListenerOrEventListenerObject,options?: boolean|AddEventListenerOptions)=>{
  if(listener&&(type==='pointermove'||type==='pointerup')){
   let listeners=active.get(type);if(!listeners){listeners=new Set();active.set(type,listeners);}listeners.add(listener);
  }
  add(type,listener,options);
 };
 doc.removeEventListener=(type: string,listener: EventListenerOrEventListenerObject,options?: boolean|EventListenerOptions)=>{if(listener)active.get(type)?.delete(listener);remove(type,listener,options);};
 const shells=Array.from({length:20},(_,index)=>{
  const root=target();doc.body.append(root);const shell=new UiWindow(root,{id:'window-'+index,title:'Test',manager});measure(shell.panel);shell.refresh();
  capture(findElement(root,'.window-header','header'));return shell;
 });
 const shell=shells[0];assert.ok(shell);const header=findElement(shell.root,'.window-header','header');
 const count=()=>[active.get('pointermove')?.size??0,active.get('pointerup')?.size??0];assert.deepEqual(count(),[0,0]);
 for(const finish of [()=>fire(doc,'pointerup'),()=>header.releasePointerCapture(1),()=>fire(doc,'pointercancel'),()=>host.dispatchEvent(new host.Event('blur')),()=>manager.setViewport({width:600,height:400})]){
  fire(header,'pointerdown');assert.deepEqual(count(),[1,1]);fire(doc,'pointermove',150,150);
  fire(doc,'pointerup',150,150,2);assert.deepEqual(count(),[1,1]);finish();assert.deepEqual(count(),[0,0]);assert.equal(frames.size,0);
 }
 fire(header,'pointerdown');fire(doc,'pointermove',140,140);shell.dispose();assert.deepEqual(count(),[0,0]);assert.equal(frames.size,0);
 for(const entry of shells)entry.dispose();manager.dispose();
});

test('core tooltip accepts arbitrary DOM content; item adapter escapes and replaces item text',()=>{
 const {manager}=environment(),root=target();manager.setViewport({width:800,height:600},1.25);
 const tooltip=UiTooltip(root,{geometry:()=>manager}),content=document.createElement('button');content.textContent='Quest help';
 tooltip.contentRoot.append(content);measure(tooltip.element,200,80);tooltip.showAt({x:635,y:475});
 assert.equal(tooltip.element.hidden,false);assert.equal(tooltip.contentRoot.firstElementChild,content);
 assert.ok(parseFloat(tooltip.element.style.left)+200<=800/1.25);assert.ok(parseFloat(tooltip.element.style.top)+80<=600/1.25);
 tooltip.hide();assert.equal(tooltip.element.hidden,true);tooltip.dispose();assert.equal(root.contains(content),false);
 const item=ItemTooltip(root,{geometry:()=>manager});measure(item.element,200,80);
 item.show({clientX:790,clientY:590},{name:'<Sword>',description:'<img src=x>'});
 assert.equal(findElement(item.element,'h2','h2').textContent,'<Sword>');assert.equal(item.element.querySelector('img'),null);
 item.show({clientX:100,clientY:100},{name:'Other'});assert.equal(findElement(item.element,'p','p').textContent,'');
 item.dispose();manager.dispose();
});

test('item grid renders exactly the caller-selected models and slots need no domain state',()=>{
 environment();const element=target(),grid=UiItemGrid(element,{slotSize:()=>40});
 const models=[{sku:'first',x:1,y:2,height:2,page:1},{sku:'second',x:0,y:0,height:1,page:0}];
 const rendered: typeof models=[];
 grid.render({columns:3,rows:4,items:models},item=>{rendered.push(item);const node=document.createElement('span');node.textContent=item.sku;return node;});
 assert.deepEqual(rendered,models,'no internal inventory-page filtering');
 const presentation={id:'content',name:'Material',icon_id:'material',height:2,quantity:7};
 const slot=UiItemSlot({item:presentation,slotSize:40,resolveItemIcon:()=>null});
 assert.equal(slot.getAttribute('aria-label'),'Material');assert.equal(slot.dataset.height,'2');assert.equal(slot.querySelector('.quantity')?.textContent,'7');
 grid.render({columns:1,rows:1,items:[]},()=>{throw Error('Empty grid must not request items');});
 assert.equal(element.querySelector('span'),null);grid.dispose();assert.equal(element.childElementCount,0);
});

test('Storage composes state/actions, regions, tooltip and window lifecycle without domain coupling',()=>{
 const {manager,doc,host,frames}=environment(),root=target();doc.body.append(root);
 let closes=0,regions=0;const actions: string[]=[];
 const storage=mountStorageFixture(root,{manager,resolveItemIcon:()=>null,onClose:()=>closes++,onItemAction:(_event,item)=>actions.push(item.id),onRegionsChanged:()=>regions++});
 const panel=storage.regions[0];assert.ok(panel);measure(panel,266,280);
 const header=findElement(root,'.window-header','header');capture(header);
 const item={id:'storage-content',name:'Material',icon_id:'material',height:2,quantity:7,x:1,y:1,description:'Stored material'};
 storage.setState({columns:4,rows:5,items:[item]});const slot=findElement(root,'.ui-item-slot','div');
 fire(slot,'pointerdown');assert.deepEqual(actions,['storage-content']);
 fire(slot,'pointermove',100,150);const tooltip=findElement(root,'.ui-tooltip','aside');assert.equal(tooltip.hidden,false);assert.equal(findElement(tooltip,'p','p').textContent,item.description);
 manager.setScale(1.25);assert.equal(tooltip.hidden,true);
 fire(header,'pointerdown');fire(doc,'pointermove',120,140);fire(doc,'pointerup');assert.equal(frames.size,0);assert.ok(regions>1);assert.equal(manager.activeWindowId,'storage');
 manager.setViewport({width:400,height:350});const position=manager.place('storage');assert.ok(position.x>=0&&position.x+panel.offsetWidth<=400/1.25);
 storage.setState({columns:4,rows:5,items:[{...item,id:'updated',quantity:9}]});
 const updated=findElement(root,'.ui-item-slot','div');fire(updated,'pointerdown');assert.deepEqual(actions,['storage-content','updated']);assert.equal(updated.querySelector('.quantity')?.textContent,'9');
 const close=findElement(root,'.window-close','button');close.click();assert.equal(closes,1);
 fire(updated,'pointermove');root.hidden=true;manager.refreshAll();assert.equal(tooltip.hidden,true);
 storage.dispose();storage.dispose();const savedRegions=regions;close.click();fire(updated,'pointerdown');fire(doc,'pointermove');host.dispatchEvent(new host.Event('blur'));
 assert.equal(closes,1);assert.equal(actions.length,2);assert.equal(regions,savedRegions);assert.equal(manager.has('storage'),false);assert.equal(frames.size,0);manager.dispose();
});

test('viewport corner anchors use logical size and stale handles cannot unregister replacement windows',()=>{
 const {manager}=environment(),element=target();measure(element,80,40);manager.setViewport({width:1000,height:800},1.25);
 const corners=[['top-left',{x:10,y:5},{x:10,y:5}],['top-right',{x:-10,y:5},{x:710,y:5}],
  ['bottom-left',{x:10,y:-5},{x:10,y:595}],['bottom-right',{x:-10,y:-5},{x:710,y:595}]] satisfies
  [import('../web/core/window/window-types.js').ViewportPlacement['anchor'],{x:number;y:number},{x:number;y:number}][];
 for(const [anchor,offset,expected] of corners){
  const handle=manager.register({id:'corner',element,placement:{kind:'viewport',anchor,offset}});assert.deepEqual(handle.place(),expected);handle.dispose();
  const replacement=manager.register({id:'corner',element});handle.dispose();assert.equal(manager.has('corner'),true);replacement.dispose();
 }
 manager.dispose();
});
