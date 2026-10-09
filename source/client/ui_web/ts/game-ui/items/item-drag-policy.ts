import type { ItemPresentation, ResolveItemIcon } from '../item-types.js';
import type {
  DragPointer,
  DropPreview,
  ItemDragPayload,
  DragRegistration,
} from '../drag/item-drag-types.js';
import type { ItemDragRuntime } from '../drag/item-drag-runtime.js';
import type {
  PlacementInventory,
  Placement,
} from '../../screens/inventory/placement.js';
import { carriedCell, placement } from '../../screens/inventory/placement.js';
import { paintItemIcon } from './item-icon.js';
// A current owned-item policy contract, deliberately outside the opaque runtime.
// Future offer subjects need their own policies, without changing gesture mechanics.
export class OwnedItemDragSubject {
  constructor(
    readonly container: 'inventory' | 'storage' | 'equipment',
    readonly item: ItemPresentation,
  ) {}
}
export function ownedItemPayload(
  container: OwnedItemDragSubject['container'],
  item: ItemPresentation,
  slotSize: number,
  resolveItemIcon: ResolveItemIcon,
): ItemDragPayload {
  return {
    sourceId: container,
    subject: new OwnedItemDragSubject(container, item),
    presentation: {
      width: slotSize - 2,
      height: item.height * slotSize - 2,
      render: (ghost) => paintItemIcon(ghost, item, { resolveItemIcon }),
    },
  };
}
export interface GridDrop {
  subject: OwnedItemDragSubject;
  position: Placement;
}
export function itemGridPreview(
  element: HTMLElement,
  model: PlacementInventory,
  page: number,
  slotSize: number,
  payload: ItemDragPayload,
  pointer: DragPointer,
): DropPreview<GridDrop | null> {
  if (!(payload.subject instanceof OwnedItemDragSubject))
    return { valid: false, data: null };
  const rect = element.getBoundingClientRect();
  const cell = carriedCell(
    {
      x: (pointer.point.x - rect.left) / pointer.scale,
      y: (pointer.point.y - rect.top) / pointer.scale,
    },
    pointer.grabOffset,
    slotSize,
  );
  const position = placement(model, payload.subject.item, cell.x, cell.y, page);
  const marker = document.createElement('div');
  marker.className = 'placement-preview' + (position.valid ? '' : ' invalid');
  marker.style.left = cell.x * slotSize + 'px';
  marker.style.top = cell.y * slotSize + 'px';
  marker.style.height = payload.subject.item.height * slotSize + 'px';
  return {
    valid: position.valid,
    data: { subject: payload.subject, position },
    visual: { element: marker, parent: element },
  };
}
export function itemWindowControls(
  drag: ItemDragRuntime | undefined,
  root: HTMLElement,
): DragRegistration[] {
  if (!drag) return [];
  return [...root.querySelectorAll<HTMLElement>('.window-header')].map(
    (element) => drag.registerControl(element, 'cancel'),
  );
}
