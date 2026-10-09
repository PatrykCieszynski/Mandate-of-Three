import type {InventorySnapshot, InventoryItem} from '../contracts.js';
import {UiSlot} from '../core/ui-slot.js';
// Screen-owned grid dimensions and item footprints, independent of the skin.
export function UiInventoryGrid(element: HTMLElement,{slotSize}: {slotSize: () => number}) {
  return {element,render(inventory: InventorySnapshot,page: number,createItem: (item: InventoryItem) => HTMLElement){
    const size=slotSize();element.replaceChildren();element.style.width=inventory.columns*size+'px';element.style.height=inventory.rows*size+'px';
    for(let y=0;y<inventory.rows;y++)for(let x=0;x<inventory.columns;x++){
      const cell=UiSlot({className:'cell'});cell.style.left=x*size+'px';cell.style.top=y*size+'px';element.append(cell);
    }
    for(const item of inventory.items.filter(item=>item.page===page)){
      const node=createItem(item);node.style.left=item.x*size+1+'px';node.style.top=item.y*size+1+'px';element.append(node);
    }
  },dispose(){element.replaceChildren();}};
}
