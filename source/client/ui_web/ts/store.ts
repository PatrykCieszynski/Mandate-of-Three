import type {Envelope, RawDomainState} from './contracts.js';
import {isObject, isDomainName, isRawDomainState} from './protocol.js';
export class DomainStore {
  state: RawDomainState = {};
  apply(message: Envelope): boolean {
    if (message.type === 'ui.snapshot') {
      if (!isRawDomainState(message.payload)) return false;
      this.state = structuredClone(message.payload);
      return true;
    }
    const domain = message.type.replace(/\.updated$/, '');
    if (message.type !== domain + '.updated' || !isDomainName(domain) || !isObject(message.payload)) return false;
    this.state[domain] = structuredClone(message.payload);
    return true;
  }
}
