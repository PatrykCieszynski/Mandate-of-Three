// Architecture acceptance fixture only: no Storage IPC, backend or production entrypoint.
import type {WindowManager} from '../web/core/window/window-manager.js';
import type {ItemGridModel, ItemSlotPresentation, PositionedItem, ResolveItemIcon} from '../web/game-ui/item-types.js';
import {UiWindow} from '../web/core/window/ui-window.js';
import {UiItemGrid} from '../web/game-ui/items/ui-item-grid.js';
import {UiItemSlot} from '../web/game-ui/items/ui-item-slot.js';
import {ItemTooltip} from '../web/game-ui/items/item-tooltip.js';
export interface StorageItem extends ItemSlotPresentation, PositionedItem { description?: string }
export type StorageState = ItemGridModel<StorageItem>;
interface StorageOptions {
  manager: WindowManager; resolveItemIcon: ResolveItemIcon;
  onClose: () => void; onItemAction: (event: PointerEvent,item: StorageItem) => void;
  onRegionsChanged: () => void;
}
export function mountStorageFixture(root: HTMLElement,{manager,resolveItemIcon,onClose,onItemAction,onRegionsChanged}: StorageOptions) {
  const shell=new UiWindow(root,{id:'storage',title:'Storage',manager,
    placement:{kind:'viewport',anchor:'top-left',offset:{x:1000,y:80}},
    onClose,onRegionsChanged,onCancel:()=>tooltip.hide()});
  const element=document.createElement('div');shell.contentRoot.append(element);
  const grid=UiItemGrid(element,{slotSize:()=>40}),tooltip=ItemTooltip(root,{geometry:()=>manager});
  let state: StorageState | undefined;
  function itemFor(event: Event) {
    const node=event.target instanceof Element?event.target.closest<HTMLElement>('.ui-item-slot'):null;
    return state?.items.find(item=>item.id===node?.dataset.id);
  }
  shell.listen(element,'pointerdown',event=>{const item=itemFor(event);if(item)onItemAction(event,item);});
  shell.listen(element,'pointermove',event=>{const item=itemFor(event);if(item)tooltip.show(event,item);});
  shell.listen(element,'pointerleave',()=>tooltip.hide());
  return {regions:[shell.panel],setState(model: StorageState){
    state=model;tooltip.hide();grid.render(model,item=>UiItemSlot({item,slotSize:40,resolveItemIcon}));shell.refresh();
  },dispose(){shell.dispose();tooltip.dispose();grid.dispose();}};
}
