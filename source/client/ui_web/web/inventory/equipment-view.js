import {UiWindow} from '../core/ui-window.js';
import {icons} from './skin.js';
// Logical slot rectangles match the native 156×188 legacy reference skin.
const slots=[
  ['weapon','Weapon',4,4,64],['head','Helmet',42,6,32],['neck','Necklace',118,2,32],
  ['armor','Armor',42,42,64],['earrings','Earrings',118,40,32],['bracelet','Bracelet',80,76,32],
  ['shield','Shield',4,74,32],['feet','Shoes',42,112,32],['belt','Belt',4,116,32],['charm','Charm',80,116,32],
  ['ring','Ring',118,112,32],
  ['special1','Special slot I',4,154,32],['special2','Special slot II',42,154,32],
  ['special3','Special slot III',80,154,32],['special4','Special slot IV',118,154,32]
];
export function mountEquipment(root,{manager,unequipItem,onClose=()=>{},onRegionsChanged=()=>{}}={}) {
  const shell=new UiWindow(root,{window_id:'equipment',title:'Equipment',className:'equipment-window',manager,
    placement:{preferredAnchor:'right',defaultOffset:{x:-16,y:240},relativeTo:'inventory',relativeOffset:{x:-12,y:0}},onClose,onRegionsChanged,
    onCancel:()=>{tooltip.hidden=true;},content:`<div class="equipment-body"><div class="equipment-silhouette" aria-hidden="true">♟</div></div>
    <p class="equipment-stats"></p><p class="equipment-hint">Right-click bag items to equip.<br>Click weapon to unequip.</p>
    <p class="inventory-status" role="status"></p>`});
  root.insertAdjacentHTML('beforeend',`<aside class="item-tooltip" hidden><h2></h2><p></p></aside>`);
  const panel=root.querySelector('.equipment-window'),body=root.querySelector('.equipment-body'),status=root.querySelector('[role=status]'),tooltip=root.querySelector('.item-tooltip');
  let pending=false,items=[],disposed=false;
  const buttons=new Map();
  for(const [slot,label,x,y,height] of slots){
    const button=document.createElement('button');button.type='button';button.className='equipment-slot';button.dataset.slot=slot;
    button.style.left=x+'px';button.style.top=y+'px';button.style.height=height+'px';button.setAttribute('aria-label',label);
    button.title=slot==='weapon'?label:label+' · not available yet';button.disabled=true;
    button.addEventListener('pointermove',event=>showTooltip(event,slot));
    button.addEventListener('pointerleave',()=>tooltip.hidden=true);
    button.addEventListener('click',async()=>{
      const item=items.find(item=>item.slot===slot);if(!item||pending)return;
      pending=true;tooltip.hidden=true;render();status.textContent='Unequipping…';
      try {const result=await unequipItem({id:item.id,revision:item.revision});if(!disposed)status.textContent=result.ok?'':`Unequip rejected: ${result.error||'request'}`;}
      catch(error){if(!disposed)status.textContent=`Unequip failed: ${error.message}`;}
      finally {pending=false;if(!disposed)render();}
    });
    buttons.set(slot,button);body.append(button);
  }
  function showTooltip(event,slot){
    const item=items.find(item=>item.slot===slot);if(!item||pending||shell.drag)return;
    tooltip.querySelector('h2').textContent=item.name;tooltip.querySelector('p').textContent=item.description||'';tooltip.hidden=false;
    const width=tooltip.offsetWidth,height=tooltip.offsetHeight,x=event.clientX/shell.scale,y=event.clientY/shell.scale;
    const left=x+14+width>innerWidth/shell.scale?x-width-14:x+14;
    tooltip.style.left=Math.max(0,Math.min(left,innerWidth/shell.scale-width))+'px';tooltip.style.top=Math.max(0,Math.min(y+14,innerHeight/shell.scale-height))+'px';
  }
  function render(){
    for(const [slot,button] of buttons){
      const item=items.find(item=>item.slot===slot);button.replaceChildren();button.disabled=slot!=='weapon'||!item||pending;
      button.classList.toggle('equipped',!!item);
      if(item){button.removeAttribute('title');
        if(icons[item.icon]){const img=document.createElement('img');img.src=icons[item.icon];img.alt=item.name;img.className='item-icon';button.append(img);}
        else button.textContent=item.name;
      }
    }
  }
  return {regions:[panel],close:onClose,setState(state){
    manager.setScale(Number(state.hud?.ui_scale||shell.scale));
    tooltip.hidden=true;items=state.equipment?.items||[];render();root.querySelector('.equipment-stats').textContent='Attack '+Number(state.equipment?.stats?.attack||0);shell.refresh();
  },dispose(){disposed=true;shell.dispose();}};
}
