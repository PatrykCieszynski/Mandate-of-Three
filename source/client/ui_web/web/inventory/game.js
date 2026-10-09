import {WindowLayout} from './window-layout.js';
import {WebBridge,reportInteractiveRegions} from '../bridge.js';
import {DomainStore} from '../store.js';
import {mountInventory} from './inventory-view.js';
import {mountEquipment} from './equipment-view.js';
const layout=new WindowLayout();
const root=document.getElementById('inventory'),equipmentRoot=document.getElementById('equipment'),store=new DomainStore();
let regions;
const bridge=new WebBridge({onShortcut:()=>{
  if(!root.hidden)view.cancelOrClose();else if(!equipmentRoot.hidden)equipment.close();
},onState(message){
  if(!store.apply(message))return;
  const state=store.state;root.hidden=!state.hud?.inventory_open;equipmentRoot.hidden=!state.hud?.equipment_open;
  if(root.hidden)view.cancelCarry();
  if(state.inventory){if(['ui.snapshot','inventory.updated'].includes(message.type))view.setState(state);else view.setInfo(state);}
  equipment.setState(state);
  regions?.refresh();
}});
const view=mountInventory(root,{layout,equipItem:payload=>bridge.request('equipment.equip',payload),moveItem:payload=>bridge.request('inventory.move_item',payload),onClose:()=>bridge.request('inventory.close',{}).catch(()=>{}),onRegionsChanged:()=>regions?.refresh()});
const equipment=mountEquipment(equipmentRoot,{layout,unequipItem:payload=>bridge.request('equipment.unequip',payload),onClose:()=>bridge.request('equipment.close',{}).catch(()=>{}),onRegionsChanged:()=>regions?.refresh()});
regions=reportInteractiveRegions(bridge,[...view.regions,...equipment.regions]);
window.addEventListener('pagehide',()=>{view.dispose();equipment.dispose();regions.dispose();bridge.clearPending('reload');});
document.addEventListener('contextmenu',event=>event.preventDefault());bridge.ready();
