import {uiIcons} from './ui-icons.js';
import {loadImage} from './skin.js';
export function UiCurrency(element=document.createElement('footer'),{label='',iconId,icons=uiIcons,loadAsset=loadImage}={}) {
  element.classList.add('ui-currency');element.replaceChildren();
  const icon=document.createElement('span'),caption=document.createElement('span'),amount=document.createElement('strong');
  icon.className='currency-icon';icon.textContent='●';caption.textContent=label;amount.textContent='—';element.append(icon,caption,amount);
  let version=0,disposed=false;
  const refresh=async()=>{
    const current=++version,url=icons.resolve(iconId);icon.style.backgroundImage='none';
    if(url&&await loadAsset(url)&&!disposed&&current===version)icon.style.backgroundImage=`url(${JSON.stringify(url)})`;
  };
  const unsubscribe=icons.subscribe(refresh);refresh();
  return {element,setValue(value){amount.textContent=Number(value||0).toLocaleString('en-US');},dispose(){disposed=true;version++;unsubscribe();}};
}
