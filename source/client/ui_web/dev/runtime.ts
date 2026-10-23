import { statsFixture } from './stats-fixture.js';
import {
  chatFixture,
  chatCommand,
  receiveChatFixture,
} from './chat-fixture.js';
import {
  STORAGE_COLUMNS,
  STORAGE_ROWS,
  STORAGE_PAGES,
} from '../web/screens/storage/storage-model.js';
import type { MoveItemCommand } from '../web/protocol/contracts.js';
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
const hotbarFixture =
  (): import('../web/inventory/hotbar-model.js').HotbarSnapshot => ({
    slots: Array.from({ length: 16 }, (_, i) =>
      i === 0
        ? {
            id: 'preview-use',
            name: 'Potion (preview)',
            icon_id: 'red_potion',
            quantity: 12,
            available: true,
          }
        : {},
    ),
    vitals: {
      ready: true,
      hp: 340,
      max_hp: 360,
      mp: 65,
      max_mp: 80,
      level: '7',
    },
    ready: true,
    busy: false,
    error: '',
  });
function storageFixture(): StorageSnapshot {
  return {
    columns: STORAGE_COLUMNS,
    rows: STORAGE_ROWS,
    pages: STORAGE_PAGES,
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
    vendor: {
      active: false,
      ready: true,
      busy: false,
      quoting: false,
      pending: false,
      items: [],
      quote: {},
      error: '',
      outcome: '',
    },
    hotbar: hotbarFixture(),
    stats: statsFixture(),
    chat: chatFixture(),
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
          id: 'preview-use',
          primary_action: 'USE',
          revision: 1,
          name: 'Potion (preview)',
          icon_id: 'red_potion',
          height: 1,
          quantity: 12,
          x: 4,
          y: 0,
          page: 0,
        },
        {
          id: 'preview-sword',
          primary_action: 'EQUIP',
          revision: 1,
          name: 'Iron sword',
          icon_id: 'iron_sword',
          height: 3,
          quantity: 1,
          x: 0,
          y: 0,
          page: 0,
          description: 'A well-balanced blade, forged for a steady hand.',
          tooltip: {
            category: 'One-handed sword',
            properties: ['Attack: 24–32'],
            requirements: ['Requires level 12'],
            affixes: [
              { kind: 'prefix', lines: ['+15 Strength'] },
              { kind: 'prefix', lines: ['+120 maximum health'] },
              { kind: 'prefix', lines: ['+18% physical damage'] },
              { kind: 'suffix', lines: ['+8% attack speed'] },
              { kind: 'suffix', lines: ['+12% fire resistance'] },
              { kind: 'suffix', lines: ['+6% movement speed'] },
            ],
          },
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
          tooltip: {
            category: 'Body armour',
            properties: ['Defence: 42'],
            affixes: [
              { kind: 'prefix', lines: ['+80 maximum health'] },
              { kind: 'prefix', lines: ['+12 Defence'] },
              { kind: 'suffix', lines: ['+9% cold resistance'] },
              { kind: 'suffix', lines: ['+5% recovery rate'] },
            ],
          },
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
          tooltip: {
            category: 'One-handed sword',
            properties: ['Attack: 18–24'],
            affixes: [
              { kind: 'prefix', lines: ['+8 Strength'] },
              { kind: 'suffix', lines: ['+5% attack speed'] },
            ],
          },
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
  type: StateType | 'command.result' | 'ui.shortcut' | 'ui.tooltip_details',
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
    if (message.type.startsWith('vendor.') && state.vendor) {
      const v = state.vendor,
        p = message.payload;
      let result = { ok: true, error: '' };
      if (message.type === 'vendor.open') v.active = true;
      if (message.type === 'vendor.close') v.active = false;
      if (
        message.type === 'vendor.edit' &&
        typeof p.id === 'string' &&
        typeof p.amount === 'number'
      ) {
        const item = state.inventory?.items.find((i) => i.id === p.id);
        if (
          item &&
          Number.isInteger(p.amount) &&
          p.amount >= 0 &&
          p.amount <= item.quantity
        ) {
          v.items = v.items.filter((i) => i.id !== p.id);
          if (p.amount > 0)
            v.items.push({
              ...item,
              quantity: p.amount,
              maximum: Math.min(200, item.quantity),
              available: true,
            });
          const books = v.items.filter((i) =>
            i.id.startsWith('preview-book-'),
          ).length;
          // Dev-only server stand-in; production CEF never values recipes.
          v.quote = v.items.length
            ? {
                yang: String(
                  v.items
                    .filter((i) => !i.id.startsWith('preview-book-'))
                    .reduce((sum, i) => sum + i.quantity * 2, 0) +
                    (books % 5) * 10,
                ),
                rewards:
                  books >= 5
                    ? [
                        {
                          type: 'random_pool',
                          pool: 'random_skill_book',
                          quantity: 1,
                          icon_id: 'mystery_skill_book',
                        },
                      ]
                    : [],
                expires_at: Math.floor(Date.now() / 1000) + 30,
              }
            : {};
        } else result = { ok: false, error: 'request' };
      }
      if (message.type === 'vendor.refresh' && v.items.length === 0)
        result = { ok: false, error: 'unavailable' };
      if (
        message.type === 'vendor.confirm' ||
        message.type === 'vendor.recover'
      )
        result = { ok: false, error: 'preview_native_only' };
      emit('vendor.updated', v);
      emit('command.result', result, message.id);
      return;
    }
    if (message.type === 'hud.action') {
      const action = message.payload.action;
      if (action === 'inventory') {
        const open = !state.hud?.inventory_open;
        state.hud = {
          ...state.hud,
          inventory_open: open,
          equipment_open: open,
          ...(!open ? { storage_open: false } : {}),
        };
        emit('hud.updated', state.hud);
      }
      if (action === 'stats' && state.stats) {
        state.stats.opened = !state.stats.opened;
        emit('stats.updated', state.stats);
      }
      emit(
        'command.result',
        action === 'options'
          ? { ok: false, error: 'preview_native_only' }
          : { ok: true },
        message.id,
      );
      return;
    }
    if (message.type.startsWith('hotbar.') && state.hotbar) {
      const index = message.payload.slot;
      let result = { ok: false, error: 'unavailable' };
      if (
        typeof index === 'number' &&
        Number.isInteger(index) &&
        index >= 0 &&
        index < 16
      ) {
        if (message.type === 'hotbar.assign') {
          const item = state.inventory?.items.find(
            (item) => item.id === message.payload.id,
          );
          if (item?.primary_action === 'USE') {
            state.hotbar.slots[index] = {
              id: item.id,
              name: item.name,
              icon_id: item.icon_id,
              quantity: item.quantity,
              available: true,
            };
            result = { ok: true, error: '' };
          }
        }
        if (message.type === 'hotbar.clear') {
          state.hotbar.slots[index] = {};
          result = { ok: true, error: '' };
        }
        if (message.type === 'hotbar.activate') {
          const item = state.inventory?.items.find(
            (item) => item.id === state.hotbar!.slots[index]?.id,
          );
          result = {
            ok: false,
            error:
              item?.primary_action === 'USE'
                ? 'preview_native_only'
                : 'no_action',
          };
        }
      }
      emit('hotbar.updated', state.hotbar);
      emit('command.result', result, message.id);
      return;
    }
    if (message.type.startsWith('stats.') && state.stats) {
      if (message.type === 'stats.close') state.stats.opened = false;
      if (
        message.type === 'stats.spend' &&
        accept &&
        state.stats.data &&
        ['STR', 'DEX', 'VIT', 'INT'].includes(String(message.payload.attribute))
      ) {
        const data = state.stats.data,
          attribute = message.payload.attribute as keyof typeof data.attributes;
        if (BigInt(data.available_points) > 0n) {
          data.available_points = String(BigInt(data.available_points) - 1n);
          data.attributes[attribute] = String(
            BigInt(data.attributes[attribute]) + 1n,
          );
        }
      }
      emit('stats.updated', state.stats);
      emit(
        'command.result',
        message.type !== 'stats.spend' || accept
          ? { ok: true }
          : { ok: false, error: 'preview_rejected' },
        message.id,
      );
      return;
    }
    if (message.type.startsWith('chat.') && state.chat) {
      const result = chatCommand(state.chat, message.type, message.payload);
      emit('chat.updated', state.chat);
      emit('command.result', result, message.id);
      return;
    }
    if (
      message.type === 'inventory.move_item' &&
      state.hud?.storage_open &&
      state.inventory
    ) {
      const p = message.payload;
      const result = isMove(p)
        ? transfer(state.inventory, state.inventory, p.id, p.revision, {
            x: p.x,
            y: p.y,
            page: p.page,
          })
        : null;
      if (result) {
        state.inventory = {
          ...state.inventory,
          items: result.destinationItems,
        };
        emit('inventory.updated', state.inventory);
      }
      emit(
        'command.result',
        result ? { ok: true } : { ok: false, error: 'occupied_or_full' },
        message.id,
      );
      return;
    }
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
          ? { inventory_open: false, storage_open: false }
          : { equipment_open: false }),
      };
      emit('hud.updated', state.hud);
    }
  });
};
function isMove(p: unknown): p is MoveItemCommand {
  return (
    isObject(p) &&
    Object.keys(p).length === 5 &&
    typeof p.id === 'string' &&
    typeof p.revision === 'number' &&
    Number.isSafeInteger(p.revision) &&
    p.revision >= 0 &&
    typeof p.x === 'number' &&
    Number.isSafeInteger(p.x) &&
    p.x >= 0 &&
    p.x < 5 &&
    typeof p.y === 'number' &&
    Number.isSafeInteger(p.y) &&
    p.y >= 0 &&
    p.y < 9 &&
    typeof p.page === 'number' &&
    Number.isSafeInteger(p.page) &&
    p.page >= 0 &&
    p.page < 4
  );
}
function isTransfer(p: unknown): p is StorageTransferCommand {
  return (
    isObject(p) &&
    typeof p.id === 'string' &&
    typeof p.revision === 'number' &&
    Number.isSafeInteger(p.revision) &&
    p.revision >= 0 &&
    (p.from === 'inventory' || p.from === 'storage') &&
    (p.to === 'inventory' || p.to === 'storage') &&
    !(p.from === 'inventory' && p.to === 'inventory') &&
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
  if (
    name === 'reset' ||
    name === 'empty' ||
    name === 'escape' ||
    name === 'chat-message' ||
    name === 'whisper-message'
  )
    return { action: name };
  if (!('value' in value)) return null;
  if (
    (name === 'stats' ||
      name === 'inventory' ||
      name === 'equipment' ||
      name === 'vendor' ||
      name === 'hotbar' ||
      name === 'storage' ||
      name === 'accept' ||
      name === 'tooltip-details') &&
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
    case 'chat-message':
    case 'whisper-message':
      if (state.chat) {
        receiveChatFixture(state.chat, request.action === 'whisper-message');
        emit('chat.updated', state.chat);
      }
      break;
    case 'reset':
      state = fixture();
      snapshot();
      break;
    case 'empty':
      state = {
        ...state,
        inventory: { columns: 5, rows: 9, pages: 4, items: [] },
        storage: {
          columns: STORAGE_COLUMNS,
          rows: STORAGE_ROWS,
          pages: STORAGE_PAGES,
          items: [],
        },
        equipment: { items: [], stats: { attack: 0 } },
      };
      snapshot();
      break;
    case 'stats':
      if (state.stats) {
        state.stats.opened = request.value;
        emit('stats.updated', state.stats);
      }
      break;
    case 'inventory':
      state.hud = {
        ...state.hud,
        inventory_open: request.value,
        ...(!request.value ? { storage_open: false } : {}),
      };
      emit('hud.updated', state.hud);
      break;
    case 'equipment':
      state.hud = { ...state.hud, equipment_open: request.value };
      emit('hud.updated', state.hud);
      break;

    case 'vendor':
      state.vendor!.active = request.value;
      state.hud = { ...state.hud, inventory_open: true };
      emit('hud.updated', state.hud);
      if (request.value && state.inventory) {
        state.inventory.items = state.inventory.items.filter(
          (i) => !i.id.startsWith('preview-book-'),
        );
        for (let i = 0; i < 5; i++)
          state.inventory.items.push({
            id: `preview-book-${i}`,
            revision: 0,
            name: `Skill Book ${i + 1}`,
            icon_id: 'skill_book',
            height: 1,
            quantity: 1,
            x: i,
            y: 4,
            page: 0,
          });
        emit('inventory.updated', state.inventory);
      }
      emit('vendor.updated', state.vendor!);
      return;
    case 'hotbar':
      state.hotbar = hotbarFixture();
      if (!request.value)
        state.hotbar.slots = Array.from({ length: 16 }, () => ({}));
      emit('hotbar.updated', state.hotbar);
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
      state.hud = {
        ...state.hud,
        storage_open: request.value,
        ...(request.value ? { inventory_open: true } : {}),
      };
      emit('hud.updated', state.hud);
      break;
    case 'tooltip-details':
      emit('ui.tooltip_details', { alt: request.value });
      break;
    case 'accept':
      accept = request.value;
      break;
    case 'escape':
      emit('ui.shortcut', { key: 'Escape' });
      break;
  }
});
