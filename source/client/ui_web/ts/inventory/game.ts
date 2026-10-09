import type {ItemIconId} from '../game-ui/item-types.js';
import {element as findElement} from '../core/dom.js';
import {readDomainSnapshot} from '../protocol.js';
import {uiIcons} from '../core/assets/ui-icons.js';
import {ItemIconResolver} from '../content/item-icons.js';
import {applySkin} from '../core/assets/skin.js';
import {loadLegacySkin} from '../skins/legacy.js';
import {WindowManager} from '../core/window/window-manager.js';
import {WebBridge,reportInteractiveRegions} from '../bridge.js';
import {DomainStore} from '../store.js';
import {mountInventory} from '../screens/inventory/inventory-view.js';
import {mountEquipment} from '../screens/equipment/equipment-view.js';
const legacy=await loadLegacySkin();
await applySkin(document.documentElement,legacy.skin);
uiIcons.replace(legacy.uiIcons,new URL('./',import.meta.url));
const itemIcons=new ItemIconResolver(legacy.itemIcons);
const resolveItemIcon=(id: ItemIconId)=>itemIcons.resolve(id);
const manager=new WindowManager();
manager.setViewport({width:innerWidth,height:innerHeight},1);
const root=findElement(document,'#inventory','main'),equipmentRoot=findElement(document,'#equipment','main'),store=new DomainStore();
let regions: ReturnType<typeof reportInteractiveRegions> | undefined;
const bridge=new WebBridge({onShortcut:()=>{
  if(!root.hidden)view.cancelOrClose();else if(!equipmentRoot.hidden)equipment.close();
},onState(message){
  if(!store.apply(message))return;
  const state=readDomainSnapshot(store.state);if(!state)return;root.hidden=!state.hud?.inventory_open;equipmentRoot.hidden=!state.hud?.equipment_open;
  manager.setViewport({width:innerWidth,height:innerHeight},manager.scale);
  if(root.hidden)view.cancelCarry();
  if(state.inventory){if(['ui.snapshot','inventory.updated'].includes(message.type))view.setState({...state,inventory:state.inventory});else view.setInfo(state);}
  equipment.setState(state);
  manager.refreshAll();
  regions?.refresh();
}});
const view=mountInventory(root,{manager,resolveItemIcon,equipItem:payload=>bridge.request('equipment.equip',payload),moveItem:payload=>bridge.request('inventory.move_item',payload),onClose:()=>bridge.request('inventory.close',{}).catch(()=>{}),onRegionsChanged:()=>regions?.refresh()});
const equipment=mountEquipment(equipmentRoot,{manager,resolveItemIcon,unequipItem:payload=>bridge.request('equipment.unequip',payload),onClose:()=>bridge.request('equipment.close',{}).catch(()=>{}),onRegionsChanged:()=>regions?.refresh()});
regions=reportInteractiveRegions(bridge,[...view.regions,...equipment.regions]);
window.addEventListener('pagehide',()=>{view.dispose();equipment.dispose();regions?.dispose();bridge.clearPending('reload');manager.dispose();});
document.addEventListener('contextmenu',event=>event.preventDefault());bridge.ready();
