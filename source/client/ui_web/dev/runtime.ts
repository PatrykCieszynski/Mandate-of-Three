// Development-only native stand-in. Production bridge/store/views are unchanged.
import { decode, encode } from '../web/protocol.js';
import type { DomainSnapshot, StateType } from '../web/protocol/contracts.js';
import type { PreviewAction } from './contracts.js';
const receivers: ((raw: unknown) => void)[] = [];
let accept = false;
function fixture(): DomainSnapshot {
  return {
    hud: { inventory_open: true, equipment_open: true, ui_scale: 1 },
    wallet: { balance: 12345, ready: true },
    inventory: {
      columns: 5,
      rows: 9,
      pages: 4,
      items: [
        {
          id: 'preview-sword',
          revision: 1,
          name: 'Iron sword',
          icon_id: 'iron_sword',
          height: 3,
          quantity: 1,
          x: 0,
          y: 0,
          page: 0,
          description: 'Development fixture: three-cell footprint.',
        },
        {
          id: 'preview-material',
          revision: 1,
          name: 'Material',
          icon_id: 'material',
          height: 1,
          quantity: 12,
          x: 2,
          y: 0,
          page: 0,
          description: 'Development fixture: stack.',
        },
        {
          id: 'preview-armor',
          revision: 1,
          name: 'Armor',
          icon_id: 'armor',
          height: 2,
          quantity: 1,
          x: 3,
          y: 2,
          page: 0,
        },
        {
          id: 'preview-page-two',
          revision: 1,
          name: 'Page II material',
          icon_id: 'material',
          height: 1,
          quantity: 3,
          x: 1,
          y: 1,
          page: 1,
        },
      ],
    },
    equipment: {
      items: [
        {
          id: 'preview-equipped',
          revision: 1,
          name: 'Equipped sword',
          icon_id: 'iron_sword',
          height: 3,
          quantity: 1,
          slot: 'weapon',
        },
      ],
      stats: { attack: 10 },
    },
  };
}
let state = fixture();
export function previewInventory() {
  return state.inventory;
}
export function updatePreviewInventory(
  items: NonNullable<DomainSnapshot['inventory']>['items'],
) {
  if (!state.inventory) return;
  state.inventory = { ...state.inventory, items };
  emit('inventory.updated', state.inventory);
}

export const notify = (detail: object) =>
  parent.postMessage(
    { source: 'mandate-ui-preview', ...detail },
    location.origin,
  );
const emit = (
  type: StateType | 'command.result' | 'ui.shortcut',
  payload: object,
  id?: string,
) => {
  const raw = encode(type, payload, id);
  for (const receiver of receivers) receiver(raw);
};
const snapshot = () => emit('ui.snapshot', state);
window.ipcMessage = { addListener: (callback) => receivers.push(callback) };
window.sendIpcMessage = (raw) => {
  const message = decode(raw);
  if (message.type === 'ui.interactive_regions') return; // Keep the command log useful.
  notify({ message });
  if (message.type === 'ui.ready') {
    queueMicrotask(() => {
      snapshot();
      notify({ ready: true });
    });
    return;
  }
  if (!message.id) return;
  queueMicrotask(() => {
    emit(
      'command.result',
      accept ? { ok: true } : { ok: false, error: 'preview_rejected' },
      message.id,
    );
    if (
      accept &&
      (message.type === 'inventory.close' || message.type === 'equipment.close')
    ) {
      state.hud = {
        ...state.hud,
        ...(message.type === 'inventory.close'
          ? { inventory_open: false }
          : { equipment_open: false }),
      };
      emit('hud.updated', state.hud);
    }
  });
};
export function decodePreviewAction(value: unknown): PreviewAction | null {
  if (value === null || typeof value !== 'object' || !('action' in value))
    return null;
  const name = value.action;
  if (name === 'reset' || name === 'empty' || name === 'escape')
    return { action: name };
  if (!('value' in value)) return null;
  if (
    (name === 'inventory' ||
      name === 'equipment' ||
      name === 'storage' ||
      name === 'accept') &&
    typeof value.value === 'boolean'
  )
    return { action: name, value: value.value };
  if (
    name === 'scale' &&
    typeof value.value === 'number' &&
    [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.5].includes(value.value)
  )
    return { action: name, value: value.value };
  if (
    name === 'wallet' &&
    typeof value.value === 'number' &&
    Number.isSafeInteger(value.value) &&
    value.value >= 0 &&
    value.value <= 9000000000000000
  )
    return { action: name, value: value.value };
  return null;
}
window.addEventListener('message', (event) => {
  if (event.source !== parent || event.origin !== location.origin) return;
  const request = decodePreviewAction(event.data);
  if (!request) return;
  switch (request.action) {
    case 'reset':
      state = fixture();
      snapshot();
      break;
    case 'empty':
      state = {
        ...state,
        inventory: { columns: 5, rows: 9, pages: 4, items: [] },
        equipment: { items: [], stats: { attack: 0 } },
      };
      snapshot();
      break;
    case 'inventory':
      state.hud = { ...state.hud, inventory_open: request.value };
      emit('hud.updated', state.hud);
      break;
    case 'equipment':
      state.hud = { ...state.hud, equipment_open: request.value };
      emit('hud.updated', state.hud);
      break;
    case 'scale':
      state.hud = { ...state.hud, ui_scale: request.value };
      emit('hud.updated', state.hud);
      break;
    case 'wallet':
      state.wallet = { balance: request.value, ready: true };
      emit('wallet.updated', state.wallet);
      break;
    case 'storage':
      break; // Handled by the development Storage composition.
    case 'accept':
      accept = request.value;
      break;
    case 'escape':
      emit('ui.shortcut', { key: 'Escape' });
      break;
  }
});
