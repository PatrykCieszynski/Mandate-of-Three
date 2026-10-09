import {placement,clampWindow} from './placement.js';
import {icons} from './skin.js';
export function mountInventory(root,{moveItem,onClose=()=>{},onRegionsChanged=()=>{}}={}) {
  root.innerHTML=`<section id="inventory-window" class="window window-chrome" aria-label="Inventory">
    <i class="chrome edge top"></i><i class="chrome edge bottom"></i><i class="chrome edge left"></i><i class="chrome edge right"></i>
    <i class="chrome corner tl"></i><i class="chrome corner tr"></i><i class="chrome corner bl"></i><i class="chrome corner br"></i>
    <header class="window-header"><h1>Inventory</h1><button class="window-close" aria-label="Close inventory">×</button></header>
    <nav class="inventory-tabs" aria-label="Inventory pages">${['I','II','III','IV'].map((label,page)=>`<button role="tab" data-page="${page}">${label}</button>`).join('')}</nav>
    <div class="inventory-grid"></div><footer class="wallet"><span class="yang-icon">●</span><span>Yang</span><strong>—</strong></footer>
    <p class="inventory-status" role="status"></p></section><div id="carry-surface" hidden></div>
    <div class="carried-item" hidden></div><aside class="item-tooltip" hidden><h2></h2><p></p></aside>`;
  const panel=root.querySelector('.window'),grid=root.querySelector('.inventory-grid'),surface=root.querySelector('#carry-surface'),
    ghost=root.querySelector('.carried-item'),tooltip=root.querySelector('.item-tooltip'),status=root.querySelector('.inventory-status');
  let inventory={columns:5,rows:9,pages:4,items:[]},scale=1,page=0,position=null,dragged=false,carry=null,windowDrag=null,windowFrame=0,windowSize=null,pending=false,disposed=false;
  const viewport=()=>({width:innerWidth,height:innerHeight});
  const point=e=>({x:e.clientX/scale,y:e.clientY/scale});
  const cell=()=>parseFloat(getComputedStyle(grid).getPropertyValue('--slot-size'));
  const size=()=>({width:panel.offsetWidth,height:panel.offsetHeight});
  panel.style.left='0px';panel.style.top='0px';
  function paintWindow() {
    panel.style.transform=`translate3d(${position.x}px,${position.y}px,0)`;onRegionsChanged();
  }
  function flushWindowMove() {
    if(windowFrame){cancelAnimationFrame(windowFrame);windowFrame=0;paintWindow();}
  }
  function positionWindow() {
    // display:none has no measurable geometry; clamp on reopening instead.
    if(root.hidden)return;
    flushWindowMove();
    // Only the unusually small viewport fallback scrolls; core geometry stays fixed.
    panel.style.maxHeight=innerHeight/scale+"px";
    const small=panel.scrollHeight+2>innerHeight/scale;
    panel.style.overflowY=small?"auto":"visible";panel.style.overflowX=small?"hidden":"visible";
    windowSize=size();
    if(!position||!dragged)position={x:innerWidth/scale-windowSize.width-16,y:240};
    position=clampWindow(position,windowSize,viewport(),scale);
    paintWindow();
    surface.style.width=innerWidth/scale+'px';surface.style.height=innerHeight/scale+'px';onRegionsChanged();
  }
  function icon(node,item) {
    node.replaceChildren();
    if(icons[item.icon]) {const img=document.createElement('img');img.src=icons[item.icon];img.alt='';img.className='item-icon';node.append(img);}
    else {const label=document.createElement('span');label.className='icon-fallback';label.textContent=item.name;node.append(label);}
    if(item.quantity>1){const qty=document.createElement('span');qty.className='quantity';qty.textContent=item.quantity;node.append(qty);}
  }
  function render() {
    grid.replaceChildren();
    for(let y=0;y<inventory.rows;y++)for(let x=0;x<inventory.columns;x++) {
      const slot=document.createElement('div');slot.className='cell';slot.style.left=x*cell()+'px';slot.style.top=y*cell()+'px';grid.append(slot);
    }
    for(const item of inventory.items.filter(i=>i.page===page)) {
      const node=document.createElement('div');node.className='inventory-item';node.dataset.id=item.id;node.dataset.height=item.height;
      node.style.left=item.x*cell()+1+'px';node.style.top=item.y*cell()+1+'px';node.style.height=item.height*cell()-2+'px';
      node.setAttribute('aria-label',item.name);icon(node,item);
      node.addEventListener('pointerdown',event=>beginCarry(event,item,node));
      node.addEventListener('pointermove',event=>{if(!carry&&!pending)showTooltip(event,item);});
      node.addEventListener('pointerleave',()=>tooltip.hidden=true);grid.append(node);
    }
    root.querySelectorAll('[data-page]').forEach(tab=>tab.setAttribute('aria-selected',String(Number(tab.dataset.page)===page)));positionWindow();
  }
  function showTooltip(event,item) {
    tooltip.querySelector('h2').textContent=item.name;tooltip.querySelector('p').textContent=item.description||'';tooltip.hidden=false;
    const p=point(event),width=tooltip.offsetWidth,height=tooltip.offsetHeight;
    const x=p.x+14+width>innerWidth/scale?p.x-width-14:p.x+14;
    tooltip.style.left=Math.max(0,Math.min(x,innerWidth/scale-width))+'px';tooltip.style.top=Math.max(0,Math.min(p.y+14,innerHeight/scale-height))+'px';
  }
  function releaseCapture(state) {if(state?.node?.hasPointerCapture(state.pointer))state.node.releasePointerCapture(state.pointer);}
  function cancelCarry() {
    const old=carry;carry=null;releaseCapture(old);ghost.hidden=true;surface.hidden=true;tooltip.hidden=true;
    grid.querySelector('.placement-preview')?.remove();grid.querySelectorAll('.carried').forEach(n=>n.classList.remove('carried'));onRegionsChanged();
  }
  function beginCarry(event,item,node) {
    if(event.button!==0||pending||carry)return;event.preventDefault();tooltip.hidden=true;
    const rect=node.getBoundingClientRect(),p=point(event);
    carry={item,node,pointer:event.pointerId,start:p,offset:{x:(event.clientX-rect.left)/scale,y:(event.clientY-rect.top)/scale},moved:false,latched:false};
    node.setPointerCapture(event.pointerId);node.classList.add('carried');icon(ghost,item);ghost.style.height=item.height*cell()-2+'px';ghost.hidden=false;updateCarry(event);
  }
  function updateCarry(event) {
    if(!carry)return;const p=point(event);
    if(Math.hypot(p.x-carry.start.x,p.y-carry.start.y)>3)carry.moved=true;
    ghost.style.left=p.x-carry.offset.x+'px';ghost.style.top=p.y-carry.offset.y+'px';
    const rect=grid.getBoundingClientRect(),x=Math.floor((event.clientX-rect.left)/scale/cell()),y=Math.floor((event.clientY-rect.top)/scale/cell());
    carry.preview=placement(inventory,carry.item,x,y,page);
    let preview=grid.querySelector('.placement-preview');if(!preview){preview=document.createElement('div');grid.append(preview);}
    preview.className='placement-preview'+(carry.preview.valid?'':' invalid');preview.style.left=x*cell()+'px';preview.style.top=y*cell()+'px';preview.style.height=carry.item.height*cell()+'px';
  }
  async function submit() {
    if(!carry||pending)return;const {item,preview}=carry;
    const command={id:item.id,revision:item.revision,x:preview.x,y:preview.y,page:preview.page};
    cancelCarry();pending=true;status.textContent='Moving…';
    try {const result=await moveItem(command);if(!disposed)status.textContent=result.ok?'':`Move rejected: ${result.error||'request'}`;}
    catch(error){if(!disposed)status.textContent=`Move failed: ${error.message}`;}finally {pending=false;}
  }
  function pointerDown(event) {if(carry?.latched&&event.button===0){event.preventDefault();updateCarry(event);if(carry.preview.valid)submit();}}
  function pointerMove(event) {
    if(windowDrag&&event.pointerId===windowDrag.pointer){
      if(!windowDrag.node.hasPointerCapture(windowDrag.pointer))windowDrag=null;
      else {dragged=true;const p=point(event);
        position=clampWindow({x:p.x-windowDrag.offset.x,y:p.y-windowDrag.offset.y},windowSize,viewport(),scale);
        if(!windowFrame)windowFrame=requestAnimationFrame(()=>{windowFrame=0;if(!disposed)paintWindow();});
      }
    }
    if(carry)updateCarry(event);
  }
  function pointerUp(event) {
    if(windowDrag&&event.pointerId===windowDrag.pointer){flushWindowMove();panel.style.willChange='auto';const old=windowDrag;windowDrag=null;releaseCapture(old);}
    if(!carry||carry.latched||event.pointerId!==carry.pointer)return;updateCarry(event);
    if(carry.moved){submit();return;}carry.latched=true;releaseCapture(carry);surface.hidden=false;onRegionsChanged();
  }
  function cancelOrClose(){if(carry)cancelCarry();else onClose();}
  function keyDown(event) {
    if(root.hidden||event.repeat)return;
    if(event.key==='Escape'||event.key.toLowerCase()==='i'){event.preventDefault();if(event.key==='Escape')cancelOrClose();else {cancelCarry();onClose();}}
  }
  function cancelled(){flushWindowMove();panel.style.willChange='auto';cancelCarry();if(windowDrag){const old=windowDrag;windowDrag=null;releaseCapture(old);}}
  root.querySelector('.window-close').addEventListener('click',()=>{cancelCarry();onClose();});
  root.querySelectorAll('[data-page]').forEach(tab=>tab.addEventListener('click',()=>{if(!carry?.latched)cancelCarry();page=Number(tab.dataset.page);render();}));
  root.querySelector('.window-header').addEventListener('pointerdown',event=>{
    if(event.button!==0||event.target.closest('button')||carry)return;event.preventDefault();const p=point(event);
    panel.style.willChange='transform';windowDrag={node:event.currentTarget,pointer:event.pointerId,offset:{x:p.x-position.x,y:p.y-position.y}};event.currentTarget.setPointerCapture(event.pointerId);
  });
  const resize=()=>{cancelled();positionWindow();};
  document.addEventListener('pointerdown',pointerDown);document.addEventListener('pointermove',pointerMove);document.addEventListener('pointerup',pointerUp);
  document.addEventListener('pointercancel',cancelled);document.addEventListener('keydown',keyDown);window.addEventListener('resize',resize);window.addEventListener('blur',cancelled);
  root.addEventListener('lostpointercapture',event=>{
    if(carry&&!carry.latched&&carry.pointer===event.pointerId)cancelCarry();
    if(windowDrag?.pointer===event.pointerId){flushWindowMove();panel.style.willChange='auto';windowDrag=null;}
  });render();
  return {regions:[panel,surface],cancelCarry,cancelOrClose,
    setState(snapshot){cancelCarry();inventory=structuredClone(snapshot.inventory);render();this.setInfo(snapshot);},
    setInfo(snapshot){root.querySelector('.wallet strong').textContent=Number(snapshot.wallet?.balance||0).toLocaleString('en-US');
      const next=Number(snapshot.hud?.ui_scale||scale);if(next!==scale){cancelled();scale=next;root.style.setProperty('--ui-scale',scale);}
      // Opening and Godot viewport snapshots also clamp; native resize events may lag.
      positionWindow();},
    dispose(){disposed=true;cancelled();document.removeEventListener('pointerdown',pointerDown);document.removeEventListener('pointermove',pointerMove);document.removeEventListener('pointerup',pointerUp);document.removeEventListener('pointercancel',cancelled);document.removeEventListener('keydown',keyDown);window.removeEventListener('resize',resize);window.removeEventListener('blur',cancelled);}
  };
}
