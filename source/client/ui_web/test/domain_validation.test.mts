import test from 'node:test';
import assert from 'node:assert/strict';
import {decodeAndValidate, encode, readDomainSnapshot} from '../web/protocol.js';
import {DomainStore} from '../web/store.js';
import {WebBridge} from '../web/bridge.js';
import {bagItem, equippedItem} from './fixtures.mjs';
import type {DomainName, RawObject} from '../web/protocol/contracts.js';

const inventory = {columns:5, rows:9, pages:4, items:[bagItem]};
const snapshot = {inventory, equipment:{items:[equippedItem], stats:{attack:10.5}},
  wallet:{balance:1234, ready:true}, hud:{inventory_open:true, equipment_open:true, ui_scale:1, viewport:{width:1920, height:1080}}};
const unsafeNumbers = [NaN, Infinity, -Infinity, -1, 0.5, 1e100, Number.MAX_SAFE_INTEGER + 1];
function update(domain: DomainName, payload: RawObject) {
  // Use unknown-value envelope validation without JSON.stringify turning NaN into null.
  return decodeAndValidate({v:1, type:domain+'.updated', payload});
}
function rejects(domain: DomainName, payload: RawObject) {
  const store = new DomainStore();
  assert.equal(store.apply(decodeAndValidate({v:1, type:'ui.snapshot', payload:snapshot})), true);
  const previous = store.state, previousDomain = previous[domain];
  assert.equal(store.apply(update(domain, payload)), false, domain+' should reject '+String(Object.values(payload)));
  assert.equal(store.state, previous);
  assert.equal(store.state[domain], previousDomain);
  assert.deepEqual(store.state, snapshot);
  assert.equal(readDomainSnapshot({[domain]:payload}), null);
}

test('inventory dimensions reject non-finite, fractional, zero, negative and extreme work sizes',()=>{
  for (const field of ['columns','rows','pages']) {
    for (const bad of [...unsafeNumbers, 0]) rejects('inventory', {...inventory, [field]:bad});
  }
  rejects('inventory', {...inventory, columns:6});
  rejects('inventory', {...inventory, rows:10});
  rejects('inventory', {...inventory, pages:5});
  // Even an empty grid must not trigger enormous DOM creation loops.
  rejects('inventory', {columns:1e9, rows:1e9, pages:1, items:[]});
  rejects('inventory', {...inventory, items:Array.from({length:181},()=>bagItem)});
});

test('inventory coordinates and footprints must be safe integers fitting the supplied grid',()=>{
  for (const field of ['x','y','page']) {
    for (const bad of unsafeNumbers) rejects('inventory', {...inventory, items:[{...bagItem, [field]:bad}]});
  }
  for (const [field, bad] of [['x',5],['y',9],['page',4],['height',0],['height',4],['height',1.5]] satisfies [string,number][]) {
    rejects('inventory', {...inventory, items:[{...bagItem, [field]:bad}]});
  }
  rejects('inventory', {...inventory, items:[{...bagItem,y:7}]}); // 1×3 extends below row 9.
  rejects('inventory', {...inventory, columns:2, items:[{...bagItem,x:2}]});
  rejects('inventory', {...inventory, rows:2});
  rejects('inventory', {...inventory, pages:1, items:[{...bagItem,page:1}]});
});

test('both item domains reject invalid revisions, quantities and heights',()=>{
  for (const field of ['revision','quantity','height']) {
    for (const bad of unsafeNumbers) {
      rejects('inventory', {...inventory, items:[{...bagItem, [field]:bad}]});
      rejects('equipment', {items:[{...equippedItem, [field]:bad}]});
    }
  }
  for (const field of ['quantity','height']) rejects('equipment', {items:[{...equippedItem,[field]:0}]});
  rejects('equipment', {items:[{...equippedItem,height:4}]});
});

test('wallet and stats reject invalid numeric values while native fractional stats remain valid',()=>{
  for (const bad of unsafeNumbers) rejects('wallet', {balance:bad});
  rejects('wallet', {balance:9000000000000001});
  for (const bad of [NaN,Infinity,-Infinity,-1,1e100,Number.MAX_SAFE_INTEGER+1]) rejects('equipment', {stats:{attack:bad}});
  assert.ok(readDomainSnapshot({equipment:{stats:{attack:10.5}},wallet:{balance:0}}));
  assert.ok(readDomainSnapshot({wallet:{balance:9000000000000000}}));
});

test('HUD scales and viewport dimensions reject non-finite, unsupported and extreme geometry',()=>{
  for (const bad of [...unsafeNumbers,0,0.01,0.79,1.01,1.51,100]) rejects('hud', {...snapshot.hud,ui_scale:bad});
  for (const field of ['width','height']) {
    for (const bad of [...unsafeNumbers,16385]) rejects('hud', {...snapshot.hud,viewport:{width:1920,height:1080,[field]:bad}});
  }
  for (const scale of [0.8,0.9,1,1.1,1.25,1.4,1.5]) {
    assert.ok(readDomainSnapshot({hud:{ui_scale:scale,viewport:{width:7680,height:4320}}}));
  }
  assert.ok(readDomainSnapshot({hud:{viewport:{width:0,height:0}}}));
  assert.ok(readDomainSnapshot({hud:{viewport:{width:16384,height:16384}}}));
});

