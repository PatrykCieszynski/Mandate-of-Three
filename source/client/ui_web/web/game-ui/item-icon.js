// Shared item presentation only; content resolver supplies URLs from icon_id.
export function paintItemIcon(element,item,{resolveItemIcon,alt='',fallbackClass='icon-fallback',quantity=true}) {
  element.replaceChildren();
  const fallback=()=>{const label=document.createElement('span');if(fallbackClass)label.className=fallbackClass;label.textContent=item.name;return label;};
  const url=resolveItemIcon(item.icon_id);
  if(url){const image=document.createElement('img');image.src=url;image.alt=alt;image.className='item-icon';
    image.addEventListener('error',()=>image.replaceWith(fallback()),{once:true});element.append(image);
  }else element.append(fallback());
  if(quantity&&item.quantity>1){const count=document.createElement('span');count.className='quantity';count.textContent=item.quantity;element.append(count);}
}
