import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target } from './fixtures.mjs';
import { mountCraft, isCraft, CRAFT_CURRENCIES, type CraftSnapshot } from '../web/screens/craft/craft-view.js';
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

test('Rare currencies use the same explicit cursor with correct rarity targets and Shift revisions',async()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);
 const sent:unknown[]=[];
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async p=>{sent.push(p);return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 for(const currency of ['ascension_ember','renewal_prism']) {
   assert.ok(CRAFT_CURRENCIES.includes(currency));
   const required=currency==='ascension_ember'?'normal':'rare';
   const target={...sword,tooltip:{rarity:required as 'normal'|'rare',affixes:[]}};
   const snapshot={...state(),currency:{...(state().currency as ItemPresentation),definition_id:currency},targets:[target]};
   view.setState({...snapshot,active:false});view.setState(snapshot);
   assert.equal(view.reason(target),'');await view.use(target,true);assert.ok(view.engaged());
   const next={...target,revision:8,tooltip:{rarity:'rare' as const,affixes:[]}};
   view.setState({...snapshot,targets:[next]});
   if(currency==='ascension_ember') {assert.ok(view.reason(next));await view.use(next,true);}
   else {assert.equal(view.reason(next),'');await view.use(next,false);assert.equal(view.engaged(),false);assert.deepEqual(sent.at(-1),{id:sword.id,revision:8});}
   for(const rarity of ['normal','magic','rare'] as const) {
     view.setState({...snapshot,targets:[{...target,tooltip:{rarity,affixes:[]}}]});
     assert.equal(view.reason(target)==='',rarity===required);
   }
 }
 assert.equal(sent.length,3,'creation cannot repeat on a newly Rare target; reforge can repeat with the latest revision');
 view.dispose();manager.dispose();host.close();
});

test('awakening uses Magic targets only and cannot repeat on the promoted Rare item',async()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);
 let attempts=0;
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async()=>{attempts++;return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 assert.ok(CRAFT_CURRENCIES.includes('awakening_seal'));
 const snapshot={...state(),currency:{...(state().currency as ItemPresentation),definition_id:'awakening_seal'}};
 view.setState(snapshot);assert.equal(view.reason(sword),'');await view.use(sword,true);assert.equal(attempts,1);assert.ok(view.engaged());
 for(const rarity of ['rare','normal'] as const) {
   view.setState({...snapshot,targets:[{...sword,revision:8,tooltip:{rarity,affixes:[]}}]});
   assert.ok(view.reason(sword));await view.use(sword,true);assert.equal(attempts,1);
 }
 view.dispose();manager.dispose();host.close();
});

test('cleanse accepts nonempty Magic/Rare only and stops repeat after the Normal snapshot',async()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);let attempts=0;
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async()=>{attempts++;return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 assert.ok(CRAFT_CURRENCIES.includes('cleansing_salt'));
 const snapshot={...state(),currency:{...(state().currency as ItemPresentation),definition_id:'cleansing_salt'}};
 for(const rarity of ['magic','rare'] as const) {
   const target={...sword,tooltip:{...sword.tooltip,rarity}};
   view.setState({...snapshot,active:false});view.setState({...snapshot,targets:[target]});
   assert.equal(view.reason(target),'');await view.use(target,true);assert.ok(view.engaged());
   view.setState({...snapshot,targets:[{...target,revision:8,tooltip:{rarity:'normal',affixes:[]}}]});
   assert.ok(view.reason(target));const count=attempts;await view.use(target,true);assert.equal(attempts,count);
   view.setState({...snapshot,targets:[{...target,tooltip:{rarity,affixes:[]}}]});assert.ok(view.reason(target));
 }
 assert.equal(attempts,2);view.dispose();manager.dispose();host.close();
});

