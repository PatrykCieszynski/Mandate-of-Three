import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target } from './fixtures.mjs';
import { mountCraft, isCraft, type CraftSnapshot } from '../web/screens/craft/craft-view.js';
import type { ItemPresentation } from '../web/game-ui/item-types.js';
import { DomainStore } from '../web/store.js';
const sword={id:'a'.repeat(32),revision:7,name:'Sword',icon_id:'iron_sword',height:3,quantity:1,tooltip:{rarity:'magic' as const,affixes:[{kind:'prefix' as const,lines:['+1 Attack']}]} };
const state=():CraftSnapshot=>({active:true,pending:false,busy:false,currency:{...sword,id:'b'.repeat(32),name:'Pył Odnowy',definition_id:'renewal_dust',icon_id:'renewal_dust',quantity:3,height:1},effect:'Reroll Magic',targets:[sword]});
test('currency mode requires deliberate target click, serializes Shift reuse and keeps updated identities',async()=>{
 const {manager,host,doc}=environment(),root=target();doc.body.append(root);
 const slot=doc.createElement('div');slot.className='inventory-item';slot.dataset.id=sword.id;root.append(slot);
 const sent:unknown[]=[];const replies:((v:{ok:boolean})=>void)[]=[];let closed=0;
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:p=>{sent.push(p);return new Promise(resolve=>replies.push(resolve));},retry:async()=>{sent.push('retry');return {ok:true};},close:()=>{closed++;},cancelCarry:()=>{},regions:()=>{}});
 const click=(button=0,shiftKey=false)=>slot.dispatchEvent(new host.MouseEvent('pointerdown',{bubbles:true,button,shiftKey}));
 click();assert.equal(sent.length,0,'ordinary carrying cannot craft');
 const snapshot=state();assert.ok(isCraft(snapshot));const store=new DomainStore();assert.ok(store.apply({v:1,type:'craft.updated',payload:snapshot as never}));
 assert.equal(isCraft({...snapshot,targets:[{...sword,revision:-1}]}),false);
 view.setState(snapshot);assert.equal(slot.dataset.craftTarget,'valid');click(0,true);click(0,true);assert.deepEqual(sent,[{id:sword.id,revision:7}]);
 // Authoritative Inventory/receipt reconciliation publishes the new revisions
 // before the response. Shift must retain the remaining stack, not stale DTOs.
 const next={...snapshot,currency:{...(snapshot.currency as ItemPresentation),revision:1,quantity:2},targets:[{...sword,revision:8}]};
 view.setState({...next,pending:true,busy:true});click(0,true);assert.equal(sent.length,1);
 view.setState(next);replies.shift()!({ok:true});await new Promise(r=>setTimeout(r,0));assert.ok(view.engaged());
 click();assert.deepEqual(sent.at(-1),{id:sword.id,revision:8});replies.shift()!({ok:true});await new Promise(r=>setTimeout(r,0));assert.equal(view.engaged(),false);assert.equal(closed,1);
 view.setState({...snapshot,active:false});view.setState(snapshot);click(2);assert.equal(view.engaged(),false);assert.equal(sent.length,2,'RMB cancels without an additional operation');
 view.setState({...snapshot,active:false});view.setState(snapshot);doc.dispatchEvent(new host.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(view.engaged(),false);
 view.setState({...snapshot,active:false});view.setState({...snapshot,pending:true});click();assert.equal(sent.length,2);const retry=root.querySelector('button')!;assert.equal(retry.hidden,false);retry.click();await new Promise(r=>setTimeout(r,0));assert.equal(sent.at(-1),'retry');assert.equal(closed,4,'terminal recovery closes native targeting even when no cursor was armed');
 view.dispose();manager.dispose();host.close();
});
test('ineligible targets and depleted stacks never send a new crafting operation',()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);let attempts=0;
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async()=>{attempts++;return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 const snapshot=state();view.setState({...snapshot,targets:[{...sword,tooltip:{rarity:'rare',affixes:[]}}]});assert.ok(view.reason(sword));void view.use(sword,true);assert.equal(attempts,0);
 view.setState({...snapshot,currency:{}});assert.equal(view.engaged(),false);view.dispose();manager.dispose();host.close();
});

test('outside clicks cancel targeting and reach other windows without losing pending recovery',()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);
 const other=doc.createElement('button');other.textContent='Trade accept';doc.body.append(other);
 let actions=0,attempts=0,closes=0;other.addEventListener('pointerdown',()=>actions++);
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async()=>{attempts++;return {ok:true};},retry:async()=>({ok:true}),close:()=>{closes++;},cancelCarry:()=>{},regions:()=>{}});
 view.setState(state());const click=new host.MouseEvent('pointerdown',{button:0,bubbles:true,cancelable:true});other.dispatchEvent(click);
 assert.equal(view.engaged(),false);assert.equal(actions,1);assert.equal(click.defaultPrevented,false);assert.equal(attempts,0);assert.equal(closes,1);
 view.setState({...state(),active:false});view.setState(state());view.setState({...state(),pending:true});other.dispatchEvent(new host.MouseEvent('pointerdown',{button:0,bubbles:true,cancelable:true}));
 assert.equal(view.engaged(),false);assert.equal(actions,2);assert.equal(root.querySelector('button')!.hidden,false,'cancellation leaves unresolved receipt recovery visible');
 view.dispose();manager.dispose();host.close();
});
