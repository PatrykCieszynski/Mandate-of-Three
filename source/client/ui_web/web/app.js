import { WebBridge } from './bridge.js';
import { DomainStore } from './store.js';
const state = new DomainStore();
const bridge = new WebBridge({ onState: message => state.apply(message) });
bridge.ready();
// Screen composition belongs to the client application. This shell has no mock UI.
