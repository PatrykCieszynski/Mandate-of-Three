import {WebBridge,reportInteractiveRegions} from '../bridge.js';
import {DomainStore} from '../store.js';
import {mountInventory} from './inventory-view.js';
const root=document.getElementById('inventory'),store=new DomainStore();
let regions;
const bridge=new WebBridge({onShortcut:()=>view.cancelOrClose(),onState(message){
  if(!store.apply(message))return;
  const state=store.state;root.hidden=!state.hud?.inventory_open;
  if(root.hidden)view.cancelCarry();
  if(state.inventory){if(['ui.snapshot','inventory.updated'].includes(message.type))view.setState(state);else view.setInfo(state);}
  regions?.refresh();
}});
const view=mountInventory(root,{moveItem:payload=>bridge.request('inventory.move_item',payload),onClose:()=>bridge.request('inventory.close',{}).catch(()=>{}),onRegionsChanged:()=>regions?.refresh()});
regions=reportInteractiveRegions(bridge,view.regions);
window.addEventListener('pagehide',()=>{view.dispose();regions.dispose();bridge.clearPending('reload');});
document.addEventListener('contextmenu',event=>event.preventDefault());bridge.ready();