test('Rare extension preserves targeting until the authoritative six-affix capacity',async()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);const sent:unknown[]=[];
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async p=>{sent.push(p);return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 assert.ok(CRAFT_CURRENCIES.includes('completion_core'));
 const candidate={...sword,tooltip:{rarity:'rare' as const,affixes:Array.from({length:5},(_,i)=>({kind:(i<3?'prefix':'suffix') as 'prefix'|'suffix',lines:['+1 test']}))}};
 const snapshot={...state(),currency:{...(state().currency as ItemPresentation),definition_id:'completion_core'},targets:[candidate]};
 view.setState(snapshot);assert.equal(view.reason(candidate),'');await view.use(candidate,true);assert.ok(view.engaged());assert.deepEqual(sent,[{id:sword.id,revision:7}]);
 view.setState({...snapshot,targets:[{...candidate,revision:8,tooltip:{rarity:'rare',affixes:[...candidate.tooltip.affixes,{kind:'suffix' as const,lines:['+1 test']}]}}]});
 assert.ok(view.reason(candidate));await view.use(candidate,true);assert.equal(sent.length,1);
 for(const rarity of ['magic','normal'] as const){view.setState({...snapshot,targets:[{...sword,tooltip:{rarity,affixes:[]}}]});assert.ok(view.reason(candidate));}
 view.dispose();manager.dispose();host.close();
});

test('random removal repeats with latest revision until empty and never changes rarity eligibility',async()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);const sent:unknown[]=[];
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async p=>{sent.push(p);return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 assert.ok(CRAFT_CURRENCIES.includes('dispersal_chisel'));
 const snapshot={...state(),currency:{...(state().currency as ItemPresentation),definition_id:'dispersal_chisel'}};
 for(const rarity of ['magic','rare'] as const) {
   const candidate={...sword,tooltip:{rarity,affixes:[sword.tooltip.affixes[0]!,{kind:'suffix' as const,lines:['+1 test']}]}};
   view.setState({...snapshot,active:false});view.setState({...snapshot,targets:[candidate]});
   assert.equal(view.reason(candidate),'');await view.use(candidate,true);assert.ok(view.engaged());
   view.setState({...snapshot,targets:[{...candidate,revision:8,tooltip:{rarity,affixes:[candidate.tooltip.affixes[0]!]}}]});
   assert.equal(view.reason(candidate),'');await view.use(candidate,true);assert.deepEqual(sent.at(-1),{id:sword.id,revision:8});
   view.setState({...snapshot,targets:[{...candidate,revision:9,tooltip:{rarity,affixes:[]}}]});
   assert.ok(view.reason(candidate));const count=sent.length;await view.use(candidate,true);assert.equal(sent.length,count);
 }
 view.setState({...snapshot,targets:[{...sword,tooltip:{rarity:'normal',affixes:[]}}]});assert.ok(view.reason(sword));
 assert.equal(sent.length,4);view.dispose();manager.dispose();host.close();
});

test('value rerolls allow repeated nonempty Magic/Rare and always use refreshed revisions',async()=>{
 const {manager,doc,host}=environment(),root=target();doc.body.append(root);const sent:unknown[]=[];
 const view=mountCraft(root,{resolveItemIcon:()=>null,execute:async p=>{sent.push(p);return {ok:true};},retry:async()=>({ok:true}),close:()=>{},cancelCarry:()=>{},regions:()=>{}});
 assert.ok(CRAFT_CURRENCIES.includes('attunement_prism'));
 const snapshot={...state(),currency:{...(state().currency as ItemPresentation),definition_id:'attunement_prism'}};
 for(const rarity of ['magic','rare'] as const) {
   const candidate={...sword,tooltip:{...sword.tooltip,rarity}};
   view.setState({...snapshot,active:false});view.setState({...snapshot,targets:[candidate]});
   assert.equal(view.reason(candidate),'');await view.use(candidate,true);assert.ok(view.engaged());
   view.setState({...snapshot,targets:[{...candidate,revision:8}]});await view.use(candidate,true);assert.deepEqual(sent.at(-1),{id:sword.id,revision:8});
   view.setState({...snapshot,targets:[{...candidate,tooltip:{rarity,affixes:[]}}]});assert.ok(view.reason(candidate));
 }
 view.setState({...snapshot,targets:[{...sword,tooltip:{rarity:'normal',affixes:[]}}]});assert.ok(view.reason(sword));assert.equal(sent.length,4);
 view.dispose();manager.dispose();host.close();
});
