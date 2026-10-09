import type {DomainSnapshot, EquipmentItem, ItemCommand, CommandResult} from '../protocol/contracts.js';
import type {ResolveItemIcon} from '../game-ui/item-types.js';
import type {WindowManager} from '../core/window/window-manager.js';
import {element as findElement} from '../core/dom.js';
import {errorMessage} from '../protocol.js';
interface EquipmentOptions {
  manager: WindowManager; resolveItemIcon?: ResolveItemIcon;
  unequipItem: (command: ItemCommand) => Promise<CommandResult>;
  onClose?: () => void; onRegionsChanged?: () => void;
}
import {UiEquipmentSlot} from '../game-ui/ui-equipment-slot.js';
import {ItemTooltip} from '../game-ui/items/item-tooltip.js';
import {UiWindow} from '../core/window/ui-window.js';
// Logical slot rectangles match the native 156×188 legacy reference skin.
const slots: [slot: string,label: string,x: number,y: number,height: number][]=[
  ['weapon','Weapon',4,4,64],['head','Helmet',42,6,32],['neck','Necklace',118,2,32],
  ['armor','Armor',42,42,64],['earrings','Earrings',118,40,32],['bracelet','Bracelet',80,76,32],
  ['shield','Shield',4,74,32],['feet','Shoes',42,112,32],['belt','Belt',4,116,32],['charm','Charm',80,116,32],
  ['ring','Ring',118,112,32],
  ['special1','Special slot I',4,154,32],['special2','Special slot II',42,154,32],
  ['special3','Special slot III',80,154,32],['special4','Special slot IV',118,154,32]
];
export function mountEquipment(root: HTMLElement,{manager,resolveItemIcon=()=>null,unequipItem,onClose=()=>{},onRegionsChanged=()=>{}}: EquipmentOptions) {
  const shell=new UiWindow(root,{id:'equipment',title:'Equipment',className:'equipment-window',manager,
    placement:{kind:'relative',target:'inventory',side:'left',align:'start',gap:12,fallback:{kind:'viewport',anchor:'top-right',offset:{x:-16,y:240}}},onClose,onRegionsChanged,
    onCancel:()=>{tooltip.hidden=true;}});
  shell.contentRoot.innerHTML=`<div class="equipment-body"><div class="equipment-silhouette" aria-hidden="true">♟</div></div>
    <p class="equipment-stats"></p><p class="equipment-hint">Right-click bag items to equip.<br>Click weapon to unequip.</p>
    <p class="inventory-status" role="status"></p>`;
  const panel=findElement(root,'.equipment-window','section'),body=findElement(root,'.equipment-body','div'),status=findElement(root,'[role=status]','p');
  const tip=ItemTooltip(root,{geometry:()=>manager}),tooltip=tip.element;
  let pending=false,disposed=false;
  let items: EquipmentItem[]=[];
  const buttons=new Map<string, ReturnType<typeof UiEquipmentSlot>>();
  for(const [slot,label,x,y,height] of slots){
    const tile=UiEquipmentSlot({slot,label,x,y,height,resolveItemIcon,title:slot==='weapon'?label:label+' · not available yet'}),button=tile.element;
    shell.listen(button,'pointermove',event=>showTooltip(event,slot));
    shell.listen(button,'pointerleave',()=>tooltip.hidden=true);
    shell.listen(button,'click',async()=>{
      const item=items.find(item=>item.slot===slot);if(!item||pending)return;
      pending=true;tooltip.hidden=true;render();status.textContent='Unequipping…';
      try {const result=await unequipItem({id:item.id,revision:item.revision});if(!disposed)status.textContent=result.ok?'':`Unequip rejected: ${result.error||'request'}`;}
      catch(error){if(!disposed)status.textContent=`Unequip failed: ${errorMessage(error)}`;}
      finally {pending=false;if(!disposed)render();}
    });
    buttons.set(slot,tile);body.append(button);
  }
  function showTooltip(event: PointerEvent,slot: string){
    const item=items.find(item=>item.slot===slot);if(!item||pending||shell.drag)return;
    tip.show(event,item);
  }
  function render(){
    for(const [slot,tile] of buttons){
      const item=items.find(item=>item.slot===slot);tile.setItem(item,{enabled:slot==='weapon'&&!!item&&!pending});
    }
  }

  return {regions:[panel],close:onClose,setState(state: DomainSnapshot){
    manager.setScale(Number(state.hud?.ui_scale||shell.scale));
    tooltip.hidden=true;items=state.equipment?.items||[];render();findElement(root,'.equipment-stats','p').textContent='Attack '+Number(state.equipment?.stats?.attack||0);shell.refresh();
  },dispose(){disposed=true;shell.dispose();tip.dispose();}};
}
