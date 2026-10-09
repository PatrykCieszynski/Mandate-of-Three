import { isDomainName, isValidDomainState, isValidDomainValue } from './protocol.js';
export class DomainStore {
    state = {};
    apply(message) {
        if (message.type === 'ui.snapshot') {
            if (!isValidDomainState(message.payload))
                return false;
            // Validate the entire replacement before changing any last known valid state.
            this.state = structuredClone(message.payload);
            return true;
        }
        const domain = message.type.replace(/\.updated$/, '');
        if (message.type !== domain + '.updated' || !isDomainName(domain) || !isValidDomainValue(domain, message.payload))
            return false;
        // Reject malformed domains independently; unrelated updates remain renderable.
        this.state[domain] = structuredClone(message.payload);
        return true;
    }
}
