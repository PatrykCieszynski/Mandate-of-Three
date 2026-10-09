import {icon} from './icons.js';
// Presentation only. Committed snapshots own placement; command results never do.
export function mountInventory(root,{moveItem,equipItem=null,onClose=()=>{}}){
 root.innerHTML=`<section class="window equipment" aria-label="Equipment"><header><span class="crest">✦</span><h1>Equipment</h1></header><div class="equipment-body"><div class="silhouette" aria-hidden="true"><div class="head"></div><div class="torso"></div><div class="legs"></div></div><div class="equipment-slots"></div></div><footer><span class="character-name">Lynanel</span><span>Level 12 · Warrior</span></footer></section><section class="window backpack" aria-label="Inventory"><header><span class="crest">✦</span><h1>Inventory</h1><button class="close" aria-label="Close inventory">×</button></header><div class="category"><span class="active">Backpack</span><span class="capacity"></span></div><div class="inventory-grid" aria-label="Inventory grid"><div class="placement-preview"></div></div><div class="wallet"><span class="coin">◉</span><strong></strong><span>Yang</span></div><footer><span>Click to pick up · click to place</span><span>Backpack</span></footer></section><aside class="item-tooltip" hidden></aside><p class="inventory-status" role="status">Select an item to inspect it.</p>`;
 const grid=root.querySelector('.inventory-grid'),preview=root.querySelector('.placement-preview'),tooltip=root.querySelector('.item-tooltip');
 let state=null,drag=null,pending=false,selected=null;
 const ghost=document.createElement('div');ghost.className='carried-item';ghost.hidden=true;root.append(ghost);
 function cancelCarry(){if(drag)drag.node.classList.remove('dragging');drag=null;preview.hidden=true;ghost.hidden=true;}
 function follow(event){
  if(!drag)return;
  ghost.style.left=`${event.clientX-drag.offsetX}px`;
  ghost.style.top=`${event.clientY-drag.offsetY}px`;
  const r=grid.getBoundingClientRect();
  drag.x=Math.floor((event.clientX-r.left)/cell());
  drag.y=Math.floor((event.clientY-r.top)/cell())-drag.offset;
  const over=event.clientX>=r.left&&event.clientX<r.right&&event.clientY>=r.top&&event.clientY<r.bottom;
  preview.hidden=!over;
  preview.style.left=`${drag.x*cell()}px`;preview.style.top=`${drag.y*cell()}px`;
  preview.style.height=`${drag.item.height*cell()}px`;
  preview.classList.toggle('invalid',!allowed(drag.item,drag.x,drag.y));
 }
 async function click(event){
  if(event.button!==0||pending||root.hidden)return;
  if(event.target?.closest?.('.close'))return;
  if(!drag){
   const node=event.target?.closest?.('.inventory-item');if(!node||!grid.contains(node))return;
   const item=state.inventory.items.find(i=>i.id===node.dataset.id);inspect(item);
   const r=node.getBoundingClientRect();
   drag={item,node,x:item.x,y:item.y,offset:Math.floor((event.clientY-r.top)/cell()),offsetX:event.clientX-r.left,offsetY:event.clientY-r.top};
   ghost.innerHTML=node.innerHTML;ghost.style.width=`${r.width}px`;ghost.style.height=`${r.height}px`;ghost.hidden=false;node.classList.add('dragging');tooltip.hidden=true;
   root.querySelector('.inventory-status').textContent='Click a free cell to place · Escape to cancel.';follow(event);return;
  }
  follow(event);
  const r=grid.getBoundingClientRect();
  if(event.clientX<r.left||event.clientX>=r.right||event.clientY<r.top||event.clientY>=r.bottom||!allowed(drag.item,drag.x,drag.y)){
   root.querySelector('.inventory-status').textContent='Cannot place here. Choose free cells or press Escape.';return;
  }
  const command={id:drag.item.id,x:drag.x,y:drag.y,revision:drag.item.revision??state.inventory.revision};cancelCarry();pending=true;root.classList.add('pending');
  try{const result=await moveItem(command);root.querySelector('.inventory-status').textContent=result.ok?'Item moved.':`Placement rejected: ${result.error}.`;}
  catch{root.querySelector('.inventory-status').textContent='No response. Waiting for authoritative state.';}
  finally{pending=false;root.classList.remove('pending');}
 }
 function key(event){if(event.key==='Escape'&&drag){event.preventDefault();event.stopImmediatePropagation();cancelCarry();root.querySelector('.inventory-status').textContent='Move cancelled.';}}
 document.addEventListener('pointermove',follow);
 document.addEventListener('click',click);
 document.addEventListener('keydown',key);
 async function equipmentAction(event){
  const node=event.target?.closest?.('.inventory-item,.equip-slot');
  if(!equipItem||!node||!root.contains(node)||!node.dataset.id)return;
  event.preventDefault();if(drag||pending)return;
  const equipped=node.classList.contains('equip-slot');
  const item=(equipped?state.equipment.slots:state.inventory.items).find(i=>i.id===node.dataset.id);
  pending=true;root.classList.add('pending');
  try{const result=await equipItem({id:item.id,revision:item.revision,action:equipped?'unequip':'equip'});root.querySelector('.inventory-status').textContent=result.ok?'Equipment updated.':`Equipment rejected: ${result.error}.`;}
  catch{root.querySelector('.inventory-status').textContent='No response. Waiting for authoritative state.';}
  finally{pending=false;root.classList.remove('pending');}
 }
 root.addEventListener('contextmenu',equipmentAction);
 const cell=()=>parseFloat(getComputedStyle(grid).getPropertyValue('--cell'));
 const allowed=(item,x,y)=>x>=0&&x<state.inventory.columns&&y>=0&&y+item.height<=state.inventory.rows&&!state.inventory.items.some(o=>o.id!==item.id&&o.x===x&&y<o.y+o.height&&y+item.height>o.y);
 function inspect(item){selected=item.id;tooltip.hidden=false;tooltip.replaceChildren();const add=(tag,text,cls)=>{const n=document.createElement(tag);n.textContent=text;if(cls)n.className=cls;tooltip.append(n);};add('small',item.category??'ITEM','rarity');add('h2',item.name);add('p',item.description??'A useful companion on the road.');if(item.attack)add('p',`Attack ${item.attack}`,'stat');add('p',`Size 1 × ${item.height}`);add('small',equipItem?'Left click to move · right click to equip/unequip':'Click to pick up · click to place');root.querySelectorAll('.inventory-item').forEach(n=>n.classList.toggle('selected',n.dataset.id===selected));}
 function render(){cancelCarry();grid.querySelectorAll('.inventory-item,.cell').forEach(n=>n.remove());grid.style.setProperty('--columns',state.inventory.columns);grid.style.setProperty('--rows',state.inventory.rows);
 for(let y=0;y<state.inventory.rows;y++)for(let x=0;x<state.inventory.columns;x++){const n=document.createElement('div');n.className='cell';n.style.left=`${x*cell()}px`;n.style.top=`${y*cell()}px`;grid.append(n);}
 for(const item of state.inventory.items){const n=document.createElement('button');n.type='button';n.className='inventory-item';n.dataset.id=item.id;n.setAttribute('aria-label',item.name);n.innerHTML=icon(item.icon);if(item.quantity>1){const q=document.createElement('span');q.className='quantity';q.textContent=item.quantity;n.append(q);}n.style.left=`${item.x*cell()+2}px`;n.style.top=`${item.y*cell()+2}px`;n.style.height=`${item.height*cell()-4}px`;n.classList.toggle('selected',selected===item.id);
 n.addEventListener('focus',()=>{if(!drag)inspect(item);});n.addEventListener('pointerenter',()=>{if(!drag)inspect(item);});grid.append(n);}
 root.querySelector('.capacity').textContent=`${state.inventory.items.reduce((n,i)=>n+i.height,0)} / ${state.inventory.columns*state.inventory.rows}`;
 renderInfo();
 const slots=root.querySelector('.equipment-slots');slots.replaceChildren();for(const entry of state.equipment.slots){const n=document.createElement('div');n.className=`equip-slot ${entry.slot}`;n.innerHTML=entry.icon?icon(entry.icon):'';n.title=entry.label;if(entry.id){n.dataset.id=entry.id;n.tabIndex=0;n.setAttribute('role','button');n.setAttribute('aria-label',entry.label);n.addEventListener('pointerenter',()=>{if(!drag)inspect(entry);});}slots.append(n);}if(selected){const i=state.inventory.items.find(i=>i.id===selected);if(i)inspect(i);else tooltip.hidden=true;}
 }
 function renderInfo(){
 root.querySelector('.wallet strong').textContent=state.wallet.ready===false?'—':Number(state.wallet.balance).toLocaleString('en-US');
 root.querySelector('.character-name').textContent=state.player?.name??'Lynanel';
 root.querySelector('.equipment footer span:last-child').textContent=`Level ${state.player?.level??12} · Attack ${state.equipment.attack??'—'}`;
 }
 const observer=new ResizeObserver(()=>{if(state)render();});observer.observe(grid);
 root.querySelector('.close').onclick=()=>{cancelCarry();onClose();};
 return {cancelCarry,setInfo(snapshot){if(!state)return;state.wallet=snapshot.wallet;state.player=snapshot.player;state.equipment.attack=snapshot.equipment.attack;renderInfo();},setState(snapshot){state=structuredClone(snapshot);render();},dispose(){cancelCarry();observer.disconnect();document.removeEventListener('pointermove',follow);document.removeEventListener('click',click);document.removeEventListener('keydown',key);root.removeEventListener('contextmenu',equipmentAction);root.replaceChildren();}};
}
