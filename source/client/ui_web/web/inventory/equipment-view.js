import {clampWindow} from './placement.js';
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
export function mountEquipment(root,{unequipItem,onClose=()=>{},onRegionsChanged=()=>{}}={}) {
  root.innerHTML=`<section id="equipment-window" class="window-chrome equipment-window" aria-label="Equipment">
    <i class="chrome edge top"></i><i class="chrome edge bottom"></i><i class="chrome edge left"></i><i class="chrome edge right"></i>
    <i class="chrome corner tl"></i><i class="chrome corner tr"></i><i class="chrome corner bl"></i><i class="chrome corner br"></i>
    <header class="window-header"><h1>Equipment</h1><button class="window-close" aria-label="Close equipment">×</button></header>
    <div class="equipment-body"><div class="equipment-silhouette" aria-hidden="true">♟</div></div>
    <p class="equipment-stats"></p><p class="equipment-hint">Right-click bag items to equip.<br>Click weapon to unequip.</p>
    <p class="inventory-status" role="status"></p></section><aside class="item-tooltip" hidden><h2></h2><p></p></aside>`;
  const panel=root.querySelector('.equipment-window'),body=root.querySelector('.equipment-body'),status=root.querySelector('[role=status]'),tooltip=root.querySelector('.item-tooltip');
  let scale=1,position=null,drag=null,dragged=false,frame=0,dimensions=null,pending=false,items=[],disposed=false;
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
    const item=items.find(item=>item.slot===slot);if(!item||pending||drag)return;
    tooltip.querySelector('h2').textContent=item.name;tooltip.querySelector('p').textContent=item.description||'';tooltip.hidden=false;
    const width=tooltip.offsetWidth,height=tooltip.offsetHeight,x=event.clientX/scale,y=event.clientY/scale;
    const left=x+14+width>innerWidth/scale?x-width-14:x+14;
    tooltip.style.left=Math.max(0,Math.min(left,innerWidth/scale-width))+'px';tooltip.style.top=Math.max(0,Math.min(y+14,innerHeight/scale-height))+'px';
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
  function paint(){panel.style.transform=`translate3d(${position.x}px,${position.y}px,0)`;onRegionsChanged();}
  function flush(){if(frame){cancelAnimationFrame(frame);frame=0;paint();}}
  function layout(){
    if(root.hidden)return;
    flush();panel.style.maxHeight=innerHeight/scale+'px';panel.style.overflowY=panel.scrollHeight>innerHeight/scale?'auto':'visible';
    dimensions={width:panel.offsetWidth,height:panel.offsetHeight};
    const bagWidth=parseFloat(getComputedStyle(root).getPropertyValue('--window-width'));
    if(!position||!dragged)position={x:innerWidth/scale-bagWidth-12-dimensions.width-16,y:240};
    position=clampWindow(position,dimensions,{width:innerWidth,height:innerHeight},scale);paint();
  }
  function stop(){flush();panel.style.willChange='auto';const old=drag;drag=null;if(old?.node.hasPointerCapture(old.id))old.node.releasePointerCapture(old.id);}
  function move(event){if(!drag||event.pointerId!==drag.id)return;
    dragged=true;position=clampWindow({x:event.clientX/scale-drag.x,y:event.clientY/scale-drag.y},dimensions,{width:innerWidth,height:innerHeight},scale);
    if(!frame)frame=requestAnimationFrame(()=>{frame=0;if(!disposed)paint();});
  }
  const header=root.querySelector('.window-header');header.addEventListener('pointerdown',event=>{
    if(event.button!==0||event.target.closest('button'))return;event.preventDefault();
    drag={node:header,id:event.pointerId,x:event.clientX/scale-position.x,y:event.clientY/scale-position.y};
    panel.style.willChange='transform';header.setPointerCapture(event.pointerId);
  });
  const up=event=>{if(drag?.id===event.pointerId)stop();};
  const resize=()=>{stop();layout();};
  header.addEventListener('lostpointercapture',stop);
  root.querySelector('.window-close').addEventListener('click',onClose);
  document.addEventListener('pointermove',move);document.addEventListener('pointerup',up);document.addEventListener('pointercancel',stop);
  window.addEventListener('resize',resize);window.addEventListener('blur',stop);
  return {regions:[panel],close:onClose,setState(state){
    if(root.hidden)stop();
    const next=Number(state.hud?.ui_scale||scale);if(next!==scale){stop();scale=next;root.style.setProperty('--ui-scale',scale);}
    tooltip.hidden=true;items=state.equipment?.items||[];render();root.querySelector('.equipment-stats').textContent='Attack '+Number(state.equipment?.stats?.attack||0);layout();
  },dispose(){disposed=true;stop();document.removeEventListener('pointermove',move);document.removeEventListener('pointerup',up);document.removeEventListener('pointercancel',stop);window.removeEventListener('resize',resize);window.removeEventListener('blur',stop);}};
}
