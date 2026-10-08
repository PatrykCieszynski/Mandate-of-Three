"use strict";
const grid=document.getElementById("grid"),preview=document.getElementById("preview");
let authoritative=null,drag=null,pending=false,lastRevision=-1;
const send=(type,payload={})=>window.sendIpcMessage(JSON.stringify({type,payload}));
const cell=()=>parseFloat(getComputedStyle(grid).getPropertyValue("--cell"));
function valid(item,x,y){return x>=0&&x<authoritative.columns&&y>=0&&y+item.height<=authoritative.rows&&!authoritative.items.some(other=>other.id!==item.id&&other.x===x&&y<other.y+other.height&&y+item.height>other.y);}
function report(data){send("spike.report",data);}
function render(){
 drag=null;pending=false;preview.style.display="none";
 grid.querySelectorAll(".item").forEach(n=>n.remove());
 for(const item of authoritative.items){
  const node=document.createElement("div");node.className="item";node.dataset.id=item.id;
  node.textContent=item.name;node.style.left=`${item.x*cell()+2}px`;node.style.top=`${item.y*cell()+2}px`;node.style.height=`${item.height*cell()-4}px`;
  node.addEventListener("pointerdown",event=>{if(pending||event.button!==0)return;event.preventDefault();report({kind:"pointer",event:"down",id:item.id});node.setPointerCapture(event.pointerId);drag={item,node,x:item.x,y:item.y,offset:Math.floor((event.clientY-node.getBoundingClientRect().top)/cell())};node.classList.add("dragging");});
  node.addEventListener("pointermove",event=>{if(!drag||drag.node!==node)return;const rect=grid.getBoundingClientRect();drag.x=Math.floor((event.clientX-rect.left)/cell());drag.y=Math.floor((event.clientY-rect.top)/cell())-drag.offset;preview.style.display="block";preview.style.left=`${drag.x*cell()}px`;preview.style.top=`${drag.y*cell()}px`;preview.style.height=`${item.height*cell()}px`;const allowed=valid(item,drag.x,drag.y);preview.classList.toggle("invalid",!allowed);report({kind:"preview",valid:allowed,x:drag.x,y:drag.y});});
  node.addEventListener("pointerup",event=>{if(!drag||drag.node!==node)return;report({kind:"pointer",event:"up",id:item.id});const move={id:item.id,x:drag.x,y:drag.y,revision:authoritative.revision};drag=null;preview.style.display="none";pending=true;node.className="item pending";node.style.left=`${move.x*cell()+2}px`;node.style.top=`${move.y*cell()+2}px`;send("inventory.move_item",move);});
  node.addEventListener("pointercancel",()=>{report({kind:"pointer",event:"cancel",id:item.id});render();});grid.appendChild(node);
 }
}
window.ipcMessage.addListener(message=>{
 const envelope=JSON.parse(message);
 if(!["state.snapshot","state.update"].includes(envelope.type))return;
 authoritative=envelope.payload;window.spikeState=structuredClone(authoritative);
 document.getElementById("version").textContent=`Revision ${authoritative.revision}`;
 document.getElementById("ticks").textContent=`Godot tick ${authoritative.ticks}`;
 if(envelope.type==="state.snapshot"||authoritative.revision!==lastRevision||Object.keys(envelope.result).length){render();lastRevision=authoritative.revision;}
 if(Object.keys(envelope.result).length)document.getElementById("result").textContent=envelope.result.ok?"Godot accepted placement.":`Godot rejected: ${envelope.result.error}. Authoritative placement restored.`;
 report({kind:"state",revision:authoritative.revision,ticks:authoritative.ticks,width:innerWidth,height:innerHeight});
});
document.getElementById("invalid").onclick=()=>{pending=true;send("inventory.move_item",{id:"spear",x:0,y:6,revision:authoritative.revision});};
document.getElementById("ready").onclick=()=>send("UI_READY");
document.getElementById("focus-test").addEventListener("input",event=>report({kind:"input",value:event.target.value}));
document.addEventListener("keydown",event=>report({kind:"key",key:event.key}));
window.addEventListener("resize",()=>{if(authoritative&&!drag&&!pending)render();});
document.addEventListener("click",event=>{if(event.target.closest("a"))event.preventDefault();});
window.open=()=>null;
send("UI_READY");
