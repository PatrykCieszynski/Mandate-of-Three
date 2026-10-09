import { WindowLayout } from './window-layout.js';
// Registration, activation and layout invalidation; rendering belongs to UiWindow.
export class WindowManager {
    #windows = new Map();
    #viewport = Object.freeze({ width: 0, height: 0 });
    #scale = 1;
    #activeWindowId = null;
    #order = [];
    #disposed = false;
    get viewport() {
        return this.#viewport;
    }
    get scale() {
        return this.#scale;
    }
    get activeWindowId() {
        return this.#activeWindowId;
    }
    get disposed() {
        return this.#disposed;
    }
    get registeredCount() {
        return this.#windows.size;
    }
    has(id) {
        return this.#windows.has(id);
    }
    assertActive() {
        if (this.#disposed)
            throw new Error('Disposed WindowManager');
    }
    layout = new WindowLayout(() => this);
    host;
    resize;
    constructor({ host = globalThis.window } = {}) {
        this.host = host;
        this.resize = () => {
            if (host)
                this.setViewport({ width: host.innerWidth, height: host.innerHeight });
        };
        host?.addEventListener('resize', this.resize);
    }
    register({ id, element, root = element, placement, }) {
        this.assertActive();
        if (typeof id !== 'string' || !id)
            throw new Error('Window registration requires a stable id');
        if (this.#windows.has(id))
            throw new Error('Duplicate window: ' + id);
        const entry = {
            root,
            layoutListeners: new Set(),
            activationListeners: new Set(),
        };
        this.#windows.set(id, entry);
        this.layout.register(id, element, placement);
        root.style.setProperty('--ui-scale', String(this.#scale));
        this.#order.push(id);
        this.restack();
        const current = () => {
            this.assertActive();
            if (this.#windows.get(id) !== entry)
                throw new Error('Disposed window: ' + id);
        };
        return {
            activate: () => {
                current();
                this.activate(id);
            },
            place: () => {
                current();
                return this.place(id);
            },
            move: (position) => {
                current();
                return this.move(id, position);
            },
            resetPosition: () => {
                current();
                this.layout.resetPosition(id);
                this.refresh(id);
            },
            refresh: () => {
                current();
                this.refresh(id);
            },
            onLayoutChanged: (listener) => {
                current();
                entry.layoutListeners.add(listener);
                return () => {
                    entry.layoutListeners.delete(listener);
                };
            },
            onActivate: (listener) => {
                current();
                entry.activationListeners.add(listener);
                return () => {
                    entry.activationListeners.delete(listener);
                };
            },
            dispose: () => {
                if (this.#windows.get(id) === entry)
                    this.unregister(id);
            },
        };
    }
    unregister(id) {
        this.assertActive();
        this.removeWindow(id);
    }
    removeWindow(id) {
        const entry = this.#windows.get(id);
        if (!entry)
            return;
        try {
            for (const listener of entry.layoutListeners)
                listener({ cancelTransient: true });
        }
        finally {
            entry.layoutListeners.clear();
            entry.activationListeners.clear();
            this.#windows.delete(id);
            this.layout.unregister(id);
            this.#order = this.#order.filter((key) => key !== id);
            if (this.#activeWindowId === id)
                this.#activeWindowId = null;
            if (!this.#disposed)
                this.syncActive();
            this.restack();
        }
    }
    restack() {
        this.#order.forEach((id, index) => {
            const entry = this.#windows.get(id);
            if (entry)
                entry.root.style.zIndex = String(10 + index);
        });
    }
    activate(id) {
        this.assertActive();
        const entry = this.#windows.get(id);
        if (!entry || entry.root.hidden || this.#activeWindowId === id)
            return;
        this.#order = this.#order.filter((key) => key !== id);
        this.#order.push(id);
        this.#activeWindowId = id;
        this.restack();
        for (const listener of entry.activationListeners)
            listener();
    }
    syncActive() {
        if (this.#activeWindowId === null ||
            this.#windows.get(this.#activeWindowId)?.root.hidden ||
            !this.#windows.has(this.#activeWindowId)) {
            this.#activeWindowId = null;
            const visible = [...this.#order]
                .reverse()
                .find((id) => this.#windows.get(id)?.root.hidden === false);
            if (visible)
                this.activate(visible);
        }
    }
    refresh(id, cancelTransient = false) {
        this.assertActive();
        const entry = this.#windows.get(id);
        if (!entry)
            return;
        for (const listener of entry.layoutListeners)
            listener({ cancelTransient: cancelTransient || entry.root.hidden });
        this.syncActive();
    }
    refreshAll(cancelTransient = false) {
        this.assertActive();
        for (const id of this.#windows.keys())
            this.refresh(id, cancelTransient);
    }
    setScale(scale) {
        this.assertActive();
        if (!Number.isFinite(scale) || scale <= 0)
            throw new Error('Invalid UI scale');
        if (scale === this.#scale)
            return;
        this.#scale = scale;
        for (const entry of this.#windows.values())
            entry.root.style.setProperty('--ui-scale', String(scale));
        this.refreshAll(true);
    }
    setViewport(viewport, scale = this.#scale) {
        this.assertActive();
        const changed = viewport.width !== this.#viewport.width ||
            viewport.height !== this.#viewport.height;
        this.#viewport = Object.freeze({ ...viewport });
        if (scale !== this.#scale)
            this.setScale(scale);
        else if (changed)
            this.refreshAll(true);
    }
    place(id) {
        this.assertActive();
        return this.layout.place(id);
    }
    move(id, position) {
        this.assertActive();
        return this.layout.move(id, position);
    }
    dispose() {
        if (this.#disposed)
            return;
        this.#disposed = true;
        this.host?.removeEventListener('resize', this.resize);
        const errors = [];
        for (const id of [...this.#windows.keys()]) {
            try {
                this.removeWindow(id);
            }
            catch (error) {
                errors.push(error);
            }
        }
        if (errors.length)
            throw new AggregateError(errors, 'WindowManager disposal failed');
    }
}
