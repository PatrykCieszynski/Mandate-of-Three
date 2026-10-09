import type {ItemGridModel, PositionedItem} from '../item-types.js';
import {UiSlot} from '../../core/primitives/ui-slot.js';
// A rectangular item grid. The caller selects items and supplies their presentation.
export function UiItemGrid(element: HTMLElement,{slotSize}: {slotSize: () => number}) {
  element.classList.add('ui-item-grid');
  return {element,render<T extends PositionedItem>(model: ItemGridModel<T>,createItem: (item: T) => HTMLElement){
    const size=slotSize();element.replaceChildren();element.style.width=model.columns*size+'px';element.style.height=model.rows*size+'px';
    for(let y=0;y<model.rows;y++)for(let x=0;x<model.columns;x++){
      const cell=UiSlot({className:'cell'});cell.style.left=x*size+'px';cell.style.top=y*size+'px';element.append(cell);
    }
    for(const item of model.items){
      const node=createItem(item);node.style.left=item.x*size+1+'px';node.style.top=item.y*size+1+'px';element.append(node);
    }
  },dispose(){element.replaceChildren();}};
}
