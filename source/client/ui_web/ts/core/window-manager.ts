import type {WindowId, Point, Viewport, WindowRegistration, WindowHandle, LayoutInvalidation} from './window/window-types.js';
import {WindowLayout} from './window/window-layout.js';
export type {WindowPlacement, WindowRegistration, WindowHandle} from './window/window-types.js';
export type WindowHost = Pick<Window, 'innerWidth'|'innerHeight'|'addEventListener'|'removeEventListener'>;
interface WindowEntry {
  root: HTMLElement;
  layoutListeners: Set<(event: LayoutInvalidation) => void>;
  activationListeners: Set<() => void>;
}
// Registration, activation and layout invalidation; rendering belongs to UiWindow.
export class WindowManager {
  readonly windows = new Map<WindowId, WindowEntry>();
  viewport: Viewport = {width:0,height:0};
  scale = 1;
  activeWindowId: WindowId | null = null;
  private order: WindowId[] = [];
  private readonly layout = new WindowLayout(()=>this);
  private readonly host: WindowHost | null;
  private readonly resize: () => void;
  constructor({host=globalThis.window}: {host?: WindowHost | null}={}) {
    this.host=host;
    this.resize=()=>{if(host)this.setViewport({width:host.innerWidth,height:host.innerHeight});};
    host?.addEventListener('resize',this.resize);
  }
  register({id,element,root=element,placement}: WindowRegistration): WindowHandle {
    if(typeof id!=='string'||!id)throw new Error('Window registration requires a stable id');
    if(this.windows.has(id))throw new Error('Duplicate window: '+id);
    const entry: WindowEntry={root,layoutListeners:new Set(),activationListeners:new Set()};
    this.windows.set(id,entry);this.layout.register(id,element,placement);
    root.style.setProperty('--ui-scale',String(this.scale));this.order.push(id);this.restack();
    const current=()=>{if(this.windows.get(id)!==entry)throw new Error('Disposed window: '+id);};
    return {
      activate:()=>{current();this.activate(id);},place:()=>{current();return this.place(id);},
      move:(position: Point)=>{current();return this.move(id,position);},
      resetPosition:()=>{current();this.layout.resetPosition(id);this.refresh(id);},
      refresh:()=>{current();this.refresh(id);},
      onLayoutChanged:listener=>{current();entry.layoutListeners.add(listener);return ()=>{entry.layoutListeners.delete(listener);};},
      onActivate:listener=>{current();entry.activationListeners.add(listener);return ()=>{entry.activationListeners.delete(listener);};},
      dispose:()=>{if(this.windows.get(id)===entry)this.unregister(id);}
    };
  }
  unregister(id: WindowId) {
    const entry=this.windows.get(id);if(!entry)return;
    for(const listener of entry.layoutListeners)listener({cancelTransient:true});
    entry.layoutListeners.clear();entry.activationListeners.clear();this.windows.delete(id);this.layout.unregister(id);
    this.order=this.order.filter(key=>key!==id);if(this.activeWindowId===id)this.activeWindowId=null;
    this.syncActive();this.restack();
  }
  private restack() { this.order.forEach((id,index)=>{const entry=this.windows.get(id);if(entry)entry.root.style.zIndex=String(10+index);}); }
  activate(id: WindowId) {
    const entry=this.windows.get(id);if(!entry||entry.root.hidden||this.activeWindowId===id)return;
    this.order=this.order.filter(key=>key!==id);this.order.push(id);this.activeWindowId=id;this.restack();
    for(const listener of entry.activationListeners)listener();
  }
  private syncActive() {
    if(this.activeWindowId===null||this.windows.get(this.activeWindowId)?.root.hidden||!this.windows.has(this.activeWindowId)) {
      this.activeWindowId=null;
      const visible=[...this.order].reverse().find(id=>this.windows.get(id)?.root.hidden===false);
      if(visible)this.activate(visible);
    }
  }
  refresh(id: WindowId,cancelTransient=false) {
    const entry=this.windows.get(id);if(!entry)return;
    for(const listener of entry.layoutListeners)listener({cancelTransient:cancelTransient||entry.root.hidden});
    this.syncActive();
  }
  refreshAll(cancelTransient=false) { for(const id of this.windows.keys())this.refresh(id,cancelTransient); }
  setScale(scale: number) {
    if(!Number.isFinite(scale)||scale<=0)throw new Error('Invalid UI scale');
    if(scale===this.scale)return;
    this.scale=scale;for(const entry of this.windows.values())entry.root.style.setProperty('--ui-scale',String(scale));
    this.refreshAll(true);
  }
  setViewport(viewport: Viewport,scale=this.scale) {
    const changed=viewport.width!==this.viewport.width||viewport.height!==this.viewport.height;
    this.viewport={...viewport};
    if(scale!==this.scale)this.setScale(scale);else if(changed)this.refreshAll(true);
  }
  place(id: WindowId): Point { return this.layout.place(id); }
  move(id: WindowId,position: Point): Point { return this.layout.move(id,position); }
  dispose() { this.host?.removeEventListener('resize',this.resize);for(const id of [...this.windows.keys()])this.unregister(id); }
}
