import test from 'node:test';
import assert from 'node:assert/strict';
import {WindowManager} from '../source/client/ui_web/web/core/window-manager.js';
import {UiWindow} from '../source/client/ui_web/web/core/ui-window.js';
function target(extra={}) {
  const listeners=new Map(),captures=new Set();
  return {style:{setProperty(key,value){this[key]=value;}},hidden:false,offsetWidth:240,offsetHeight:400,scrollHeight:400,
    replaceChildren(){},getClientRects(){return this.hidden?[]:[{}];},setAttribute(){},
    addEventListener(type,fn){if(!listeners.has(type))listeners.set(type,new Set());listeners.get(type).add(fn);},
    removeEventListener(type,fn){listeners.get(type)?.delete(fn);},
    fire(type,event={}){for(const fn of [...listeners.get(type)||[]])fn(event);},
    count(){return [...listeners.values()].reduce((sum,set)=>sum+set.size,0);},
    setPointerCapture(id){captures.add(id);},hasPointerCapture(id){return captures.has(id);},
    releasePointerCapture(id){captures.delete(id);this.fire('lostpointercapture',{pointerId:id});},...extra};
}
function environment(){
 const host=target({innerWidth:1200,innerHeight:800}),doc=target(),frames=new Map();let sequence=0;
 Object.assign(globalThis,{window:host,document:doc,requestAnimationFrame:fn=>{frames.set(++sequence,fn);return sequence;},cancelAnimationFrame:id=>frames.delete(id)});
 const manager=new WindowManager({host});manager.setViewport({width:host.innerWidth,height:host.innerHeight},1);
 return {host,doc,manager,frames};
}
function shellRoot(){
 const title=target(),header=target({querySelector:selector=>selector==='h1'?title:close}),close=target(),panel=target();
 const root=target({querySelector:selector=>selector==='section'?panel:selector==='.window-header'?header:close});
 return {root,panel,header,close,title};
}
const pointer=(node,x=100,y=100,id=1)=>({target:node,currentTarget:node,clientX:x,clientY:y,pointerId:id,button:0,preventDefault(){}});
test('registration, activation, hidden windows, resize and scale stay in the manager',()=>{
 const {host,manager}=environment(),one=target(),two=target();let cancelled=0,activated=0;
 manager.register({window_id:'one',element:one,cancel:()=>cancelled++,onActivate:()=>activated++});
 manager.register({window_id:'two',element:two});assert.throws(()=>manager.register({window_id:'one',element:one}),/Duplicate/);
 manager.activate('one');assert.equal(manager.activeWindowId,'one');assert.ok(Number(one.style.zIndex)>Number(two.style.zIndex));assert.equal(activated,1);
 one.hidden=true;manager.refresh('one');assert.equal(manager.activeWindowId,'two');assert.ok(cancelled>0);
 one.hidden=false;manager.move('one',{x:9999,y:9999});manager.setScale(1.5);host.innerWidth=600;host.innerHeight=500;host.fire('resize');
 const p=manager.place('one');assert.ok(p.x>=0&&p.x+one.offsetWidth<=host.innerWidth/manager.scale);assert.ok(p.y>=0);
 assert.throws(()=>manager.setScale(0),/Invalid/);manager.unregister('two');assert.equal(manager.activeWindowId,'one');
 manager.dispose();assert.equal(host.count(),0);assert.equal(manager.windows.size,0);
});
test('shared shell captures drag, cancels on lifecycle changes and removes all listeners',()=>{
 const {host,doc,manager,frames}=environment(),{root,panel,header,close}=shellRoot();let regions=0,closes=0,cancels=0;
 header.closest=()=>null;
 const shell=new UiWindow(root,{manager,window_id:'storage',title:'Storage',onClose:()=>closes++,onCancel:()=>cancels++,onRegionsChanged:()=>regions++});
 shell.refresh();header.fire('pointerdown',pointer(header));assert.ok(header.hasPointerCapture(1));
 doc.fire('pointermove',pointer(header,250,150,2));assert.equal(frames.size,0);
 doc.fire('pointermove',pointer(header,250,150));assert.equal(frames.size,1);
 doc.fire('pointerup',pointer(header));assert.equal(frames.size,0);assert.equal(header.hasPointerCapture(1),false);assert.ok(regions>1);
 header.fire('pointerdown',pointer(header));manager.setScale(.9);assert.equal(header.hasPointerCapture(1),false);
 header.fire('pointerdown',pointer(header));host.fire('blur');assert.equal(header.hasPointerCapture(1),false);
 close.fire('click');assert.equal(closes,1);assert.ok(cancels>0);
 shell.dispose();shell.dispose();assert.equal(doc.count(),0);assert.equal(header.count(),0);assert.equal(close.count(),0);assert.equal(panel.count(),0);
 assert.equal(manager.windows.size,0);manager.dispose();assert.equal(host.count(),0);
});

import {tooltipPosition} from '../source/client/ui_web/web/core/ui-tooltip.js';
test('tooltip geometry flips and stays reachable at all scales and in small viewports',()=>{
 for(const scale of [.8,.9,1,1.1,1.25,1.4,1.5]){
  const viewport={width:1280,height:720},size={width:200,height:80};
  const near={x:viewport.width/scale-5,y:viewport.height/scale-5};
  const p=tooltipPosition(near,size,viewport,scale);
  assert.ok(p.x<near.x&&p.x>=0&&p.x+size.width<=viewport.width/scale);
  assert.ok(p.y>=0&&p.y+size.height<=viewport.height/scale);
 }
 assert.deepEqual(tooltipPosition({x:20,y:20},{width:200,height:80},{width:50,height:50},1),{x:0,y:0});
});

