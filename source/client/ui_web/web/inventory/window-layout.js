import {clampWindow} from './placement.js';
// Geometry is measured in logical pixels; viewport dimensions are physical pixels.
export class WindowLayout {
  constructor(){this.windows=new Map();this.viewport={width:0,height:0};this.scale=1;}
  register({id,element,preferredAnchor='right',defaultOffset={x:0,y:0},relativeTo=null,relativeOffset={x:0,y:0}}){
    if(this.windows.has(id))throw new Error('Duplicate window: '+id);
    this.windows.set(id,{element,preferredAnchor,defaultOffset,relativeTo,relativeOffset,position:null,manual:false,size:null});
  }
  unregister(id){this.windows.delete(id);}
  setViewport(viewport,scale){this.viewport=viewport;this.scale=scale;}
  measure(entry){
    if(entry.element.getClientRects().length)entry.size={width:entry.element.offsetWidth,height:entry.element.offsetHeight};
    return entry.size;
  }
  place(id,visiting=new Set()){
    const entry=this.windows.get(id);if(!entry)throw new Error('Unknown window: '+id);
    if(visiting.has(id))throw new Error('Cyclic window placement: '+id);
    visiting.add(id);
    const size=this.measure(entry)||{width:0,height:0};
    let position=entry.position;
    if(!entry.manual){
      position={x:(entry.preferredAnchor==='right'?this.viewport.width/this.scale-size.width:0)+entry.defaultOffset.x,y:entry.defaultOffset.y};
      const relative=this.windows.get(entry.relativeTo);
      if(relative&&this.measure(relative)){
        const anchor=this.place(entry.relativeTo,visiting);
        position={x:anchor.x-size.width+entry.relativeOffset.x,y:anchor.y+entry.relativeOffset.y};
      }
    }
    entry.position=clampWindow(position,size,this.viewport,this.scale);
    visiting.delete(id);return {...entry.position};
  }
  move(id,position){
    const entry=this.windows.get(id);entry.manual=true;
    entry.position=clampWindow(position,this.measure(entry)||{width:0,height:0},this.viewport,this.scale);
    return {...entry.position};
  }
}
