import type { Point } from '../../core/window/window-types.js';
// Subject and target data belong to policies; the gesture runtime never decodes them.
export interface ItemDragPresentation {
  width: number;
  height: number;
  // A list/button source can choose an anchor inside its carried footprint.
  grabOffset?: Point;
  render: (ghost: HTMLElement) => void;
}
export interface ItemDragPayload {
  sourceId: string;
  subject: unknown;
  presentation: ItemDragPresentation;
}
export interface DragPointer {
  point: Point; // viewport CSS pixels
  grabOffset: Point; // logical pixels
  scale: number;
}
export interface DropPreview<T> {
  valid: boolean;
  data: T;
  visual?: { element: HTMLElement; parent: HTMLElement };
}
export interface ItemDragSource {
  element: HTMLElement;
  payload: (event: PointerEvent) => ItemDragPayload | null;
}
export interface ItemDropTarget<T> {
  element: HTMLElement;
  preview: (payload: ItemDragPayload, pointer: DragPointer) => DropPreview<T>;
  drop: (
    payload: ItemDragPayload,
    preview: DropPreview<T>,
  ) => void | Promise<void>;
}
export interface DragRegistration {
  dispose(): void;
}
