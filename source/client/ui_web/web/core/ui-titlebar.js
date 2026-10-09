import {UiButton} from './ui-button.js';
export const titlebarMarkup='<header class="window-header"><h1></h1><button type="button" class="window-close">×</button></header>';
export function UiTitlebar(element,{title,onClose}) {
  element.querySelector('h1').textContent=title;
  const close=UiButton({element:element.querySelector('button'),label:'×',onClick:onClose});
  close.element.setAttribute('aria-label','Close '+title.toLowerCase());
  return {element,close:close.element,dispose:()=>close.dispose()};
}
