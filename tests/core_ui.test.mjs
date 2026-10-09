import test from 'node:test';
import assert from 'node:assert/strict';
import {WindowManager} from '../source/client/ui_web/web/core/window-manager.js';
import {UiWindow} from '../source/client/ui_web/web/core/ui-window.js';
function target(extra={}) {
  const listeners=new Map(),captures=new Set();
  return {style:{setProperty(key,value){this[key]=value;}},hidden:false,offsetWidth:240,offsetHeight:400,scrollHeight:400,
    getClientRects(){return this.hidden?[]:[{}];},setAttribute(){},
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
 const title=target(),header=target({querySelector:()=>title}),close=target(),panel=target();
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
