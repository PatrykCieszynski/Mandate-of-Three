// Composed shell only. The screen supplies content, placement and actions.
export class UiWindow {
  constructor(root,{window_id,title,className='',content='',manager,placement={},onClose=()=>{},canDrag=()=>true,onCancel=()=>{},onRegionsChanged=()=>{},onGeometry=()=>{},onActivate=()=>{},scrollBorder=0,hideHorizontalOverflow=false}={}) {
    if(!manager||!window_id)throw new Error('UiWindow requires manager and stable window_id');
    this.root=root;this.id=window_id;this.manager=manager;this.drag=null;this.frame=0;this.disposed=false;this.listeners=[];
    root.innerHTML=`<section class="window-chrome ${className}">
      <i class="chrome edge top"></i><i class="chrome edge bottom"></i><i class="chrome edge left"></i><i class="chrome edge right"></i>
      <i class="chrome corner tl"></i><i class="chrome corner tr"></i><i class="chrome corner bl"></i><i class="chrome corner br"></i>
      <header class="window-header"><h1></h1><button type="button" class="window-close">×</button></header>${content}</section>`;
    this.panel=root.querySelector('section');this.panel.id=window_id+'-window';this.panel.setAttribute('aria-label',title);
    this.panel.style.left='0px';this.panel.style.top='0px';root.style.setProperty('--ui-scale',manager.scale);
    const header=root.querySelector('.window-header'),close=root.querySelector('.window-close');
    header.querySelector('h1').textContent=title;close.setAttribute('aria-label','Close '+title.toLowerCase());
    this.paint=position=>{this.position=position;this.panel.style.transform=`translate3d(${position.x}px,${position.y}px,0)`;onGeometry();onRegionsChanged();};
    this.cancel=()=>{this.stopDrag();onCancel();};
    manager.register({window_id,element:this.panel,root,...placement,onActivate,cancel:this.cancel,paint:this.paint,prepare:()=>{
      const height=manager.viewport.height/this.scale;this.panel.style.maxHeight=height+'px';
      const small=this.panel.scrollHeight+scrollBorder>height;this.panel.style.overflowY=small?'auto':'visible';
      if(hideHorizontalOverflow)this.panel.style.overflowX=small?'hidden':'visible';
    }});
    this.listen(this.panel,'pointerdown',()=>manager.activate(window_id));
    this.listen(this.panel,'focusin',()=>manager.activate(window_id));
    this.listen(close,'click',()=>{this.cancel();onClose();});
    this.listen(header,'pointerdown',event=>{
      if(event.button!==0||event.target.closest('button')||!canDrag()||!this.position)return;
      event.preventDefault();const p=this.point(event);this.panel.style.willChange='transform';
      this.drag={node:header,pointer:event.pointerId,offset:{x:p.x-this.position.x,y:p.y-this.position.y}};
      header.setPointerCapture(event.pointerId);
    });
    this.listen(header,'lostpointercapture',event=>{if(this.drag?.pointer===event.pointerId)this.stopDrag();});
    this.listen(document,'pointermove',event=>{
      if(!this.drag||event.pointerId!==this.drag.pointer)return;
      if(!header.hasPointerCapture(this.drag.pointer)){this.stopDrag();return;}
      const p=this.point(event);this.position=manager.move(window_id,{x:p.x-this.drag.offset.x,y:p.y-this.drag.offset.y});
      if(!this.frame)this.frame=requestAnimationFrame(()=>{this.frame=0;if(!this.disposed)this.paint(this.position);});
    });
    this.listen(document,'pointerup',event=>{if(this.drag?.pointer===event.pointerId)this.stopDrag();});
    this.listen(document,'pointercancel',this.cancel);this.listen(window,'blur',this.cancel);
  }
  get scale(){return this.manager.scale;}
  point(event){return {x:event.clientX/this.scale,y:event.clientY/this.scale};}
  listen(target,type,callback){target.addEventListener(type,callback);this.listeners.push(()=>target.removeEventListener(type,callback));}
  stopDrag(){
    if(this.frame){cancelAnimationFrame(this.frame);this.frame=0;this.paint(this.position);}
    this.panel.style.willChange='auto';const old=this.drag;this.drag=null;
    if(old?.node.hasPointerCapture(old.pointer))old.node.releasePointerCapture(old.pointer);
  }
  refresh(){this.manager.refresh(this.id);}
  dispose(){if(this.disposed)return;this.disposed=true;this.cancel();this.listeners.forEach(remove=>remove());this.listeners=[];this.manager.unregister(this.id);}
}
