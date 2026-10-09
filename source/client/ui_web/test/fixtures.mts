import {JSDOM} from 'jsdom';
import {WindowManager} from '../web/core/window-manager.js';
import type {InventoryItem, EquipmentItem} from '../web/contracts.js';
export const bagItem: InventoryItem={id:'bag-item',revision:3,name:'Sword',icon_id:'iron_sword',x:0,y:0,page:0,height:3,quantity:2,description:'Example'};
export const equippedItem: EquipmentItem={id:'equipped-item',revision:4,name:'Equipped sword',icon_id:'iron_sword',slot:'weapon',height:3,quantity:1};
export function environment(){
  const dom=new JSDOM('<!doctype html><html><body></body></html>',{pretendToBeVisual:true});
  const host=dom.window,doc=host.document,frames=new Map<number, FrameRequestCallback>();let sequence=0;
  Object.assign(globalThis,{window:host,document:doc,Element:host.Element,HTMLButtonElement:host.HTMLButtonElement,
    requestAnimationFrame:(fn: FrameRequestCallback)=>{frames.set(++sequence,fn);return sequence;},
    cancelAnimationFrame:(id: number)=>{frames.delete(id);}});
  const manager=new WindowManager({host});manager.setViewport({width:host.innerWidth,height:host.innerHeight},1);
  return {dom,host,doc,manager,frames};
}
export function measure(element: HTMLElement,width=240,height=400){
  Object.defineProperties(element,{
    offsetWidth:{configurable:true,get:()=>width},offsetHeight:{configurable:true,get:()=>height},scrollHeight:{configurable:true,get:()=>height},
    getClientRects:{configurable:true,value:()=>element.hidden?[]:[element.getBoundingClientRect()]}
  });
  return {resize(w: number,h=height){width=w;height=h;}};
}
export function target(){const element=document.createElement('div');measure(element);return element;}
export function capture(element: HTMLElement){
  const captured=new Set<number>();
  element.setPointerCapture=id=>{captured.add(id);};element.hasPointerCapture=id=>captured.has(id);
  element.releasePointerCapture=id=>{captured.delete(id);fire(element,'lostpointercapture',0,0,id);};
}
export function fire(element: EventTarget,type: string,x=100,y=100,id=1){
  const event=document.createEvent('MouseEvent');event.initMouseEvent(type,true,true,window,0,0,0,x,y,false,false,false,false,0,null);
  Object.defineProperty(event,'pointerId',{value:id});element.dispatchEvent(event);
}
export class TestResizeObserver implements ResizeObserver {
  static disconnected=false;
  observe(){} unobserve(){} disconnect(){TestResizeObserver.disconnected=true;}
}
