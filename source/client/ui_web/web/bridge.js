import {decode, encode} from './protocol.js';
export class WebBridge {
  pending = new Map();
  sequence = 0;
  epoch = globalThis.crypto?.randomUUID?.() ?? String(Date.now());
  constructor({send = message => window.sendIpcMessage(message), subscribe = callback => window.ipcMessage.addListener(callback), onState = () => {}, timeoutMs = 3000} = {}) {
    this.send = send;
    this.onState = onState;
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
      this.pending.set(id, {resolve, reject, timer});
      try { this.send(encode(type, payload, id)); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  receive(json) {
    let message;
    try { message = decode(json); } catch { return; }
    if (message.type === 'command.result') {
      const result = message.payload;
      if (!message.id || typeof result.ok !== 'boolean' ||
          Object.keys(result).some(key => !['ok','error'].includes(key)) ||
          ('error' in result && typeof result.error !== 'string')) return;
      const request = this.pending.get(message.id);
      if (!request) return; // Unknown/late results never mutate state.
      this.pending.delete(message.id);
      clearTimeout(request.timer);
      request.resolve(result);
    } else {
      if (message.id || !['ui.snapshot','inventory.updated','equipment.updated','wallet.updated','player.updated','hud.updated'].includes(message.type)) return;
      this.onState(message);
    }
  }
}
export function reportInteractiveRegions(bridge, elements) {
  let scheduled = false;
  const report = () => {
    scheduled = false;
    const regions = elements.filter(element => element.getClientRects().length).map(element => {
      const rect = element.getBoundingClientRect();
      const x = Math.max(0, Math.min(innerWidth, rect.left));
      const y = Math.max(0, Math.min(innerHeight, rect.top));
      return {id: element.id, x, y, w: Math.max(0, Math.min(innerWidth, rect.right) - x), h: Math.max(0, Math.min(innerHeight, rect.bottom) - y)};
    });
    bridge.event('ui.interactive_regions', {width: innerWidth, height: innerHeight, regions});
  };
  const schedule = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(report); } };
  const observer = new ResizeObserver(schedule);
  elements.forEach(element => observer.observe(element));
  window.addEventListener('resize', schedule);
  window.addEventListener('scroll', schedule, true);
  schedule();
  return {refresh: schedule, dispose() { observer.disconnect(); window.removeEventListener('resize', schedule); window.removeEventListener('scroll', schedule, true); }};
}
