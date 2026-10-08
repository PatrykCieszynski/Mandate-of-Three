import {mountInventory} from '../../source/client/ui_web/web/inventory/inventory-view.js';
const state={inventory:{columns:6,rows:7,revision:1,items:[
{id:'potion',name:'Red Potion',icon:'potion',quantity:120,height:1,x:0,y:0,category:'CONSUMABLE',description:'Restores health. Sample item.'},
{id:'mana',name:'Blue Potion',icon:'mana',quantity:85,height:1,x:1,y:0,category:'CONSUMABLE'},
{id:'blade',name:'Bronze Sword +0',icon:'blade',height:2,x:2,y:1,category:'UNCOMMON · WEAPON',attack:'18–24',description:'A balanced blade forged for the road ahead.'},
{id:'spear',name:'Iron Spear +0',icon:'spear',height:3,x:4,y:2,category:'WEAPON',attack:'22–30'},
{id:'helm',name:'Iron Helmet +0',icon:'helm',height:1,x:0,y:3,category:'ARMOR'},
{id:'material',name:'Jade Fragment',icon:'material',height:1,x:1,y:4,quantity:6,category:'MATERIAL'},
{id:'scroll',name:'Ancient Scroll',icon:'scroll',height:1,x:3,y:0,quantity:2,category:'MATERIAL'}]},wallet:{balance:100090},equipment:{slots:[{slot:'helmet',icon:'helm',label:'Helmet'},{slot:'weapon',icon:'blade',label:'Weapon'},{slot:'armor',icon:'armor',label:'Armor'},{slot:'necklace',icon:'ring',label:'Necklace'},{slot:'ring',icon:'ring',label:'Ring'},{slot:'boots',icon:'boots',label:'Boots'},{slot:'gloves',label:'Gloves'},{slot:'belt',label:'Belt'}]}};
const root=document.getElementById('inventory'),reopen=document.getElementById('reopen');
const view=mountInventory(root,{onClose(){root.hidden=true;reopen.hidden=false;},async moveItem(move){const item=state.inventory.items.find(i=>i.id===move.id);let error='';if(move.revision!==state.inventory.revision)error='stale revision';else if(!item||move.x<0||move.x>=state.inventory.columns||move.y<0||move.y+item.height>state.inventory.rows)error='outside backpack';else if(state.inventory.items.some(o=>o.id!==item.id&&o.x===move.x&&move.y<o.y+o.height&&move.y+item.height>o.y))error='occupied cells';if(!error){item.x=move.x;item.y=move.y;state.inventory.revision++;}view.setState(state);return error?{ok:false,error}:{ok:true};}});
view.setState(state);reopen.onclick=()=>{root.hidden=false;reopen.hidden=true;};document.addEventListener('keydown',e=>{if(e.key==='Escape'){root.hidden=true;reopen.hidden=false;}else if(e.key.toLowerCase()==='i'){view.cancelCarry();root.hidden=!root.hidden;reopen.hidden=!root.hidden;}});
