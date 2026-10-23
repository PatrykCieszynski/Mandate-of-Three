import type { InventoryItem } from '../web/protocol/contracts.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target, measure, fire, capture, bagItem } from './fixtures.mjs';
import { ItemDragRuntime } from '../web/game-ui/drag/item-drag-runtime.js';
import { ownedItemPayload } from '../web/game-ui/items/item-drag-policy.js';
import { mountBottomHud } from '../web/inventory/bottom-hud.js';
import { isHotbar, type HotbarSnapshot } from '../web/inventory/hotbar-model.js';
function fixture():HotbarSnapshot {return {slots:Array.from({length:16},()=>({})),vitals:{ready:true,hp:75,max_hp:100,mp:20,max_mp:50,level:'3'},ready:true,busy:false,error:''};}
test('hotbar validates sixteen slots and authoritative vitals',()=>{
 const s=fixture();assert.ok(isHotbar(s));assert.ok(!isHotbar({...s,slots:[]}));assert.ok(!isHotbar({...s,vitals:{...s.vitals,hp:NaN}}));assert.ok(!isHotbar({...s,slots:[{id:'x',name:'bad',icon_id:'x',quantity:-1,available:true},...s.slots.slice(1)]}));
});
test('two key banks, current meters, assignment-only drag and system actions',async()=>{
 const env=environment();Object.assign(globalThis,{HTMLElement:env.host.HTMLElement,getComputedStyle:env.host.getComputedStyle.bind(env.host)});
 const drag=new ItemDragRuntime({scale:()=>1,onRegionsChanged:()=>{}}),root=target();env.doc.body.append(root);
 const commands:unknown[]=[];
 const hud=mountBottomHud(root,{drag,resolveItemIcon:()=>null,assign:async(slot,id)=>{commands.push(['assign',slot,id]);return {ok:true};},clear:async slot=>{commands.push(['clear',slot]);return {ok:true};},activate:async slot=>{commands.push(['activate',slot]);return {ok:true};},system:async action=>{commands.push(['system',action]);return {ok:true};},regions:()=>{}});
 const state=fixture();hud.render(state);assert.equal(root.querySelectorAll('.bottom-hud-slot').length,16);assert.equal(root.querySelectorAll('.bottom-hud-key')[8]?.textContent,'F1');assert.equal(root.querySelector('progress[aria-label=HP]')?.getAttribute('max'),'100');
 const button=root.querySelector<HTMLButtonElement>('[data-slot="15"]')!;measure(button,32,36);
 const source=target();env.doc.body.append(source);capture(source);
 const item:InventoryItem={...structuredClone(bagItem),primary_action:'USE'};let container:'inventory'|'storage'='inventory';drag.registerSource({element:source,payload:()=>ownedItemPayload(container,item,40,()=>null)});
 Object.defineProperty(env.doc,'elementFromPoint',{configurable:true,value:()=>button});
 fire(source,'pointerdown',2,2);fire(env.doc,'pointermove',300,300);fire(env.doc,'pointerup',300,300);
 await new Promise(r=>setTimeout(r,0));assert.deepEqual(commands,[['assign',15,item.id]]);assert.deepEqual(item,{...bagItem,primary_action:'USE'},'assignment never relocates inventory');
 for(const action of ['EQUIP','NONE',undefined] as const){if(action===undefined)Reflect.deleteProperty(item,'primary_action');else item.primary_action=action;fire(source,'pointerdown',2,2);fire(env.doc,'pointermove',300,300);fire(env.doc,'pointerup',300,300);await new Promise(r=>setTimeout(r,0));assert.equal(commands.length,1,'non-USE items cannot assign');drag.cancel();}item.primary_action='USE';
 container='storage';fire(source,'pointerdown',2,2);fire(env.doc,'pointermove',300,300);fire(env.doc,'pointerup',300,300);await new Promise(r=>setTimeout(r,0));assert.equal(commands.length,1,'storage subjects cannot assign a shortcut');drag.cancel();
 state.slots[15]={id:item.id,name:item.name,icon_id:item.icon_id,quantity:2,available:true};hud.render(state);button.click();await new Promise(r=>setTimeout(r,0));assert.deepEqual(commands.at(-1),['activate',15]);
 button.dispatchEvent(new env.host.MouseEvent('contextmenu',{bubbles:true,cancelable:true}));await new Promise(r=>setTimeout(r,0));assert.deepEqual(commands.at(-1),['clear',15]);
 const options=Array.from(root.querySelectorAll('button')).find(b=>b.getAttribute('aria-label')==='Options')!;options.click();await new Promise(r=>setTimeout(r,0));assert.deepEqual(commands.at(-1),['system','options']);
 hud.dispose();assert.equal(drag.registrationCount,1);drag.dispose();env.manager.dispose();
});
