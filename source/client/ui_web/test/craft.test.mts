import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target } from './fixtures.mjs';
import { mountCraft, isCraft, type CraftSnapshot } from '../web/screens/craft/craft-view.js';
import { DomainStore } from '../web/store.js';
const sword={id:'a'.repeat(32),revision:7,name:'Sword',icon_id:'iron_sword',height:3,quantity:1,tooltip:{rarity:'rare' as const,affixes:[]}};
const state=():CraftSnapshot=>({active:true,pending:false,busy:false,currency:{...sword,id:'b'.repeat(32),name:'Iskra Przemiany',icon_id:'change_spark',height:1},effect:'Normal to Magic',targets:[sword]});
test('craft validates authoritative snapshots and sends only selected identity',async()=>{
 const {manager,host}=environment(),root=target();const sent:unknown[]=[];
 const view=mountCraft(root,{manager,resolveItemIcon:()=>null,execute:async p=>{sent.push(p);return {ok:true};},retry:async()=>{sent.push('retry');return {ok:true};},close:()=>{},regions:()=>{}});
 const snapshot=state();assert.ok(isCraft(snapshot));const store=new DomainStore();assert.ok(store.apply({v:1,type:'craft.updated',payload:snapshot as never}));
 assert.equal(isCraft({...snapshot,targets:[{...sword,revision:-1}]}),false);
 view.setState(snapshot);const select=root.querySelector('select')!;select.value=sword.id;select.dispatchEvent(new host.Event('change'));
 const apply=Array.from(root.querySelectorAll('button')).find(b=>b.textContent==='Użyj · 1 szt.')!;apply.click();await new Promise(r=>setTimeout(r,0));assert.deepEqual(sent,[{id:sword.id,revision:7}]);
 view.setState({...snapshot,pending:true});assert.ok(apply.disabled);const retry=Array.from(root.querySelectorAll('button')).find(b=>b.textContent==='Odzyskaj wynik')!;assert.equal(retry.hidden,false);retry.click();await new Promise(r=>setTimeout(r,0));assert.equal(sent.at(-1),'retry');
 view.dispose();manager.dispose();
});
