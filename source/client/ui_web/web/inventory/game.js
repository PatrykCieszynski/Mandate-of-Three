import {WebBridge,reportInteractiveRegions} from '../bridge.js';
import {DomainStore} from '../store.js';
import {mountInventory} from './inventory-view.js';
const root=document.getElementById('inventory'),store=new DomainStore();
const bridge=new WebBridge({onState(message){
 if(!store.apply(message))return;
 const s=store.state;
 root.hidden=!s.hud?.inventory_open;
 if(root.hidden)view.cancelCarry();
 if(s.inventory&&s.equipment&&s.wallet){
  if(['ui.snapshot','inventory.updated','equipment.updated'].includes(message.type))view.setState(s);
  else view.setInfo(s);
 }
 regions.refresh();
}});
const close=()=>bridge.request('inventory.close',{}).catch(()=>{});
const view=mountInventory(root,{moveItem:p=>bridge.request('inventory.move_item',p),equipItem:p=>bridge.request('inventory.equipment',p),onClose:close});
const regions=reportInteractiveRegions(bridge,[...root.querySelectorAll('.window')]);
document.addEventListener('keydown',event=>{
 if(root.hidden||event.repeat)return;
 if(event.key==='Escape'||event.key.toLowerCase()==='i'){event.preventDefault();view.cancelCarry();close();}
});
window.addEventListener('pagehide',()=>{view.dispose();regions.dispose();bridge.clearPending('reload');});
document.addEventListener('contextmenu',event=>event.preventDefault());
bridge.ready();
