import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const base = new URL('../source/client/ui_web/web/', import.meta.url);
const protocolUrl = 'data:text/javascript;base64,' + Buffer.from(await readFile(new URL('protocol.js',base),'utf8')).toString('base64');
const protocol = await import(protocolUrl);
const bridgeCode = (await readFile(new URL('bridge.js',base),'utf8')).replace("'./protocol.js'",JSON.stringify(protocolUrl));
const {WebBridge,reportInteractiveRegions} = await import('data:text/javascript;base64,'+Buffer.from(bridgeCode).toString('base64'));
const {DomainStore} = await import('data:text/javascript;base64,'+Buffer.from(await readFile(new URL('store.js',base),'utf8')).toString('base64'));
function fixture(timeoutMs=30) {
 const sent=[];const state=new DomainStore();
 const bridge=new WebBridge({send:m=>sent.push(protocol.decode(m)),subscribe:()=>{},onState:m=>state.apply(m),timeoutMs});
 return {bridge,sent,state};
}
test('strict v1 framing and UTF8 byte limit',()=>{
 for(const bad of ['bad',JSON.stringify({v:2,type:'ui.ready',payload:{}}),JSON.stringify({v:1,type:'x',payload:[]}),JSON.stringify({v:1,type:'x',payload:{},extra:1}),JSON.stringify({v:1,type:'x',id:4,payload:{}}),'é'.repeat(9000)]) assert.throws(()=>protocol.decode(bad));
 assert.deepEqual(protocol.decode(protocol.encode('ui.ready')),{v:1,type:'ui.ready',payload:{}});
});
test('correlation, late results, domain update separate from results',async()=>{
 const {bridge,sent,state}=fixture();const pending=bridge.request('inventory.move_item',{x:1});const id=sent.at(-1).id;
 bridge.receive(protocol.encode('command.result',{ok:true},'unknown'));assert.equal(bridge.pending.size,1);
 bridge.receive(protocol.encode('inventory.updated',{revision:2}));
 bridge.receive(protocol.encode('command.result',{ok:true},id));assert.deepEqual(await pending,{ok:true});
 assert.deepEqual(state.state,{inventory:{revision:2}});
 bridge.receive(protocol.encode('command.result',{ok:false},id));assert.equal(bridge.pending.size,0);
});
test('ready cancels pending; snapshot replaces disposable state',async()=>{
 const {bridge,sent,state}=fixture();const pending=bridge.request('inventory.move_item',{});const id=sent.at(-1).id;
 const cancelled=assert.rejects(pending,/reload/);bridge.ready();await cancelled;
 assert.equal(sent.at(-1).type,'ui.ready');assert.equal(bridge.pending.size,0);
 bridge.receive(protocol.encode('ui.snapshot',{inventory:{revision:7},wallet:{yang:90}}));
 bridge.receive(protocol.encode('ui.snapshot',{inventory:{revision:8}}));
 bridge.receive(protocol.encode('command.result',{ok:true},id));
 assert.deepEqual(state.state,{inventory:{revision:8}});
});
test('timeout and invalid result cannot mutate state',async()=>{
 const {bridge,sent,state}=fixture(5);const pending=bridge.request('inventory.move_item',{});
 bridge.receive(protocol.encode('command.result',{ok:'yes'},sent.at(-1).id));
 await assert.rejects(pending,/timeout/);assert.equal(bridge.pending.size,0);assert.deepEqual(state.state,{});
});

test('invalid domain sections and unknown state messages are ignored',()=>{
 const {bridge,state}=fixture();
 bridge.receive(protocol.encode('ui.snapshot',{inventory:5}));
 bridge.receive(protocol.encode('ui.snapshot',{future:{}}));
 bridge.receive(protocol.encode('get_tree().quit',{}));
 assert.deepEqual(state.state,{});
 bridge.receive(protocol.encode('wallet.updated',{yang:30}));
 assert.deepEqual(state.state,{wallet:{yang:30}});
});

test('presentation Escape shortcut is explicit and cannot mutate state',()=>{
 const keys=[];
 const bridge=new WebBridge({send:()=>{},subscribe:()=>{},onShortcut:key=>keys.push(key)});
 bridge.receive(protocol.encode('ui.shortcut',{key:'Escape'}));
 bridge.receive(protocol.encode('ui.shortcut',{key:'W'}));
 bridge.receive(protocol.encode('ui.shortcut',{key:'Escape',method:'quit'}));
 bridge.receive(protocol.encode('ui.shortcut',{key:'Escape'},'request'));
 assert.deepEqual(keys,['Escape']);
});

