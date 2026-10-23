import test from 'node:test';
import assert from 'node:assert/strict';
import { environment, target } from './fixtures.mjs';
import { mountStats } from '../web/screens/stats/stats-view.js';
import { isStats, type StatsSnapshot } from '../web/screens/stats/stats-model.js';
import { DomainStore } from '../web/store.js';
const fixture = (): StatsSnapshot => ({opened:true,ready:true,busy:false,pending:false,pending_attribute:'',error:'',vitals:{hp:90,mp:40},data:{attributes:{STR:'9007199254740993',DEX:'2',VIT:'3',INT:'4'},level:'2',experience:'35',xp_to_next:'140',xp_fraction:0.25,available_points:'1',available_skill_points:'1',revision:'1',combat:{health_max:135,mana_max:70,attack:12,armor:0.75,mana_regen:0.7,attack_speed:100.2}}});
test('stats validates exact decimal counters and rejects malformed updates atomically',()=>{
  const value=fixture();assert.ok(isStats(value));const store=new DomainStore();
  assert.ok(store.apply({v:1,type:'stats.updated',payload:{...value}}));
  for(const bad of [{...value,ready:true,data:undefined},{...value,data:{...value.data,available_points:-1}},{...value,data:{...value.data,combat:{attack:NaN}}},{...value,data:{...value.data,attributes:{STR:'9223372036854775808'}}}]) {
    assert.equal(isStats(bad),false);assert.equal(store.apply({v:1,type:'stats.updated',payload:bad}),false);
  }
  assert.equal((store.state.stats?.data as unknown as StatsSnapshot['data'])?.attributes.STR,'9007199254740993');
});
test('stats sends only one-point intent, awaits authoritative state and offers pending retry',async()=>{
  const {manager}=environment(), root=target();let resolve!: (v:{ok:boolean})=>void;const sent:string[]=[];
  const view=mountStats(root,{manager,spend:attribute=>{sent.push(attribute);return new Promise(r=>{resolve=r;});},retry:async()=>{sent.push('retry');return {ok:true};},refresh:async()=>({ok:true}),close:()=>{sent.push('close');},regions:()=>{}});
  const state=fixture();view.setState(state);
  const plus=root.querySelector<HTMLButtonElement>('[aria-label="Increase STR"]')!;
  assert.ok(root.textContent?.includes('9007199254740993'));
  plus.click();plus.click();assert.deepEqual(sent,['STR']);assert.ok(plus.disabled);
  assert.equal(root.querySelector('[data-stat=available_points]')?.textContent,'1','no optimistic spend');
  resolve({ok:true});await new Promise(r=>setTimeout(r,0));assert.equal(root.querySelector('[data-stat=available_points]')?.textContent,'1','ack alone is not new state');
  view.setState({...state,pending:true,pending_attribute:'STR',error:'timeout'});
  assert.ok(plus.disabled);const retry=Array.from(root.querySelectorAll('button')).find(b=>b.textContent==='Retry allocation')!;assert.equal(retry.hidden,false);retry.click();await new Promise(r=>setTimeout(r,0));assert.deepEqual(sent,['STR','retry']);
  view.setState({...state,data:{...state.data!,available_points:'0'}});assert.ok(plus.disabled);
  assert.ok(view.closeIfActive());assert.equal(sent.at(-1),'close');view.dispose();manager.dispose();
});
