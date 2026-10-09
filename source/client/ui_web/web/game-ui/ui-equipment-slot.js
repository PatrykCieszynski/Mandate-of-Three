import {UiSlot} from '../core/ui-slot.js';
import {paintItemIcon} from './item-icon.js';
export function UiEquipmentSlot({slot,label,x,y,height,resolveItemIcon,title=label}) {
  const element=UiSlot({tag:'button',className:'equipment-slot',label});element.dataset.slot=slot;
  element.style.left=x+'px';element.style.top=y+'px';element.style.height=height+'px';element.title=title;element.disabled=true;
  return {element,setItem(item,{enabled=false}={}){
    element.replaceChildren();element.disabled=!enabled;element.classList.toggle('equipped',!!item);
    if(item){element.removeAttribute('title');paintItemIcon(element,item,{resolveItemIcon,alt:item.name,fallbackClass:null,quantity:false});}
  }};
}
