import type {
  WindowId,
  Point,
  WindowPlacement,
  WindowHandle,
} from './window-types.js';
import type { WindowManager } from './window-manager.js';
import { UiTitlebar } from '../primitives/ui-titlebar.js';
import { WindowDragController } from './window-drag.js';
import { createWindowShell } from './window-shell.js';
export interface UiWindowOptions {
  id: WindowId;
  title: string;
  manager: WindowManager;
  className?: string;
  placement?: WindowPlacement;
  onClose?: () => void;
  canDrag?: () => boolean;
  onCancel?: () => void;
  onRegionsChanged?: () => void;
  onGeometry?: () => void;
  onActivate?: () => void;
  scrollBorder?: number;
  hideHorizontalOverflow?: boolean;
}
// Shell composition. The screen supplies content, placement and actions.
export class UiWindow {
  readonly id: WindowId;
  readonly panel: HTMLElement;
  readonly contentRoot: HTMLElement;
  readonly handle: WindowHandle;
  private readonly dragController: WindowDragController;
  private readonly removals: (() => void)[] = [];
  private disposed = false;
  private position: Point | undefined;
  constructor(
    readonly root: HTMLElement,
    private readonly options: UiWindowOptions,
  ) {
    this.validateOptions();
    this.id = options.id;
    const shell = createWindowShell(root, {
      id: this.id,
      title: options.title,
      className: options.className ?? '',
    });
    this.panel = shell.panel;
    this.contentRoot = shell.content;
    this.handle = this.registerWindow();
    this.dragController = this.createDragController(shell.header);
    this.bindTitlebar(shell.header);
    this.bindLayout();
    this.bindActivation();
    this.bindCancellation();
  }
  private validateOptions() {
    if (
      !this.options.manager ||
      typeof this.options.id !== 'string' ||
      !this.options.id
    )
      throw new Error('UiWindow requires manager and stable id');
  }
  private registerWindow(): WindowHandle {
    return this.options.manager.register({
      id: this.id,
      root: this.root,
      element: this.panel,
      ...(this.options.placement ? { placement: this.options.placement } : {}),
    });
  }
  private createDragController(header: HTMLElement): WindowDragController {
    return new WindowDragController({
      handle: header,
      getPosition: () => this.position,
      toLogicalPoint: (event) => this.point(event),
      onMove: (position) => this.handle.move(position),
      paint: (position) => this.paint(position),
      canStart: () => this.options.canDrag?.() ?? true,
      onActiveChanged: (active) => {
        this.panel.style.willChange = active ? 'transform' : 'auto';
      },
    });
  }
  private bindTitlebar(header: HTMLElement) {
    const titlebar = UiTitlebar(header, {
      title: this.options.title,
      onClose: () => {
        this.cancel();
        this.options.onClose?.();
      },
    });
    this.removals.push(() => titlebar.dispose());
  }
  private bindLayout() {
    let wasHidden = this.root.hidden;
    this.removals.push(
      this.handle.onLayoutChanged(({ cancelTransient }) => {
        // Repainting an already hidden window must not cancel another window's carry.
        if (cancelTransient && (!this.root.hidden || !wasHidden)) this.cancel();
        wasHidden = this.root.hidden;
        if (this.root.hidden || this.disposed || this.options.manager.disposed)
          return;
        this.updateOverflow();
        this.paint(this.handle.place());
      }),
    );
  }
  private bindActivation() {
    this.removals.push(
      this.handle.onActivate(() => this.options.onActivate?.()),
    );
    this.listen(this.panel, 'pointerdown', () => this.handle.activate());
    this.listen(this.panel, 'focusin', () => this.handle.activate());
  }
  private bindCancellation() {
    // Screen transients (including Inventory carry) also cancel outside window drag.
    this.listen(document, 'pointercancel', () => this.cancel());
    this.listen(window, 'blur', () => this.cancel());
  }
  private updateOverflow() {
    const height = this.options.manager.viewport.height / this.scale;
    this.panel.style.maxHeight = height + 'px';
    const small =
      this.panel.scrollHeight + (this.options.scrollBorder ?? 0) > height;
    this.panel.style.overflowY = small ? 'auto' : 'visible';
    if (this.options.hideHorizontalOverflow)
      this.panel.style.overflowX = small ? 'hidden' : 'visible';
  }
  private paint(position: Point) {
    this.position = position;
    this.panel.style.transform = `translate3d(${position.x}px,${position.y}px,0)`;
    this.options.onGeometry?.();
    this.options.onRegionsChanged?.();
  }
  cancel(): void {
    this.dragController.stop();
    this.options.onCancel?.();
  }
  get scale() {
    return this.options.manager.scale;
  }
  get drag() {
    return this.dragController.active;
  }
  point(event: Pick<MouseEvent, 'clientX' | 'clientY'>): Point {
    return { x: event.clientX / this.scale, y: event.clientY / this.scale };
  }
  listen<K extends keyof GlobalEventHandlersEventMap>(
    target: {
      addEventListener(
        type: NoInfer<K>,
        callback: (event: GlobalEventHandlersEventMap[NoInfer<K>]) => void,
      ): void;
      removeEventListener(
        type: NoInfer<K>,
        callback: (event: GlobalEventHandlersEventMap[NoInfer<K>]) => void,
      ): void;
    },
    type: K,
    callback: (event: GlobalEventHandlersEventMap[K]) => void,
  ) {
    target.addEventListener(type, callback);
    this.removals.push(() => target.removeEventListener(type, callback));
  }
  refresh() {
    if (!this.disposed) this.handle.refresh();
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.cancel();
    this.dragController.dispose();
    for (const remove of this.removals) remove();
    this.removals.length = 0;
    this.handle.dispose();
    this.root.replaceChildren();
    this.options.onRegionsChanged?.();
  }
}
