import {mountInventory} from '../../source/client/ui_web/web/inventory/inventory-view.js';
import {placement} from '../../source/client/ui_web/web/inventory/placement.js';
const state={inventory:{columns:5,rows:9,pages:4,items:[
{id:'potion',revision:0,name:'Red Potion',icon:'potion',quantity:15,height:1,x:0,y:0,page:0,description:'Mock consumable.'},
{id:'short',revision:0,name:'Short Sword +0',icon:'short_sword',height:2,x:1,y:0,page:0,description:'Mock 1 × 2 item.'},
{id:'sword',revision:0,name:'Iron Sword +0',icon:'iron_sword',height:3,x:2,y:0,page:0,description:'Mock 1 × 3 item.'},
{id:'other',revision:0,name:'Iron Sword +1',icon:'iron_sword',height:3,x:0,y:0,page:1,description:'Second page.'}
]},wallet:{balance:100090},hud:{ui_scale:Number(new URLSearchParams(location.search).get('scale')||1)}};
const root=document.getElementById('inventory'),reopen=document.getElementById('reopen');
const view=mountInventory(root,{onClose(){root.hidden=true;reopen.hidden=false;},async moveItem(move){
 const item=state.inventory.items.find(i=>i.id===move.id);
 const valid=item&&item.revision===move.revision&&placement(state.inventory,item,move.x,move.y,move.page).valid;
 if(valid){Object.assign(item,{x:move.x,y:move.y,page:move.page,revision:item.revision+1});}
 view.setState(state);return valid?{ok:true}:{ok:false,error:'placement'};
}});
view.setState(state);reopen.onclick=()=>{root.hidden=false;reopen.hidden=true;view.setInfo(state);};
