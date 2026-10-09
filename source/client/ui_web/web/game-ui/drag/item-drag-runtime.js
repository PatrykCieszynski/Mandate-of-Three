export class ItemDragRuntime {
    options;
    sources = new Map();
    targets = new Map();
    controls = new Map();
    removals = [];
    ghost;
    surface;
    session = null;
    resolution = null;
    activeTarget = null;
    pending = false;
    disposed = false;
    suppressClick = false;
    constructor(options) {
        this.options = options;
        this.ghost = document.createElement('div');
        this.ghost.className = 'carried-item';
        this.ghost.hidden = true;
        this.surface = document.createElement('div');
        this.surface.id = 'carry-surface';
        this.surface.hidden = true;
        document.body.append(this.ghost, this.surface);
        this.listen(document, 'pointerdown', (event) => this.down(event), true);
        this.listen(document, 'pointermove', (event) => {
            if (!this.session ||
                (!this.session.latched && event.pointerId !== this.session.pointerId))
                return;
            event.stopImmediatePropagation();
            this.update(event);
        }, true);
        this.listen(document, 'pointerup', (event) => this.up(event), true);
        this.listen(document, 'click', (event) => {
            if (!this.suppressClick || event.detail === 0)
                return;
            this.suppressClick = false;
            event.preventDefault();
            event.stopImmediatePropagation();
        }, true);
        this.listen(document, 'keydown', (event) => {
            if (event.key === 'Escape' && this.cancel()) {
                event.preventDefault();
                event.stopImmediatePropagation();
            }
        }, true);
        this.listen(document, 'contextmenu', (event) => {
            if (this.active)
                event.preventDefault();
        });
        this.listen(document, 'pointercancel', () => this.cancel());
        this.listen(document, 'lostpointercapture', (event) => {
            if (this.session &&
                !this.session.latched &&
                this.session.pointerId === event.pointerId)
                this.cancel();
        });
        this.listen(window, 'blur', () => this.cancel());
        this.listen(window, 'resize', () => this.cancel());
    }
    get active() {
        return this.session !== null;
    }
    get latched() {
        return this.session?.latched ?? false;
    }
    get regions() {
        return [this.surface];
    }
    get registrationCount() {
        this.prune();
        return this.sources.size + this.targets.size + this.controls.size;
    }
    registerSource(source) {
        this.ensureLive();
        if (this.sources.has(source.element))
            throw Error('Duplicate drag source');
        this.sources.set(source.element, source);
        return {
            dispose: () => {
                if (this.sources.get(source.element) !== source)
                    return;
                this.sources.delete(source.element);
                if (this.session?.node === source.element) {
                    if (!this.session.latched)
                        this.cancel();
                    else {
                        source.element.classList.remove('carried');
                        this.session.node = null;
                        this.session.source = null;
                    }
                }
            },
        };
    }
    registerTarget(target) {
        this.ensureLive();
        if (this.targets.has(target.element))
            throw Error('Duplicate drop target');
        const binding = {
            element: target.element,
            resolve: (payload, pointer) => {
                const preview = target.preview(payload, pointer);
                return {
                    valid: preview.valid,
                    ...(preview.visual ? { visual: preview.visual } : {}),
                    drop: () => {
                        if (this.targets.get(target.element) === binding &&
                            this.visible(target.element))
                            return target.drop(payload, preview);
                    },
                };
            },
        };
        this.targets.set(target.element, binding);
        return {
            dispose: () => {
                if (this.targets.get(target.element) !== binding)
                    return;
                this.targets.delete(target.element);
                if (this.activeTarget === binding)
                    this.clearPreview();
            },
        };
    }
    registerControl(element, behavior) {
        this.ensureLive();
        if (this.controls.has(element))
            throw Error('Duplicate drag control');
        this.controls.set(element, behavior);
        return {
            dispose: () => {
                this.controls.delete(element);
            },
        };
    }
    // A page can repaint while carrying a detached payload; stale markers never survive.
    refreshPreview() {
        this.clearPreview();
    }
    cancel() {
        const old = this.session;
        this.session = null;
        this.clearPreview();
        if (old) {
            this.release(old);
            old.node?.classList.remove('carried');
        }
        this.ghost.hidden = true;
        this.ghost.replaceChildren();
        this.surface.hidden = true;
        if (old)
            this.options.onRegionsChanged();
        return old !== null;
    }
    clearPreview() {
        this.resolution?.visual?.element.remove();
        this.resolution = null;
        this.activeTarget = null;
    }
    release(session) {
        if (session.node?.hasPointerCapture(session.pointerId))
            session.node.releasePointerCapture(session.pointerId);
    }
    down(event) {
        this.prune();
        this.suppressClick = false;
        if (event.button === 2 && this.active) {
            event.preventDefault();
            event.stopImmediatePropagation();
            this.cancel();
            return;
        }
        if (event.button !== 0)
            return;
        const node = event.target instanceof Element ? event.target : null;
        if (!node)
            return;
        if (this.active) {
            for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
                if (!(ancestor instanceof HTMLElement))
                    continue;
                const control = this.controls.get(ancestor);
                if (control) {
                    if (control === 'cancel' || !this.latched)
                        this.cancel();
                    else
                        this.clearPreview();
                    return;
                }
            }
            if (this.latched) {
                event.preventDefault();
                event.stopImmediatePropagation();
                this.suppressClick = true;
                this.update(event);
                this.drop();
            }
            return;
        }
        if (this.pending || this.disposed)
            return;
        for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
            if (!(ancestor instanceof HTMLElement))
                continue;
            const source = this.sources.get(ancestor);
            if (!source || !this.visible(ancestor))
                continue;
            const payload = source.payload(event);
            if (!payload)
                return;
            const scale = this.options.scale();
            if (!Number.isFinite(scale) || scale <= 0)
                return;
            const rect = source.element.getBoundingClientRect();
            event.preventDefault();
            event.stopImmediatePropagation();
            this.suppressClick = true;
            this.session = {
                payload,
                source,
                node: source.element,
                pointerId: event.pointerId,
                start: { x: event.clientX, y: event.clientY },
                offset: {
                    x: (event.clientX - rect.left) / scale,
                    y: (event.clientY - rect.top) / scale,
                },
                scale,
                moved: false,
                latched: false,
            };
            source.element.setPointerCapture(event.pointerId);
            source.element.classList.add('carried');
            payload.presentation.render(this.ghost);
            this.ghost.style.width = payload.presentation.width + 'px';
            this.ghost.style.height = payload.presentation.height + 'px';
            this.ghost.style.transformOrigin = 'top left';
            this.ghost.style.transform = `scale(${scale})`;
            this.ghost.hidden = false;
            this.surface.hidden = false;
            this.options.onRegionsChanged();
            this.update(event);
            return;
        }
    }
    up(event) {
        const session = this.session;
        if (!session || session.latched || session.pointerId !== event.pointerId)
            return;
        event.preventDefault();
        event.stopImmediatePropagation();
        this.update(event);
        if (this.session !== session)
            return;
        if (session.moved)
            this.drop();
        else if (session.source?.onClick) {
            const action = session.source.onClick;
            this.cancel();
            action();
        }
        else {
            session.latched = true;
            this.release(session);
        }
    }
    update(event) {
        this.prune();
        const session = this.session;
        if (!session)
            return;
        const scale = this.options.scale();
        if (scale !== session.scale) {
            this.cancel();
            return;
        }
        if (Math.hypot(event.clientX - session.start.x, event.clientY - session.start.y) >
            3 * scale)
            session.moved = true;
        this.ghost.style.left = event.clientX - session.offset.x * scale + 'px';
        this.ghost.style.top = event.clientY - session.offset.y * scale + 'px';
        this.clearPreview();
        const hit = document.elementFromPoint(event.clientX, event.clientY);
        for (let ancestor = hit; ancestor; ancestor = ancestor.parentElement) {
            if (!(ancestor instanceof HTMLElement))
                continue;
            const target = this.targets.get(ancestor);
            if (!target || !this.visible(ancestor))
                continue;
            this.activeTarget = target;
            this.resolution = target.resolve(session.payload, {
                point: { x: event.clientX, y: event.clientY },
                grabOffset: session.offset,
                scale,
            });
            const visual = this.resolution.visual;
            if (visual)
                visual.parent.append(visual.element);
            break;
        }
    }
    drop() {
        const resolution = this.resolution;
        this.cancel();
        if (!resolution?.valid || this.pending)
            return;
        this.pending = true;
        void Promise.resolve()
            .then(() => {
            if (!this.disposed)
                return resolution.drop();
        })
            .catch((error) => this.options.onError?.(error))
            .finally(() => {
            this.pending = false;
        });
    }
    visible(element) {
        return element.isConnected && !element.closest('[hidden]');
    }
    prune() {
        for (const [element] of this.sources)
            if (!element.isConnected) {
                this.sources.delete(element);
                if (this.session?.node === element)
                    this.cancel();
            }
        for (const [element, target] of this.targets)
            if (!element.isConnected) {
                this.targets.delete(element);
                if (this.activeTarget === target)
                    this.clearPreview();
            }
        for (const [element] of this.controls)
            if (!element.isConnected)
                this.controls.delete(element);
        if (this.session?.node && !this.visible(this.session.node))
            this.cancel();
    }
    ensureLive() {
        if (this.disposed)
            throw Error('Disposed ItemDragRuntime');
    }
    listen(target, type, callback, capture = false) {
        target.addEventListener(type, callback, capture);
        this.removals.push(() => target.removeEventListener(type, callback, capture));
    }
    dispose() {
        if (this.disposed)
            return;
        this.disposed = true;
        this.cancel();
        for (const remove of this.removals)
            remove();
        this.removals.length = 0;
        this.sources.clear();
        this.targets.clear();
        this.controls.clear();
        this.ghost.remove();
        this.surface.remove();
    }
}
