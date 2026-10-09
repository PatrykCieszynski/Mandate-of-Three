import {UiTab} from '../core/ui-tab.js';
import {UiSlot} from '../core/ui-slot.js';
import {UiTooltip} from '../core/ui-tooltip.js';
import {UiCurrency} from '../core/ui-currency.js';
import {UiWindow} from '../core/ui-window.js';
import {placement,carriedCell} from './placement.js';
import {icons} from './skin.js';
export function mountInventory(root,{manager,moveItem,equipItem,onClose=()=>{},onRegionsChanged=()=>{}}={}) {
  const shell=new UiWindow(root,{window_id:'inventory',title:'Inventory',className:'window',manager,
    placement:{preferredAnchor:'right',defaultOffset:{x:-16,y:240}},scrollBorder:2,hideHorizontalOverflow:true,
    onClose,canDrag:()=>!carry,onCancel:()=>cancelCarry(),onRegionsChanged,onGeometry:()=>{
      surface.style.width=innerWidth/shell.scale+'px';surface.style.height=innerHeight/shell.scale+'px';
    },content:`<nav class="inventory-tabs" aria-label="Inventory pages"></nav>
    <div class="inventory-grid"></div><footer class="wallet"><span class="yang-icon">●</span><span>Yang</span><strong>—</strong></footer>
    <p class="inventory-status" role="status"></p>`});
  root.insertAdjacentHTML('beforeend',`<div id="carry-surface" hidden></div><div class="carried-item" hidden></div>`);
  const panel=root.querySelector('.window'),grid=root.querySelector('.inventory-grid'),surface=root.querySelector('#carry-surface'),
    ghost=root.querySelector('.carried-item'),status=root.querySelector('.inventory-status');
  const tip=UiTooltip(root,{geometry:()=>manager}),tooltip=tip.element,currency=UiCurrency(root.querySelector('.wallet'));
  const tabs=['I','II','III','IV'].map((label,index)=>{
    const tab=UiTab({label,onSelect:()=>{if(!carry?.latched)cancelCarry();page=index;render();}});
    root.querySelector('.inventory-tabs').append(tab.element);return tab;
  });
  let inventory={columns:5,rows:9,pages:4,items:[]},page=0,carry=null,pending=false,disposed=false;
  const point=e=>shell.point(e);
  const cell=()=>parseFloat(getComputedStyle(grid).getPropertyValue('--slot-size'));
  const positionWindow=()=>shell.refresh();
  function icon(node,item) {
    node.replaceChildren();
    if(icons[item.icon]) {const img=document.createElement('img');img.src=icons[item.icon];img.alt='';img.className='item-icon';node.append(img);}
    else {const label=document.createElement('span');label.className='icon-fallback';label.textContent=item.name;node.append(label);}
    if(item.quantity>1){const qty=document.createElement('span');qty.className='quantity';qty.textContent=item.quantity;node.append(qty);}
  }
  function render() {
    grid.replaceChildren();
    for(let y=0;y<inventory.rows;y++)for(let x=0;x<inventory.columns;x++) {
      const slot=UiSlot({className:'cell'});slot.style.left=x*cell()+'px';slot.style.top=y*cell()+'px';grid.append(slot);
    }
    for(const item of inventory.items.filter(i=>i.page===page)) {
      const node=document.createElement('div');node.className='inventory-item';node.dataset.id=item.id;node.dataset.height=item.height;
      node.style.left=item.x*cell()+1+'px';node.style.top=item.y*cell()+1+'px';node.style.height=item.height*cell()-2+'px';
      node.setAttribute('aria-label',item.name);icon(node,item);
      node.addEventListener('pointerdown',event=>{
        if(event.button===2&&equipItem&&!carry&&!pending){event.preventDefault();equip(item);}
        else beginCarry(event,item,node);
      });
      node.addEventListener('pointermove',event=>{if(!carry&&!pending)showTooltip(event,item);});
      node.addEventListener('pointerleave',()=>tooltip.hidden=true);grid.append(node);
    }
    tabs.forEach((tab,index)=>tab.setSelected(index===page));positionWindow();
  }
  function showTooltip(event,item) {
    tip.show(event,item);
  }
  function releaseCapture(state) {if(state?.node?.hasPointerCapture(state.pointer))state.node.releasePointerCapture(state.pointer);}
  function cancelCarry() {
    const old=carry;carry=null;releaseCapture(old);ghost.hidden=true;surface.hidden=true;tooltip.hidden=true;
    grid.querySelector('.placement-preview')?.remove();grid.querySelectorAll('.carried').forEach(n=>n.classList.remove('carried'));onRegionsChanged();
  }
  function beginCarry(event,item,node) {
    if(event.button!==0||pending||carry)return;event.preventDefault();tooltip.hidden=true;
    const rect=node.getBoundingClientRect(),p=point(event);
    carry={item,node,pointer:event.pointerId,start:p,offset:{x:(event.clientX-rect.left)/shell.scale,y:(event.clientY-rect.top)/shell.scale},moved:false,latched:false};
    node.setPointerCapture(event.pointerId);node.classList.add('carried');icon(ghost,item);ghost.style.height=item.height*cell()-2+'px';ghost.hidden=false;updateCarry(event);
  }
  function updateCarry(event) {
    if(!carry)return;const p=point(event);
    if(Math.hypot(p.x-carry.start.x,p.y-carry.start.y)>3)carry.moved=true;
    ghost.style.left=p.x-carry.offset.x+'px';ghost.style.top=p.y-carry.offset.y+'px';
    const rect=grid.getBoundingClientRect(),{x,y}=carriedCell({x:(event.clientX-rect.left)/shell.scale,y:(event.clientY-rect.top)/shell.scale},carry.offset,cell());
    carry.preview=placement(inventory,carry.item,x,y,page);
    let preview=grid.querySelector('.placement-preview');if(!preview){preview=document.createElement('div');grid.append(preview);}
    preview.className='placement-preview'+(carry.preview.valid?'':' invalid');preview.style.left=x*cell()+'px';preview.style.top=y*cell()+'px';preview.style.height=carry.item.height*cell()+'px';
  }
  async function equip(item) {
    pending=true;tooltip.hidden=true;status.textContent='Equipping…';
    try {const result=await equipItem({id:item.id,revision:item.revision});if(!disposed)status.textContent=result.ok?'':`Equip rejected: ${result.error||'request'}`;}
    catch(error){if(!disposed)status.textContent=`Equip failed: ${error.message}`;}finally {pending=false;}
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
    if(carry)updateCarry(event);
  }
  function pointerUp(event) {
    if(!carry||carry.latched||event.pointerId!==carry.pointer)return;updateCarry(event);
    if(carry.moved){submit();return;}carry.latched=true;releaseCapture(carry);surface.hidden=false;onRegionsChanged();
  }
  function cancelOrClose(){if(carry)cancelCarry();else onClose();}
  function keyDown(event) {
    if(root.hidden||event.repeat)return;
    if(event.key==='Escape'||event.key.toLowerCase()==='i'){event.preventDefault();if(event.key==='Escape')cancelOrClose();else {cancelCarry();onClose();}}
  }
  shell.listen(document,'pointerdown',pointerDown);shell.listen(document,'pointermove',pointerMove);shell.listen(document,'pointerup',pointerUp);
  shell.listen(document,'keydown',keyDown);
  shell.listen(root,'lostpointercapture',event=>{
    if(carry&&!carry.latched&&carry.pointer===event.pointerId)cancelCarry();
  });render();
  return {regions:[panel,surface],cancelCarry,cancelOrClose,
    setState(snapshot){cancelCarry();inventory=structuredClone(snapshot.inventory);render();this.setInfo(snapshot);},
    setInfo(snapshot){currency.setValue(snapshot.wallet?.balance);
      manager.setScale(Number(snapshot.hud?.ui_scale||shell.scale));
      // Opening and Godot viewport snapshots also clamp; native resize events may lag.
      positionWindow();},
    dispose(){disposed=true;shell.dispose();tabs.forEach(tab=>tab.dispose());tip.dispose();}
  };
}
