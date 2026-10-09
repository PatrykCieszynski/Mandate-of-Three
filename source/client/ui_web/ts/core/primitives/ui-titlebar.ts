import {element as findElement} from '../dom.js';
import {UiButton} from './ui-button.js';
export function UiTitlebar(element: HTMLElement,{title,onClose}: {title: string; onClose: () => void}) {
  findElement(element,'h1','h1').textContent=title;
  const close=UiButton({element:findElement(element,'button','button'),label:'×',onClick:onClose});
  close.element.setAttribute('aria-label','Close '+title.toLowerCase());
  return {element,close:close.element,dispose:()=>close.dispose()};
}
