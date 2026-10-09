import { clampWindow } from './geometry.js';
// Geometry is measured in logical pixels; viewport dimensions are physical pixels.
export class WindowManager {
    constructor({ host = globalThis.window } = {}) {
        this.windows = new Map();
        this.viewport = { width: 0, height: 0 };
        this.scale = 1;
        this.activeWindowId = null;
        this.order = [];
        this.host = host;
        this.resize = () => { if (host)
            this.setViewport({ width: host.innerWidth, height: host.innerHeight }); };
        host?.addEventListener('resize', this.resize);
    }
    register({ window_id: id, element, root = element, prepare = () => { }, paint = () => { }, cancel = () => { }, onActivate = () => { }, preferredAnchor = 'right', defaultOffset = { x: 0, y: 0 }, relativeTo = null, relativeOffset = { x: 0, y: 0 } }) {
        if (typeof id !== 'string' || !id)
            throw new Error('Window registration requires a stable window_id');
        if (this.windows.has(id))
            throw new Error('Duplicate window: ' + id);
        this.windows.set(id, { element, root, prepare, paint, cancel, onActivate, preferredAnchor, defaultOffset, relativeTo, relativeOffset, position: null, manual: false, size: null });
        this.order.push(id);
        this.restack();
    }
    unregister(id) { this.windows.delete(id); this.order = this.order.filter(key => key !== id); if (this.activeWindowId === id)
        this.activeWindowId = null; this.syncActive(); this.restack(); }
    restack() { this.order.forEach((id, index) => { const entry = this.windows.get(id); if (entry)
        entry.root.style.zIndex = String(10 + index); }); }
    activate(id) {
        const entry = this.windows.get(id);
        if (!entry || entry.root.hidden || this.activeWindowId === id)
            return;
        this.order = this.order.filter(key => key !== id);
        this.order.push(id);
        this.activeWindowId = id;
        this.restack();
        entry.onActivate();
    }
    syncActive() {
        if (this.activeWindowId === null || this.windows.get(this.activeWindowId)?.root.hidden || !this.windows.has(this.activeWindowId)) {
            this.activeWindowId = null;
            const visible = [...this.order].reverse().find(id => this.windows.get(id)?.root.hidden === false);
            if (visible)
                this.activate(visible);
        }
    }
    refresh(id) { const entry = this.windows.get(id); if (!entry)
        return; if (entry.root.hidden) {
        entry.cancel();
        this.syncActive();
        return;
    } entry.prepare(); entry.paint(this.place(id)); this.syncActive(); }
    refreshAll(cancel = false) { for (const [id, entry] of this.windows) {
        if (cancel)
            entry.cancel();
        this.refresh(id);
    } }
    setScale(scale) {
        if (!Number.isFinite(scale) || scale <= 0)
            throw new Error('Invalid UI scale');
        if (scale === this.scale)
            return;
        this.scale = scale;
        for (const entry of this.windows.values())
            entry.root.style.setProperty('--ui-scale', String(scale));
        this.refreshAll(true);
    }
    dispose() { this.host?.removeEventListener('resize', this.resize); for (const entry of this.windows.values())
        entry.cancel(); this.windows.clear(); this.order = []; this.activeWindowId = null; }
    setViewport(viewport, scale = this.scale) {
        const changed = viewport.width !== this.viewport.width || viewport.height !== this.viewport.height;
        this.viewport = { ...viewport };
        if (scale !== this.scale)
            this.setScale(scale);
        else if (changed)
            this.refreshAll(true);
    }
    measure(entry) {
        if (entry.element.getClientRects().length)
            entry.size = { width: entry.element.offsetWidth, height: entry.element.offsetHeight };
        return entry.size;
    }
    place(id, visiting = new Set()) {
        const entry = this.windows.get(id);
        if (!entry)
            throw new Error('Unknown window: ' + id);
        if (visiting.has(id))
            throw new Error('Cyclic window placement: ' + id);
        visiting.add(id);
        const size = this.measure(entry) || { width: 0, height: 0 };
        let position = entry.position;
        if (!entry.manual) {
            position = { x: (entry.preferredAnchor === 'right' ? this.viewport.width / this.scale - size.width : 0) + entry.defaultOffset.x, y: entry.defaultOffset.y };
            const relative = entry.relativeTo === null ? undefined : this.windows.get(entry.relativeTo);
            if (entry.relativeTo !== null && relative && this.measure(relative)) {
                const anchor = this.place(entry.relativeTo, visiting);
                position = { x: anchor.x - size.width + entry.relativeOffset.x, y: anchor.y + entry.relativeOffset.y };
            }
        }
        entry.position = clampWindow(position ?? { x: 0, y: 0 }, size, this.viewport, this.scale);
        visiting.delete(id);
        return { ...entry.position };
    }
    move(id, position) {
        const entry = this.windows.get(id);
        if (!entry)
            throw new Error('Unknown window: ' + id);
        entry.manual = true;
        entry.position = clampWindow(position, this.measure(entry) || { width: 0, height: 0 }, this.viewport, this.scale);
        return { ...entry.position };
    }
}