test('valid edge coordinates, integer counters and supported presentation state remain unchanged',()=>{
  const edgeItem={...bagItem,x:4,y:6,page:3,height:3,revision:0,quantity:Number.MAX_SAFE_INTEGER};
  const valid={...snapshot,inventory:{...inventory,items:[edgeItem]}};
  const store=new DomainStore();
  assert.equal(store.apply(decodeAndValidate({v:1,type:'ui.snapshot',payload:valid})),true);
  assert.deepEqual(readDomainSnapshot(store.state),valid);
  assert.ok(readDomainSnapshot({inventory:{columns:2,rows:2,pages:1,items:[{...bagItem,x:1,y:0,page:0,height:2}]}}));
  // The store owns a copy; changing the input cannot corrupt the accepted state.
  valid.inventory.items[0]=bagItem;
  assert.deepEqual(readDomainSnapshot(store.state)?.inventory?.items,[edgeItem]);
});

test('malformed individual updates preserve last valid domains and allow unrelated updates to render',()=>{
  const store=new DomainStore(),rendered: ReturnType<typeof readDomainSnapshot>[]=[];
  const bridge=new WebBridge({send:()=>{},subscribe:()=>{},onState:message=>{
    if(store.apply(message)) rendered.push(readDomainSnapshot(store.state));
  }});
  bridge.receive(encode('ui.snapshot',snapshot));
  const savedInventory=store.state.inventory, savedEquipment=store.state.equipment, savedHud=store.state.hud;
  bridge.receive(encode('inventory.updated',{...inventory,items:[{...bagItem,revision:-1}]}));
  bridge.receive(encode('equipment.updated',{stats:{attack:-1}}));
  bridge.receive(encode('hud.updated',{ui_scale:0}));
  assert.equal(rendered.length,1);
  bridge.receive(encode('wallet.updated',{balance:4321,ready:true}));
  assert.equal(rendered.length,2);
  const renderable=rendered.at(-1);assert.ok(renderable);
  assert.equal(renderable.wallet?.balance,4321);
  assert.equal(store.state.inventory,savedInventory);assert.equal(store.state.equipment,savedEquipment);assert.equal(store.state.hud,savedHud);
  bridge.receive(encode('wallet.updated',{balance:-1}));
  bridge.receive(encode('equipment.updated',{items:[equippedItem],stats:{attack:12.5}}));
  assert.equal(rendered.length,3);
  const next=rendered.at(-1);assert.ok(next);assert.equal(next.wallet?.balance,4321);assert.equal(next.equipment?.stats?.attack,12.5);
});

test('a malformed domain before the first snapshot cannot block valid startup domains',()=>{
  const store=new DomainStore();
  assert.equal(store.apply(update('inventory',{columns:Infinity,rows:9,pages:4,items:[]})),false);
  assert.deepEqual(store.state,{});
  assert.equal(store.apply(update('wallet',{balance:42,ready:true})),true);
  assert.equal(store.apply(update('hud',{inventory_open:true,ui_scale:0.9})),true);
  assert.deepEqual(readDomainSnapshot(store.state),{wallet:{balance:42,ready:true},hud:{inventory_open:true,ui_scale:0.9}});
});

test('JSON overflow is rejected at the domain boundary and full snapshots replace state atomically',()=>{
  const store=new DomainStore(),bridge=new WebBridge({send:()=>{},subscribe:()=>{},onState:message=>{store.apply(message);}});
  bridge.receive(encode('ui.snapshot',snapshot));const previous=store.state;
  // Valid JSON can still produce Infinity: 1e309 must not be trusted as a number.
  bridge.receive('{"v":1,"type":"inventory.updated","payload":{"columns":1e309,"rows":9,"pages":4,"items":[]}}');
  assert.equal(store.state,previous);assert.deepEqual(readDomainSnapshot(store.state),snapshot);
  bridge.receive(encode('ui.snapshot',{...snapshot,inventory:{...inventory,columns:0},wallet:{balance:99}}));
  assert.equal(store.state,previous);assert.equal(readDomainSnapshot(store.state)?.wallet?.balance,1234);
  bridge.receive(encode('wallet.updated',{balance:5678}));assert.equal(readDomainSnapshot(store.state)?.wallet?.balance,5678);
  bridge.receive(encode('ui.snapshot',{inventory:{...inventory,items:[]}}));
  assert.deepEqual(readDomainSnapshot(store.state),{inventory:{...inventory,items:[]}});
});
