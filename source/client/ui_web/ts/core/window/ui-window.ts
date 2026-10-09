import type {WindowId, Point, WindowPlacement, WindowHandle} from './window-types.js';
import type {WindowManager} from './window-manager.js';
import {UiTitlebar} from '../primitives/ui-titlebar.js';
import {WindowDragController} from './window-drag.js';
import {createWindowShell} from './window-shell.js';
export interface UiWindowOptions {
  id: WindowId; title: string; manager: WindowManager;
  className?: string; placement?: WindowPlacement;
  onClose?: () => void; canDrag?: () => boolean; onCancel?: () => void; onRegionsChanged?: () => void;
  onGeometry?: () => void; onActivate?: () => void; scrollBorder?: number; hideHorizontalOverflow?: boolean;
}
// Shell composition. The screen supplies content, placement and actions.
export class UiWindow {
  readonly id: WindowId;
  readonly panel: HTMLElement;
  readonly contentRoot: HTMLElement;
  readonly handle: WindowHandle;
  private readonly dragController: WindowDragController;
  private readonly removals: (() => void)[] = [];
  private disposed = false;
  private position: Point | undefined;
  readonly cancel: () => void;
  constructor(readonly root: HTMLElement,private options: UiWindowOptions) {
    const {id,title,manager,className='',onClose=()=>{},canDrag=()=>true,onCancel=()=>{},onRegionsChanged=()=>{},onGeometry=()=>{},onActivate=()=>{},scrollBorder=0,hideHorizontalOverflow=false}=options;
    if(!manager||typeof id!=='string'||!id)throw new Error('UiWindow requires manager and stable id');
    this.id=id;
    const shell=createWindowShell(root,{id,title,className});this.panel=shell.panel;this.contentRoot=shell.content;
    this.handle=manager.register({id,root,element:this.panel,...(options.placement?{placement:options.placement}:{})});
    const paint=(position: Point)=>{
      this.position=position;this.panel.style.transform=`translate3d(${position.x}px,${position.y}px,0)`;
      onGeometry();onRegionsChanged();
    };
    this.dragController=new WindowDragController({handle:shell.header,getPosition:()=>this.position,
      toLogicalPoint:event=>this.point(event),onMove:position=>this.handle.move(position),paint,canStart:canDrag,
      onActiveChanged:active=>{this.panel.style.willChange=active?'transform':'auto';}});
    this.cancel=()=>{this.dragController.stop();onCancel();};
    const titlebar=UiTitlebar(shell.header,{title,onClose:()=>{this.cancel();onClose();}});
    this.removals.push(()=>titlebar.dispose(),this.handle.onActivate(onActivate));
    this.removals.push(this.handle.onLayoutChanged(({cancelTransient})=>{
      if(cancelTransient)this.cancel();
      if(root.hidden||this.disposed)return;
      const height=manager.viewport.height/this.scale;this.panel.style.maxHeight=height+'px';
      const small=this.panel.scrollHeight+scrollBorder>height;this.panel.style.overflowY=small?'auto':'visible';
      if(hideHorizontalOverflow)this.panel.style.overflowX=small?'hidden':'visible';
      paint(this.handle.place());
    }));
    this.listen(this.panel,'pointerdown',()=>this.handle.activate());
    this.listen(this.panel,'focusin',()=>this.handle.activate());
    // Screen transients (including Inventory carry) also cancel outside window drag.
    this.listen(document,'pointercancel',this.cancel);this.listen(window,'blur',this.cancel);
  }
  get scale() { return this.options.manager.scale; }
  get drag() { return this.dragController.active; }
  point(event: Pick<MouseEvent,'clientX'|'clientY'>): Point { return {x:event.clientX/this.scale,y:event.clientY/this.scale}; }
  listen<K extends keyof GlobalEventHandlersEventMap>(target: {
    addEventListener(type: NoInfer<K>,callback: (event: GlobalEventHandlersEventMap[NoInfer<K>]) => void): void;
    removeEventListener(type: NoInfer<K>,callback: (event: GlobalEventHandlersEventMap[NoInfer<K>]) => void): void;
  },type: K,callback: (event: GlobalEventHandlersEventMap[K]) => void) {
    target.addEventListener(type,callback);this.removals.push(()=>target.removeEventListener(type,callback));
  }
  refresh() { if(!this.disposed)this.handle.refresh(); }
  dispose() {
    if(this.disposed)return;this.disposed=true;this.cancel();this.dragController.dispose();
    for(const remove of this.removals)remove();this.removals.length=0;
    this.handle.dispose();this.root.replaceChildren();this.options.onRegionsChanged?.();
  }
}
