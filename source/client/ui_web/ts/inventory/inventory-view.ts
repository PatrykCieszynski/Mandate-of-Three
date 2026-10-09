import type {DomainSnapshot, InventorySnapshot, InventoryItem, MoveItemCommand, ItemCommand, CommandResult} from '../protocol/contracts.js';
import type {Point} from '../core/window/window-types.js';
import type {ResolveItemIcon} from '../game-ui/item-types.js';
import type {WindowManager} from '../core/window/window-manager.js';
import type {Placement} from './placement.js';
import {element as findElement} from '../core/dom.js';
import {errorMessage} from '../protocol.js';
interface InventoryOptions {
  manager: WindowManager; resolveItemIcon?: ResolveItemIcon;
  moveItem: (command: MoveItemCommand) => Promise<CommandResult>;
  equipItem?: (command: ItemCommand) => Promise<CommandResult>;
  onClose?: () => void; onRegionsChanged?: () => void;
}
interface Carry {
  item: InventoryItem; node: HTMLElement; pointer: number; start: Point; offset: Point;
  moved: boolean; latched: boolean; preview?: Placement;
}
import {UiTab} from '../core/primitives/ui-tab.js';
import {UiInventoryGrid} from '../game-ui/ui-inventory-grid.js';
import {UiItemSlot} from '../game-ui/ui-item-slot.js';
import {paintItemIcon} from '../game-ui/item-icon.js';
import {ItemTooltip} from '../game-ui/items/item-tooltip.js';
import {UiCurrency} from '../core/primitives/ui-currency.js';
import {UiWindow} from '../core/window/ui-window.js';
import {placement,carriedCell} from './placement.js';
export function mountInventory(root: HTMLElement,{manager,resolveItemIcon=()=>null,moveItem,equipItem,onClose=()=>{},onRegionsChanged=()=>{}}: InventoryOptions) {
  const shell=new UiWindow(root,{id:'inventory',title:'Inventory',className:'window',manager,
    placement:{kind:'viewport',anchor:'top-right',offset:{x:-16,y:240}},scrollBorder:2,hideHorizontalOverflow:true,
    onClose,canDrag:()=>!carry,onCancel:()=>cancelCarry(),onRegionsChanged,onGeometry:()=>{
      surface.style.width=innerWidth/shell.scale+'px';surface.style.height=innerHeight/shell.scale+'px';
    }});
  shell.contentRoot.innerHTML=`<nav class="inventory-tabs" aria-label="Inventory pages"></nav>
    <div class="inventory-grid"></div><footer class="wallet"></footer>
    <p class="inventory-status" role="status"></p>`;
  root.insertAdjacentHTML('beforeend',`<div id="carry-surface" hidden></div><div class="carried-item" hidden></div>`);
  const panel=findElement(root,'.window','section'),grid=findElement(root,'.inventory-grid','div'),surface=findElement(root,'#carry-surface','div'),
    ghost=findElement(root,'.carried-item','div'),status=findElement(root,'.inventory-status','p');
  const tip=ItemTooltip(root,{geometry:()=>manager}),tooltip=tip.element,currency=UiCurrency(findElement(root,'.wallet','footer'),{label:'Yang',iconId:'currencies.yang'});
  const tabs=['I','II','III','IV'].map((label,index)=>{
    const tab=UiTab({label,onSelect:()=>{if(!carry?.latched)cancelCarry();page=index;render();}});
    findElement(root,'.inventory-tabs','nav').append(tab.element);return tab;
  });
  let inventory: InventorySnapshot={columns:5,rows:9,pages:4,items:[]},page=0,pending=false,disposed=false;
  let carry: Carry | null=null;
  const point=(e: PointerEvent)=>shell.point(e);
  const cell=()=>parseFloat(getComputedStyle(grid).getPropertyValue('--slot-size'));
  const positionWindow=()=>shell.refresh();
  const gridView=UiInventoryGrid(grid,{slotSize:cell});
  const icon=(node: HTMLElement,item: InventoryItem)=>paintItemIcon(node,item,{resolveItemIcon});
  function render() {
    gridView.render(inventory,page,item=>{
      const node=UiItemSlot({item,slotSize:cell(),resolveItemIcon});
      node.addEventListener('pointerdown',event=>{
        if(event.button===2&&equipItem&&!carry&&!pending){event.preventDefault();equip(item);}
        else beginCarry(event,item,node);
      });
      node.addEventListener('pointermove',event=>{if(!carry&&!pending)showTooltip(event,item);});
      node.addEventListener('pointerleave',()=>tooltip.hidden=true);return node;
    });
    tabs.forEach((tab,index)=>tab.setSelected(index===page));positionWindow();
  }
  function showTooltip(event: PointerEvent,item: InventoryItem) {
    tip.show(event,item);
  }
  function releaseCapture(state: Carry | null) {if(state?.node?.hasPointerCapture(state.pointer))state.node.releasePointerCapture(state.pointer);}
  function cancelCarry() {
    const old=carry;carry=null;releaseCapture(old);ghost.hidden=true;surface.hidden=true;tooltip.hidden=true;
    grid.querySelector<HTMLDivElement>('.placement-preview')?.remove();grid.querySelectorAll('.carried').forEach(n=>n.classList.remove('carried'));onRegionsChanged();
  }
  function beginCarry(event: PointerEvent,item: InventoryItem,node: HTMLElement) {
    if(event.button!==0||pending||carry)return;event.preventDefault();tooltip.hidden=true;
    const rect=node.getBoundingClientRect(),p=point(event);
    carry={item,node,pointer:event.pointerId,start:p,offset:{x:(event.clientX-rect.left)/shell.scale,y:(event.clientY-rect.top)/shell.scale},moved:false,latched:false};
    node.setPointerCapture(event.pointerId);node.classList.add('carried');icon(ghost,item);ghost.style.height=item.height*cell()-2+'px';ghost.hidden=false;updateCarry(event);
  }
  function updateCarry(event: PointerEvent) {
    if(!carry)return;const p=point(event);
    if(Math.hypot(p.x-carry.start.x,p.y-carry.start.y)>3)carry.moved=true;
    ghost.style.left=p.x-carry.offset.x+'px';ghost.style.top=p.y-carry.offset.y+'px';
    const rect=grid.getBoundingClientRect(),{x,y}=carriedCell({x:(event.clientX-rect.left)/shell.scale,y:(event.clientY-rect.top)/shell.scale},carry.offset,cell());
    carry.preview=placement(inventory,carry.item,x,y,page);
    let preview=grid.querySelector<HTMLDivElement>('.placement-preview');if(!preview){preview=document.createElement('div');grid.append(preview);}
    preview.className='placement-preview'+(carry.preview.valid?'':' invalid');preview.style.left=x*cell()+'px';preview.style.top=y*cell()+'px';preview.style.height=carry.item.height*cell()+'px';
  }
  async function equip(item: InventoryItem) {
    if(!equipItem)return;
    pending=true;tooltip.hidden=true;status.textContent='Equipping…';
    try {const result=await equipItem({id:item.id,revision:item.revision});if(!disposed)status.textContent=result.ok?'':`Equip rejected: ${result.error||'request'}`;}
    catch(error){if(!disposed)status.textContent=`Equip failed: ${errorMessage(error)}`;}finally {pending=false;}
  }
  async function submit() {
    if(!carry||pending||!carry.preview)return;const {item,preview}=carry;
    const command={id:item.id,revision:item.revision,x:preview.x,y:preview.y,page:preview.page};
    cancelCarry();pending=true;status.textContent='Moving…';
    try {const result=await moveItem(command);if(!disposed)status.textContent=result.ok?'':`Move rejected: ${result.error||'request'}`;}
    catch(error){if(!disposed)status.textContent=`Move failed: ${errorMessage(error)}`;}finally {pending=false;}
  }
  function pointerDown(event: PointerEvent) {if(carry?.latched&&event.button===0){event.preventDefault();updateCarry(event);if(carry.preview?.valid)submit();}}
  function pointerMove(event: PointerEvent) {
    if(carry)updateCarry(event);
  }
  function pointerUp(event: PointerEvent) {
    if(!carry||carry.latched||event.pointerId!==carry.pointer)return;updateCarry(event);
    if(carry.moved){submit();return;}carry.latched=true;releaseCapture(carry);surface.hidden=false;onRegionsChanged();
  }
  function cancelOrClose(){if(carry)cancelCarry();else onClose();}
  function keyDown(event: KeyboardEvent) {
    if(root.hidden||event.repeat)return;
    if(event.key==='Escape'||event.key.toLowerCase()==='i'){event.preventDefault();if(event.key==='Escape')cancelOrClose();else {cancelCarry();onClose();}}
  }
  shell.listen(document,'pointerdown',pointerDown);shell.listen(document,'pointermove',pointerMove);shell.listen(document,'pointerup',pointerUp);
  shell.listen(document,'keydown',keyDown);
  shell.listen(root,'lostpointercapture',event=>{
    if(carry&&!carry.latched&&carry.pointer===event.pointerId)cancelCarry();
  });render();
  return {regions:[panel,surface],cancelCarry,cancelOrClose,
    setState(snapshot: DomainSnapshot & {inventory: InventorySnapshot}){cancelCarry();inventory=structuredClone(snapshot.inventory);render();this.setInfo(snapshot);},
    setInfo(snapshot: DomainSnapshot){currency.setValue(snapshot.wallet?.balance);
      manager.setScale(Number(snapshot.hud?.ui_scale||shell.scale));
      // Opening and Godot viewport snapshots also clamp; native resize events may lag.
      positionWindow();},
    dispose(){disposed=true;shell.dispose();tabs.forEach(tab=>tab.dispose());tip.dispose();currency.dispose();gridView.dispose();}
  };
}
