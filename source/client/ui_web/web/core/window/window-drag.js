// Pointer capture and frame coalescing. Global move/up listeners exist only while dragging.
export class WindowDragController {
    options;
    state = null;
    frame = 0;
    pending;
    disposed = false;
    document;
    constructor(options) {
        this.options = options;
        this.document = options.handle.ownerDocument;
        options.handle.addEventListener('pointerdown', this.start);
        options.handle.addEventListener('lostpointercapture', this.lostCapture);
    }
    get active() {
        return this.state !== null;
    }
    start = (event) => {
        const { handle, getPosition, toLogicalPoint, canStart, onActiveChanged } = this.options, position = getPosition();
        if (this.disposed ||
            this.state ||
            event.button !== 0 ||
            (event.target instanceof Element && event.target.closest('button')) ||
            !canStart() ||
            !position)
            return;
        event.preventDefault();
        const point = toLogicalPoint(event);
        this.state = {
            pointer: event.pointerId,
            offset: { x: point.x - position.x, y: point.y - position.y },
        };
        handle.setPointerCapture(event.pointerId);
        onActiveChanged(true);
        this.document.addEventListener('pointermove', this.move);
        this.document.addEventListener('pointerup', this.end);
        this.document.addEventListener('pointercancel', this.cancel);
        this.document.defaultView?.addEventListener('blur', this.cancel);
    };
    move = (event) => {
        const state = this.state;
        if (!state || event.pointerId !== state.pointer)
            return;
        if (!this.options.handle.hasPointerCapture(state.pointer)) {
            this.stop();
            return;
        }
        const point = this.options.toLogicalPoint(event);
        this.pending = this.options.onMove({
            x: point.x - state.offset.x,
            y: point.y - state.offset.y,
        });
        if (!this.frame)
            this.frame = requestAnimationFrame(() => {
                this.frame = 0;
                const position = this.pending;
                this.pending = undefined;
                if (!this.disposed && position)
                    this.options.paint(position);
            });
    };
    end = (event) => {
        if (this.state?.pointer === event.pointerId)
            this.stop();
    };
    lostCapture = (event) => {
        if (this.state?.pointer === event.pointerId)
            this.stop();
    };
    cancel = () => {
        this.stop();
    };
    stop() {
        this.document.removeEventListener('pointermove', this.move);
        this.document.removeEventListener('pointerup', this.end);
        this.document.removeEventListener('pointercancel', this.cancel);
        this.document.defaultView?.removeEventListener('blur', this.cancel);
        if (this.frame) {
            cancelAnimationFrame(this.frame);
            this.frame = 0;
        }
        const position = this.pending;
        this.pending = undefined;
        if (position)
            this.options.paint(position);
        const old = this.state;
        this.state = null;
        this.options.onActiveChanged(false);
        if (old && this.options.handle.hasPointerCapture(old.pointer))
            this.options.handle.releasePointerCapture(old.pointer);
    }
    dispose() {
        if (this.disposed)
            return;
        this.disposed = true;
        this.stop();
        this.options.handle.removeEventListener('pointerdown', this.start);
        this.options.handle.removeEventListener('lostpointercapture', this.lostCapture);
    }
}
