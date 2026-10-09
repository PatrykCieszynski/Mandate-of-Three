import type {CommandPayloads, CommandResult, StateMessage, EventPayloads} from './protocol/contracts.js';
interface BridgeOptions {
  send?: (message: string) => void;
  subscribe?: (callback: (message: unknown) => void) => void;
  onState?: (message: StateMessage) => void;
  onShortcut?: (key: 'Escape') => void;
  timeoutMs?: number;
}
interface PendingRequest {
  resolve: (result: CommandResult) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}
import {decode, encode, isCommandResult, isStateMessage} from './protocol.js';
export class WebBridge {
  pending = new Map<string, PendingRequest>();
  declare send: (message: string) => void;
  declare onState: (message: StateMessage) => void;
  declare onShortcut: (key: 'Escape') => void;
  declare timeoutMs: number;
  sequence = 0;
  epoch = globalThis.crypto?.randomUUID?.() ?? String(Date.now());
  constructor({send = message => window.sendIpcMessage(message), subscribe = callback => window.ipcMessage.addListener(callback), onState = () => {}, onShortcut = () => {}, timeoutMs = 3000}: BridgeOptions = {}) {
    this.send = send;
    this.onState = onState;
    this.onShortcut = onShortcut;
    this.timeoutMs = timeoutMs;
    subscribe(message => this.receive(message));
  }
  event(type: 'ui.ready', payload?: EventPayloads['ui.ready']): void;
  event(type: 'ui.interactive_regions', payload: EventPayloads['ui.interactive_regions']): void;
  event(type: keyof EventPayloads, payload: EventPayloads[keyof EventPayloads] = {}) { this.send(encode(type, payload)); }
  ready() {
    this.clearPending('reload');
    this.event('ui.ready');
  }
  clearPending(reason: string) {
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(Error(reason));
    }
    this.pending.clear();
  }
  request<K extends keyof CommandPayloads>(type: K, payload: CommandPayloads[K]): Promise<CommandResult> {
    const id = `${this.epoch}-${++this.sequence}`;
    return new Promise<CommandResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(Error('timeout'));
      }, this.timeoutMs);
      this.pending.set(id, {resolve, reject, timer});
      try { this.send(encode(type, payload, id)); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  receive(json: unknown) {
    let message;
    try { message = decode(json); } catch { return; }
    if (message.type === 'ui.shortcut') {
      if (!message.id && Object.keys(message.payload).length === 1 && message.payload.key === 'Escape') this.onShortcut('Escape');
    } else if (message.type === 'command.result') {
      const result = message.payload;
      if (!message.id || !isCommandResult(result)) return;
      const request = this.pending.get(message.id);
      if (!request) return; // Unknown/late results never mutate state.
      this.pending.delete(message.id);
      clearTimeout(request.timer);
      request.resolve(result);
    } else {
      if (!isStateMessage(message)) return;
      this.onState(message);
    }
  }
}
export function reportInteractiveRegions(bridge: Pick<WebBridge, 'event'>, elements: HTMLElement[]) {
  let frame = 0, disposed = false;
  const report = () => {
    frame = 0;
    if (disposed) return;
    const regions = elements.filter(element => element.getClientRects().length).map(element => {
      const rect = element.getBoundingClientRect();
      const x = Math.max(0, Math.min(innerWidth, rect.left));
      const y = Math.max(0, Math.min(innerHeight, rect.top));
      return {id: element.id, x, y, w: Math.max(0, Math.min(innerWidth, rect.right) - x), h: Math.max(0, Math.min(innerHeight, rect.bottom) - y)};
    });
    bridge.event('ui.interactive_regions', {width: innerWidth, height: innerHeight, regions});
  };
  const schedule = () => { if (!disposed && !frame) frame = requestAnimationFrame(report); };
  const observer = new ResizeObserver(schedule);
  elements.forEach(element => observer.observe(element));
  window.addEventListener('resize', schedule);
  window.addEventListener('scroll', schedule, true);
  schedule();
  return {refresh: schedule, dispose() { disposed = true; if (frame) cancelAnimationFrame(frame); frame = 0; observer.disconnect(); window.removeEventListener('resize', schedule); window.removeEventListener('scroll', schedule, true); }};
}
