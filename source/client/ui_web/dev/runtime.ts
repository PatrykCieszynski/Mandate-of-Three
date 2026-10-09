import { transfer } from '../web/screens/storage/transfer.js';
import type {
  StorageSnapshot,
  StorageTransferCommand,
} from '../web/protocol/contracts.js';
import { isObject } from '../web/protocol.js';
// Development-only native stand-in. Production bridge/store/views are unchanged.
import { decode, encode } from '../web/protocol.js';
import type { DomainSnapshot, StateType } from '../web/protocol/contracts.js';
import type { PreviewAction } from './contracts.js';
const receivers: ((raw: unknown) => void)[] = [];
let accept = false;
function storageFixture(): StorageSnapshot {
  return {
    columns: 15,
    rows: 9,
    pages: 2,
    items: [
      {
        id: 'stored-sword',
        revision: 1,
        name: 'Stored iron sword',
        icon_id: 'iron_sword',
        height: 3,
        quantity: 1,
        x: 0,
        y: 0,
        page: 0,
        description: 'A tall item on Storage page I.',
      },
      {
        id: 'stored-potions',
        revision: 1,
        name: 'Stored potions',
        icon_id: 'potion',
        height: 1,
        quantity: 20,
        x: 7,
        y: 4,
        page: 0,
        description: 'A stack in the middle of page I.',
      },
      {
        id: 'stored-edge',
        revision: 1,
        name: 'Corner potion',
        icon_id: 'potion',
        height: 1,
        quantity: 2,
        x: 14,
        y: 8,
        page: 0,
      },
      {
        id: 'stored-page-two',
        revision: 1,
        name: 'Page II sword',
        icon_id: 'short_sword',
        height: 2,
        quantity: 1,
        x: 3,
        y: 2,
        page: 1,
        description: 'A two-cell item on Storage page II.',
      },
      {
        id: 'stored-page-two-stack',
        revision: 1,
        name: 'Page II potions',
        icon_id: 'potion',
        height: 1,
        quantity: 8,
        x: 14,
        y: 8,
        page: 1,
      },
    ],
  };
}

function fixture(): DomainSnapshot {
  return {
    storage: storageFixture(),
    hud: {
      storage_open: true,
      inventory_open: true,
      equipment_open: true,
      ui_scale: 1,
    },
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
    if (message.type === 'storage.transfer') {
      const p = message.payload;
      if (!isTransfer(p) || !state.inventory || !state.storage) {
        emit('command.result', { ok: false, error: 'request' }, message.id);
        return;
      }
      const source = p.from === 'inventory' ? state.inventory : state.storage;
      const destination =
        p.to === 'inventory' ? state.inventory : state.storage;
      const result = transfer(
        source,
        destination,
        p.id,
        p.revision,
        p.quick ? undefined : { x: p.x, y: p.y, page: p.page },
      );
      if (result) {
        if (p.from === 'storage' || p.to === 'storage')
          state.storage = {
            ...state.storage,
            items:
              p.to === 'storage' ? result.destinationItems : result.sourceItems,
          };
        if (p.from === 'inventory' || p.to === 'inventory')
          state.inventory = {
            ...state.inventory,
            items:
              p.to === 'inventory'
                ? result.destinationItems
                : result.sourceItems,
          };
        emit('storage.updated', state.storage);
        emit('inventory.updated', state.inventory);
      }
      emit(
        'command.result',
        result ? { ok: true } : { ok: false, error: 'occupied_or_full' },
        message.id,
      );
      return;
    }
    if (message.type === 'storage.close') {
      state.hud = { ...state.hud, storage_open: false };
      emit('hud.updated', state.hud);
      emit('command.result', { ok: true }, message.id);
      return;
    }
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
function isTransfer(p: unknown): p is StorageTransferCommand {
  return (
    isObject(p) &&
    typeof p.id === 'string' &&
    typeof p.revision === 'number' &&
    Number.isSafeInteger(p.revision) &&
    p.revision >= 0 &&
    (p.from === 'inventory' || p.from === 'storage') &&
    (p.to === 'inventory' || p.to === 'storage') &&
    typeof p.quick === 'boolean' &&
    typeof p.x === 'number' &&
    Number.isSafeInteger(p.x) &&
    typeof p.y === 'number' &&
    Number.isSafeInteger(p.y) &&
    typeof p.page === 'number' &&
    Number.isSafeInteger(p.page)
  );
}
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
        storage: { columns: 15, rows: 9, pages: 2, items: [] },
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
      state.hud = { ...state.hud, storage_open: request.value };
      emit('hud.updated', state.hud);
      break;
    case 'accept':
      accept = request.value;
      break;
    case 'escape':
      emit('ui.shortcut', { key: 'Escape' });
      break;
  }
});
