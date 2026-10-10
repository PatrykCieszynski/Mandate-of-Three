import type { ShopOfferPresentation } from './shop-model.js';
import type { ResolveItemIcon } from '../../game-ui/item-types.js';
import type {
  ItemDragPayload,
  DragPointer,
  DropPreview,
} from '../../game-ui/drag/item-drag-types.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { carriedCell, placement } from '../inventory/placement.js';
import type { PlacementInventory, Placement } from '../inventory/placement.js';
export class NpcShopOfferDragSubject {
  constructor(
    readonly npcInstanceId: string,
    readonly serviceId: string,
    readonly offer: ShopOfferPresentation,
  ) {}
}
export function shopOfferPayload(
  subject: NpcShopOfferDragSubject,
  slotSize: number,
  resolveItemIcon: ResolveItemIcon,
): ItemDragPayload {
  return {
    sourceId: 'npc-shop',
    subject,
    presentation: {
      width: slotSize - 2,
      height: subject.offer.height * slotSize - 2,
      render: (ghost) =>
        paintItemIcon(
          ghost,
          { ...subject.offer, icon_id: subject.offer.iconId },
          { resolveItemIcon },
        ),
    },
  };
}
export interface ShopGridDrop {
  subject: NpcShopOfferDragSubject;
  position: Placement;
}
export function shopGridPreview(
  element: HTMLElement,
  model: PlacementInventory,
  page: number,
  slotSize: number,
  payload: ItemDragPayload,
  pointer: DragPointer,
): DropPreview<ShopGridDrop | null> {
  if (!(payload.subject instanceof NpcShopOfferDragSubject))
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
  // Empty identity cannot exclude an owned item from occupied cells.
  const position = placement(
    model,
    { id: '', height: payload.subject.offer.height },
    cell.x,
    cell.y,
    page,
  );
  const marker = document.createElement('div');
  marker.className = 'placement-preview' + (position.valid ? '' : ' invalid');
  marker.style.left = cell.x * slotSize + 'px';
  marker.style.top = cell.y * slotSize + 'px';
  marker.style.height = payload.subject.offer.height * slotSize + 'px';
  return {
    valid: position.valid,
    data: { subject: payload.subject, position },
    visual: { element: marker, parent: element },
  };
}
