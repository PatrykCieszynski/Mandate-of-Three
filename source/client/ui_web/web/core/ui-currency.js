import {uiIcons} from './ui-icons.js';
import {loadImage} from './skin.js';
export function UiCurrency(element,{iconId='currencies.yang',icons=uiIcons,loadAsset=loadImage}={}) {
  const amount=element.querySelector('strong'),icon=element.querySelector('.yang-icon');let version=0,disposed=false;
  const refresh=async()=>{
    const current=++version,url=icons.resolve(iconId);icon.style.backgroundImage='none';
    if(url&&await loadAsset(url)&&!disposed&&current===version)icon.style.backgroundImage=`url(${JSON.stringify(url)})`;
  };
  const unsubscribe=icons.subscribe(refresh);refresh();
  return {element,setValue(value){amount.textContent=Number(value||0).toLocaleString('en-US');},dispose(){disposed=true;version++;unsubscribe();}};
}
