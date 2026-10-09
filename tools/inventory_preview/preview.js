import {mountInventory} from '../../source/client/ui_web/web/inventory/inventory-view.js';
import {mountEquipment} from '../../source/client/ui_web/web/inventory/equipment-view.js';
import {placement} from '../../source/client/ui_web/web/inventory/placement.js';
const state={inventory:{columns:5,rows:9,pages:4,items:[
{id:'potion',revision:0,name:'Red Potion',icon:'potion',quantity:15,height:1,x:0,y:0,page:0,description:'Mock consumable.'},
{id:'short',revision:0,name:'Short Sword +0',icon:'short_sword',height:2,x:1,y:0,page:0,description:'Mock 1 × 2 item.'},
{id:'sword',revision:0,name:'Iron Sword +0',icon:'iron_sword',height:2,x:2,y:0,page:0,description:'Mock one-handed sword · 1 × 2.'},
{id:'other',revision:0,name:'Iron Sword +1',icon:'iron_sword',height:2,x:0,y:0,page:1,description:'Second page.'}
]},equipment:{items:[],stats:{attack:10}},wallet:{balance:100090},hud:{ui_scale:Number(new URLSearchParams(location.search).get('scale')||1)}};
const root=document.getElementById('inventory'),reopen=document.getElementById('reopen');
const view=mountInventory(root,{async equipItem(payload){
 const item=state.inventory.items.find(i=>i.id===payload.id);if(!item)return {ok:false,error:'item'};
 if(state.equipment.items.length)return {ok:false,error:'mock_slot_occupied'};
 state.inventory.items=state.inventory.items.filter(i=>i!==item);item.slot='weapon';item.revision++;
 state.equipment.items=[item];state.equipment.stats.attack=20;refresh();return {ok:true};
},onClose(){root.hidden=true;reopen.hidden=false;},async moveItem(move){
 const item=state.inventory.items.find(i=>i.id===move.id);
 const valid=item&&item.revision===move.revision&&placement(state.inventory,item,move.x,move.y,move.page).valid;
 if(valid){Object.assign(item,{x:move.x,y:move.y,page:move.page,revision:item.revision+1});}
 view.setState(state);return valid?{ok:true}:{ok:false,error:'placement'};
}});
const equipment=mountEquipment(document.getElementById('equipment'),{onClose(){document.getElementById('equipment').hidden=true;},async unequipItem(payload){
 const item=state.equipment.items.find(i=>i.id===payload.id);if(!item)return {ok:false,error:'item'};
 for(let y=0;y<state.inventory.rows;y++)for(let x=0;x<state.inventory.columns;x++)if(placement(state.inventory,item,x,y,0).valid){
  Object.assign(item,{x,y,page:0,revision:item.revision+1});state.inventory.items.push(item);state.equipment.items=[];state.equipment.stats.attack=10;refresh();return {ok:true};
 }
 return {ok:false,error:'bag_full'};
}});
function refresh(){view.setState(state);equipment.setState(state);}
refresh();reopen.onclick=()=>{root.hidden=false;reopen.hidden=true;view.setInfo(state);};
