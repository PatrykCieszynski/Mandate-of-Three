export type WindowId = string;
export interface Point { x: number; y: number }
export interface Size { width: number; height: number }
export type Viewport = Size;
export interface ViewportPlacement {
  kind: 'viewport';
  anchor: 'top-left' | 'top-right' | 'bottom-left' | 'bottom-right';
  offset?: Point;
}
export interface RelativePlacement {
  kind: 'relative'; target: WindowId;
  side: 'left' | 'right' | 'top' | 'bottom';
  align?: 'start' | 'center' | 'end'; gap?: number; offset?: Point;
  // Preserve standalone placement while the target has never been measured.
  fallback?: ViewportPlacement;
}
export type WindowPlacement = ViewportPlacement | RelativePlacement;
export interface WindowRegistration {
  id: WindowId; element: HTMLElement; root?: HTMLElement; placement?: WindowPlacement;
}
export interface LayoutInvalidation { cancelTransient: boolean }
export interface WindowHandle {
  activate(): void;
  place(): Point;
  move(position: Point): Point;
  resetPosition(): void;
  refresh(): void;
  onLayoutChanged(listener: (event: LayoutInvalidation) => void): () => void;
  onActivate(listener: () => void): () => void;
  dispose(): void;
}
