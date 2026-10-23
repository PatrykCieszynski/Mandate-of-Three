import test from 'node:test';
import assert from 'node:assert/strict';
import {environment,target,measure,fire,capture,bagItem} from './fixtures.mjs';
import {ItemDragRuntime} from '../web/game-ui/drag/item-drag-runtime.js';
import {ownedItemPayload} from '../web/game-ui/items/item-drag-policy.js';
import {mountVendor} from '../web/screens/vendor/vendor-view.js';
import {isVendor,type VendorSnapshot} from '../web/screens/vendor/vendor-model.js';
const fixture=():VendorSnapshot=>({active:true,ready:true,busy:false,quoting:false,pending:false,items:[],quote:{},error:'',outcome:''});
test('vendor validates bounded server offers and preserves decimal Yang',()=>{
 const s=fixture();assert.ok(isVendor(s));s.quote={yang:'9000000000000000',rewards:[{type:'random_pool',pool:'books',icon_id:'mystery',quantity:1}],expires_at:123};assert.ok(isVendor(s));assert.ok(!isVendor({...s,quote:{...s.quote,yang:'9000000000000001'}}));assert.ok(!isVendor({...s,items:[{...bagItem,maximum:201,available:true}]}));
});
test('vendor accepts Inventory references, rejects Storage, supports partial amounts and recovery without placement checks',async()=>{
 const env=environment();Object.assign(globalThis,{HTMLElement:env.host.HTMLElement,getComputedStyle:env.host.getComputedStyle.bind(env.host)});
 const root=target();env.doc.body.append(root);
 const drag=new ItemDragRuntime({scale:()=>1,onRegionsChanged:()=>{}}),commands:unknown[]=[];
 const view=mountVendor(root,{manager:env.manager,drag,resolveItemIcon:()=>null,command:async(a,p)=>{commands.push([a,p]);return {ok:true};},close:()=>{},regions:()=>{}});
 const s=fixture();view.setState(s);const basket=root.querySelector<HTMLElement>('.vendor-basket')!;measure(basket,200,120);
 const source=target();env.doc.body.append(source);capture(source);let container:'inventory'|'storage'='inventory';const item=structuredClone(bagItem);const registration=drag.registerSource({element:source,payload:()=>ownedItemPayload(container,item,40,()=>null)});
 Object.defineProperty(env.doc,'elementFromPoint',{configurable:true,value:()=>basket});
 const drop=async()=>{fire(source,'pointerdown',2,2);fire(env.doc,'pointermove',300,300);fire(env.doc,'pointerup',300,300);await new Promise(r=>setTimeout(r,0));};
 await drop();assert.deepEqual(commands,[['edit',{id:item.id,amount:item.quantity}]]);assert.deepEqual(item,bagItem);
 container='storage';await drop();assert.equal(commands.length,1);drag.cancel();
 s.items=[{...item,quantity:1,maximum:2,available:true}];s.quote={yang:'0',rewards:[{type:'random_pool',pool:'books',quantity:1,icon_id:'mystery'}],expires_at:123};view.setState(s);
 assert.ok(root.querySelector('.vendor-mystery')?.textContent?.includes('?'));
 const offered=root.querySelector<HTMLButtonElement>('.vendor-item')!;offered.click();const amount=root.querySelector<HTMLInputElement>('input')!;amount.value='2';Array.from(root.querySelectorAll('button')).find(b=>b.textContent==='Set quantity')!.click();await new Promise(r=>setTimeout(r,0));assert.deepEqual(commands.at(-1),['edit',{id:item.id,amount:2}]);
 s.pending=true;s.items[0]!.available=false;s.quote={};view.setState(s);const recover=Array.from(root.querySelectorAll('button')).find(b=>b.textContent==='Check sale result')!;recover.click();await new Promise(r=>setTimeout(r,0));assert.deepEqual(commands.at(-1),['recover',{}]);
 view.dispose();registration.dispose();drag.dispose();env.manager.dispose();
});