import {applySkin,skinVariable} from '../source/client/ui_web/web/core/skin.js';
test('skin swapping clears stale assets, detects missing images and cannot change geometry',async()=>{
 const values=new Map(),classes=new Map();const root={style:{setProperty:(key,value)=>values.set(key,value)},classList:{toggle:(key,value)=>classes.set(key,value)}};
 const options={baseUrl:'https://example.test/skin/',loadAsset:async url=>!url.includes('missing')};
 await applySkin(root,{assets:{'window.frame':'frame.png','button.close.normal':'close.png','equipment.background':'missing.png','inventory.columns':'999'}},options);
 assert.ok(values.get(skinVariable('window.frame')).includes('frame.png'));assert.equal(classes.get('has-close-asset'),true);
 assert.equal(values.get(skinVariable('button.close.hover')),values.get(skinVariable('button.close.normal')));
 assert.equal(values.get(skinVariable('equipment.background')),'none');assert.equal(values.has('--skin-inventory-columns'),false);
 await applySkin(root,{assets:{'window.frame':'replacement.png'}},options);
 assert.ok(values.get(skinVariable('window.frame')).includes('replacement.png'));assert.equal(classes.get('has-close-asset'),false);
 assert.equal(values.get(skinVariable('button.close.normal')),'none');
});

import {UiIconRegistry,uiIconDomains} from '../source/client/ui_web/web/core/ui-icons.js';
import {ItemIconResolver} from '../source/client/ui_web/web/content/item-icons.js';
test('structured UI icons are replaceable and isolated from item content',()=>{
 const registry=new UiIconRegistry();let changes=0;const remove=registry.subscribe(()=>changes++);
 registry.replace(Object.fromEntries(uiIconDomains.map(domain=>[domain,{test:'glyph.png'}])),'https://example.test/ui/');
 for(const domain of uiIconDomains)assert.equal(registry.resolve(domain+'.test'),'https://example.test/ui/glyph.png');
 assert.equal(registry.resolve('missing'),null);assert.throws(()=>registry.replace({items:{sword:'sword.png'}}),/domain/);
 const items=new ItemIconResolver({sword:'sword.png'},'https://example.test/content/');
 assert.equal(items.resolve('sword'),'https://example.test/content/sword.png');assert.equal(registry.resolve('sword'),null);
 registry.replace({currencies:{yang:'coin.png'}},'https://example.test/new/');assert.equal(registry.resolve('skills.test'),null);assert.equal(changes,2);
 remove();registry.replace({});assert.equal(changes,2);assert.equal(items.resolve('unknown'),null);
});

import {paintItemIcon} from '../source/client/ui_web/web/game-ui/item-icon.js';
import {UiEquipmentSlot} from '../source/client/ui_web/web/game-ui/ui-equipment-slot.js';
function node(tag='div'){
 const element=target({tag,children:[],dataset:{},classList:{toggle(){},add(){}},
  append(...children){this.children.push(...children);for(const child of children)child.parent=this;},
  replaceChildren(...children){this.children=[];this.append(...children);},
  replaceWith(replacement){const parent=this.parent;parent.children[parent.children.indexOf(this)]=replacement;replacement.parent=parent;},removeAttribute(){}});
 return element;
}
test('item icons preserve labels and quantity on missing images; equipment interactivity belongs to the caller',()=>{
 globalThis.document={createElement:tag=>node(tag)};
 const element=node(),item={name:'<Sword>',icon_id:'content.sword',quantity:5};
 paintItemIcon(element,item,{resolveItemIcon:()=>'/broken.png'});element.children[0].fire('error');
 assert.equal(element.children[0].textContent,item.name);assert.equal(element.children[1].textContent,5);
 const tile=UiEquipmentSlot({slot:'any-slot',label:'Any',height:32,x:0,y:0,resolveItemIcon:()=>null});
 tile.setItem(item);assert.equal(tile.element.disabled,true);
 tile.setItem(item,{enabled:true});assert.equal(tile.element.disabled,false);assert.equal(tile.element.children[0].textContent,item.name);
});

import {UiCurrency} from '../source/client/ui_web/web/core/ui-currency.js';
test('currency uses semantic UI icons, refreshes on replacement and unsubscribes on disposal',async()=>{
 globalThis.document={createElement:tag=>node(tag)};const icons=new UiIconRegistry(),element=node();
 icons.replace({currencies:{test:'coin.png'}},'https://example.test/');
 const currency=UiCurrency(element,{label:'Test currency',iconId:'currencies.test',icons,loadAsset:async()=>true});
 currency.setValue(1234);await Promise.resolve();assert.equal(element.children[2].textContent,'1,234');
 assert.ok(element.children[0].style.backgroundImage.includes('coin.png'));icons.replace({});
 assert.equal(element.children[0].style.backgroundImage,'none');assert.equal(icons.listeners.size,1);
 currency.dispose();assert.equal(icons.listeners.size,0);
});

test('relative placement rejects cycles and unknown or empty IDs',()=>{
 const manager=new WindowManager({host:null});manager.setViewport({width:1200,height:800});
 assert.throws(()=>manager.register({element:target()}),/stable window_id/);
 manager.register({window_id:'a',element:target(),relativeTo:'b'});manager.register({window_id:'b',element:target(),relativeTo:'a'});
 assert.throws(()=>manager.place('a'),/Cyclic/);assert.throws(()=>manager.place('missing'),/Unknown/);manager.dispose();
});