const {carriedCell,placement} = await import('data:text/javascript;base64,'+Buffer.from(await readFile(new URL('inventory/placement.js',base),'utf8')).toString('base64'));
test('carried footprint snaps nearest to its origin regardless of grab height',()=>{
 for(const height of [1,2,3]) {
  const inventory={columns:5,rows:9,pages:4,items:[]},item={id:'sword',height};
  for(const grabY of [5,height*40-5]) {
   const grab={x:20,y:grabY};
   const target=carriedCell({x:80+grab.x,y:120+grab.y},grab,40);
   assert.deepEqual(target,{x:2,y:3});
   assert.equal(placement(inventory,item,target.x,target.y,0).valid,true);
  }
 }
 assert.deepEqual(carriedCell({x:99,y:139},{x:0,y:0},40),{x:2,y:3});
 assert.deepEqual(carriedCell({x:101,y:141},{x:0,y:0},40),{x:3,y:4});
 const inventory={columns:5,rows:9,pages:4,items:[{id:'other',x:2,y:4,height:1,page:0}]};
 assert.equal(placement(inventory,{id:'sword',height:3},2,3,0).valid,false);
 assert.equal(placement(inventory,{id:'sword',height:3},2,7,0).valid,false);
});

import {WindowManager} from '../source/client/ui_web/web/core/window-manager.js';
test('window placement uses measured neighbors and preserves/clamps manual positions',()=>{
 const hiddenLayout=new WindowManager({host:null});
 hiddenLayout.setViewport({width:1920,height:1080},1);
 hiddenLayout.register({window_id:'hidden',element:{style:{setProperty(){}},getClientRects:()=>[]}});
 hiddenLayout.register({window_id:'visible',element:{style:{setProperty(){}},getClientRects:()=>[{}],offsetWidth:220,offsetHeight:400},relativeTo:'hidden',defaultOffset:{x:-16,y:240}});
 const fallback=hiddenLayout.place('visible');assert.ok(Number.isFinite(fallback.x)&&fallback.x+220<=1920);
 const layout=new WindowManager({host:null}),bag={style:{setProperty(){}},offsetWidth:260,offsetHeight:480,getClientRects:()=>[{}]},equipment={style:{setProperty(){}},offsetWidth:220,offsetHeight:400,getClientRects:()=>[{}]};
 layout.register({window_id:'inventory',element:bag,defaultOffset:{x:-16,y:240}});
 layout.register({window_id:'equipment',element:equipment,relativeTo:'inventory',relativeOffset:{x:-12,y:0}});
 for(const [width,height,scale] of [[1280,720,.8],[1280,720,.9],[1920,1080,1],[2560,1440,1.1],[3840,2160,1.5]]){
  layout.setViewport({width,height},scale);
  const right=layout.place('inventory'),left=layout.place('equipment');
  assert.equal(left.x+equipment.offsetWidth+12,right.x);
  assert.ok(right.y+bag.offsetHeight<=height/scale);
 }
 bag.offsetWidth=330;assert.equal(layout.place('equipment').x+220+12,layout.place('inventory').x);
 layout.move('equipment',{x:40,y:50});bag.offsetWidth=250;
 assert.deepEqual(layout.place('equipment'),{x:40,y:50});
 layout.move('equipment',{x:9999,y:9999});layout.setViewport({width:1280,height:720},.9);
 const clamped=layout.place('equipment');assert.ok(clamped.x+220<=1280/.9&&clamped.y+400<=720/.9);
});

test('interactive-region teardown cancels queued reports and cannot schedule new ones',()=>{
 const frames=new Map();let sequence=0,disconnected=false;
 globalThis.requestAnimationFrame=fn=>{frames.set(++sequence,fn);return sequence;};globalThis.cancelAnimationFrame=id=>frames.delete(id);
 globalThis.ResizeObserver=class{observe(){} disconnect(){disconnected=true;}};
 globalThis.window={addEventListener(){},removeEventListener(){}};
 const sent=[],regions=reportInteractiveRegions({event:(...args)=>sent.push(args)},[]);
 assert.equal(frames.size,1);regions.dispose();assert.equal(frames.size,0);assert.equal(disconnected,true);
 regions.refresh();assert.equal(frames.size,0);assert.equal(sent.length,0);
});
