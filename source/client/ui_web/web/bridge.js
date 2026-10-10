import { decode, encode, isCommandResult, isStateMessage } from './protocol.js';
export class WebBridge {
    pending = new Map();
    sequence = 0;
    epoch = globalThis.crypto?.randomUUID?.() ?? String(Date.now());
    constructor({ send = message => window.sendIpcMessage(message), subscribe = callback => window.ipcMessage.addListener(callback), onState = () => { }, onShortcut = () => { }, onTooltipDetails = () => { }, timeoutMs = 3000 } = {}) {
        this.send = send;
        this.onState = onState;
        this.onShortcut = onShortcut;
        this.onTooltipDetails = onTooltipDetails;
        this.timeoutMs = timeoutMs;
        subscribe(message => this.receive(message));
    }
    event(type, payload = {}) { this.send(encode(type, payload)); }
    ready() {
        this.clearPending('reload');
        this.event('ui.ready');
    }
    clearPending(reason) {
        for (const request of this.pending.values()) {
            clearTimeout(request.timer);
            request.reject(Error(reason));
        }
        this.pending.clear();
    }
    request(type, payload) {
        const id = `${this.epoch}-${++this.sequence}`;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(Error('timeout'));
            }, this.timeoutMs);
            this.pending.set(id, { resolve, reject, timer });
            try {
                this.send(encode(type, payload, id));
            }
            catch (error) {
                clearTimeout(timer);
                this.pending.delete(id);
                reject(error);
            }
        });
    }
    receive(json) {
        let message;
        try {
            message = decode(json);
        }
        catch {
            return;
        }
        if (message.type === 'ui.tooltip_details') {
            if (!message.id && Object.keys(message.payload).length === 1 && typeof message.payload.alt === 'boolean')
                this.onTooltipDetails(message.payload.alt);
        }
        else if (message.type === 'ui.shortcut') {
            if (!message.id && Object.keys(message.payload).length === 1 && message.payload.key === 'Escape')
                this.onShortcut('Escape');
        }
        else if (message.type === 'command.result') {
            const result = message.payload;
            if (!message.id || !isCommandResult(result))
                return;
            const request = this.pending.get(message.id);
            if (!request)
                return; // Unknown/late results never mutate state.
            this.pending.delete(message.id);
            clearTimeout(request.timer);
            request.resolve(result);
        }
        else {
            if (!isStateMessage(message))
                return;
            this.onState(message);
        }
    }
}
export function reportInteractiveRegions(bridge, elements) {
    let frame = 0, disposed = false;
    const report = () => {
        frame = 0;
        if (disposed)
            return;
        const regions = elements.filter(element => element.getClientRects().length).map(element => {
            const rect = element.getBoundingClientRect();
            const x = Math.max(0, Math.min(innerWidth, rect.left));
            const y = Math.max(0, Math.min(innerHeight, rect.top));
            return { id: element.id, x, y, w: Math.max(0, Math.min(innerWidth, rect.right) - x), h: Math.max(0, Math.min(innerHeight, rect.bottom) - y) };
        });
        bridge.event('ui.interactive_regions', { width: innerWidth, height: innerHeight, regions });
    };
    const schedule = () => { if (!disposed && !frame)
        frame = requestAnimationFrame(report); };
    const observer = new ResizeObserver(schedule);
    elements.forEach(element => observer.observe(element));
    window.addEventListener('resize', schedule);
    window.addEventListener('scroll', schedule, true);
    schedule();
    return { refresh: schedule, dispose() { disposed = true; if (frame)
            cancelAnimationFrame(frame); frame = 0; observer.disconnect(); window.removeEventListener('resize', schedule); window.removeEventListener('scroll', schedule, true); } };
}
