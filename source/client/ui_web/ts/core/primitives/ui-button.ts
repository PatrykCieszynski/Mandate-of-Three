export function UiButton({element=document.createElement('button'),label='',className='',onClick=()=>{}}: {element?: HTMLButtonElement; label?: string; className?: string; onClick?: (event: MouseEvent) => void}={}) {
  element.type='button';if(className)element.className=className;element.textContent=label;
  element.addEventListener('click',onClick);
  return {element,setDisabled(value: boolean){element.disabled=!!value;},dispose(){element.removeEventListener('click',onClick);}};
}
