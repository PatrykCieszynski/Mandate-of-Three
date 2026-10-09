export function tooltipPosition(point,size,viewport,scale,gap=14) {
  const width=viewport.width/scale,height=viewport.height/scale;
  const left=point.x+gap+size.width>width?point.x-size.width-gap:point.x+gap;
  return {x:Math.max(0,Math.min(left,width-size.width)),y:Math.max(0,Math.min(point.y+gap,height-size.height))};
}
export function UiTooltip(root,{geometry}) {
  const element=document.createElement('aside');element.className='item-tooltip';element.hidden=true;
  const title=document.createElement('h2'),description=document.createElement('p');element.append(title,description);root.append(element);
  return {element,hide(){element.hidden=true;},show(event,{name,description:text=''}){
    title.textContent=name;description.textContent=text;element.hidden=false;
    const {viewport,scale}=geometry();const position=tooltipPosition({x:event.clientX/scale,y:event.clientY/scale},
      {width:element.offsetWidth,height:element.offsetHeight},viewport,scale);
    element.style.left=position.x+'px';element.style.top=position.y+'px';
  },dispose(){element.remove();}};
}
