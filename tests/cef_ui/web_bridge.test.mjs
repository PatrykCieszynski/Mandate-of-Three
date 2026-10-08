import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const base = new URL('../../source/client/ui_web/web/', import.meta.url);
const protocolUrl = 'data:text/javascript;base64,' + Buffer.from(await readFile(new URL('protocol.js',base),'utf8')).toString('base64');
const protocol = await import(protocolUrl);
const bridgeCode = (await readFile(new URL('bridge.js',base),'utf8')).replace("'./protocol.js'",JSON.stringify(protocolUrl));
const {WebBridge} = await import('data:text/javascript;base64,'+Buffer.from(bridgeCode).toString('base64'));
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
