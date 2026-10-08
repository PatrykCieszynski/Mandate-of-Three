const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const domains = new Set(['inventory','equipment','wallet','player','hud']);
export class DomainStore {
  state = {};
  apply(message) {
    if (message.type === 'ui.snapshot') {
      if (Object.entries(message.payload).some(([key,value]) => !domains.has(key) || !object(value))) return false;
      this.state = structuredClone(message.payload);
      return true;
    }
    const domain = message.type.replace(/\.updated$/, '');
    if (message.type !== domain + '.updated' || !domains.has(domain) || !object(message.payload)) return false;
    this.state[domain] = structuredClone(message.payload);
    return true;
  }
}
