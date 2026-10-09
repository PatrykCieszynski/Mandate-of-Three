import { itemTransfers } from '../game-ui/item-transfers.js';
import { mountStorage } from '../screens/storage/storage-view.js';
import { updateGameViews } from './domain-updates.js';
import type { ItemIconId } from '../game-ui/item-types.js';
import { element as findElement } from '../core/dom.js';
import { readDomainSnapshot } from '../protocol.js';
import { uiIcons } from '../core/assets/ui-icons.js';
import { ItemIconResolver } from '../content/item-icons.js';
import { applySkin } from '../core/assets/skin.js';
import { loadLegacySkin } from '../skins/legacy.js';
import { WindowManager } from '../core/window/window-manager.js';
import { WebBridge, reportInteractiveRegions } from '../bridge.js';
import { DomainStore } from '../store.js';
import { mountInventory } from '../screens/inventory/inventory-view.js';
import { mountEquipment } from '../screens/equipment/equipment-view.js';
const legacy = await loadLegacySkin();
await applySkin(document.documentElement, legacy.skin);
uiIcons.replace(legacy.uiIcons, new URL('./', import.meta.url));
const itemIcons = new ItemIconResolver(legacy.itemIcons);
export const resolveItemIcon = (id: ItemIconId) => itemIcons.resolve(id);
export const manager = new WindowManager();
manager.setViewport({ width: innerWidth, height: innerHeight }, 1);
const root = findElement(document, '#inventory', 'main'),
  storageRoot = findElement(document, '#storage', 'main'),
  equipmentRoot = findElement(document, '#equipment', 'main'),
  store = new DomainStore();
let regions: ReturnType<typeof reportInteractiveRegions> | undefined;
const bridge = new WebBridge({
  onShortcut: () => {
    if (transfers.cancel()) return;
    if (!storageRoot.hidden) {
      void bridge.request('storage.close', {}).catch(() => {});
      return;
    }
    if (!root.hidden) view.cancelOrClose();
    else if (!equipmentRoot.hidden) equipment.close();
  },
  onState(message) {
    if (!store.apply(message)) return;
    const state = readDomainSnapshot(store.state);
    if (!state) return;
    if (
      message.type === 'ui.snapshot' ||
      message.type === 'inventory.updated' ||
      message.type === 'storage.updated' ||
      message.type === 'hud.updated'
    )
      transfers.cancel();
    if (
      (message.type === 'ui.snapshot' || message.type === 'storage.updated') &&
      state.storage
    )
      storage.setState(state.storage);
    if (message.type === 'ui.snapshot' || message.type === 'hud.updated') {
      const opened = storageRoot.hidden && state.hud?.storage_open === true;
      storageRoot.hidden = !state.hud?.storage_open;
      storage.refresh();
      if (opened) {
        view.cancelCarry();
        storage.activate();
      }
      regions?.refresh();
    }
    updateGameViews(message.type, state, {
      inventory: view,
      equipment,
      inventoryRoot: root,
      equipmentRoot,
      manager,
      viewport: () => ({ width: innerWidth, height: innerHeight }),
      onRegionsChanged: () => regions?.refresh(),
    });
  },
});
const view = mountInventory(root, {
  externalCarry: () => !storageRoot.hidden,
  manager,
  resolveItemIcon,
  equipItem: (payload) => bridge.request('equipment.equip', payload),
  moveItem: (payload) => bridge.request('inventory.move_item', payload),
  onClose: () => bridge.request('inventory.close', {}).catch(() => {}),
  onRegionsChanged: () => regions?.refresh(),
});
const equipment = mountEquipment(equipmentRoot, {
  manager,
  resolveItemIcon,
  unequipItem: (payload) => bridge.request('equipment.unequip', payload),
  onClose: () => bridge.request('equipment.close', {}).catch(() => {}),
  onRegionsChanged: () => regions?.refresh(),
});
const storage = mountStorage(storageRoot, {
  manager,
  resolveItemIcon,
  onClose: () => {
    transfers.cancel();
    void bridge.request('storage.close', {}).catch(() => {});
  },
  onItemAction: () => {},
  onRegionsChanged: () => regions?.refresh(),
});
const transfers = itemTransfers({
  manager,
  resolveItemIcon,
  onRegionsChanged: () => regions?.refresh(),
  getState(id) {
    const state = readDomainSnapshot(store.state);
    const container = id === 'storage' ? state?.storage : state?.inventory;
    if (!container) throw Error('Missing item domain');
    return container;
  },
  async move(from, to, item, target) {
    try {
      const result = await bridge.request('storage.transfer', {
        id: item.id,
        revision: item.revision,
        from,
        to,
        x: target?.x ?? 0,
        y: target?.y ?? 0,
        page: target?.page ?? 0,
        quick: !target,
      });
      const status = storageRoot.querySelector('.storage-capacity');
      if (status)
        status.textContent = result.ok
          ? '135 slots per page · 2 pages'
          : `Transfer rejected: ${result.error ?? 'request'}`;
      return result.ok;
    } catch {
      const status = storageRoot.querySelector('.storage-capacity');
      if (status) status.textContent = 'Transfer failed';
      return false;
    }
  },
});
regions = reportInteractiveRegions(bridge, [
  ...view.regions,
  ...equipment.regions,
  ...storage.regions,
  ...transfers.regions,
]);
window.addEventListener('pagehide', () => {
  transfers.dispose();
  storage.dispose();
  view.dispose();
  equipment.dispose();
  regions?.dispose();
  bridge.clearPending('reload');
  manager.dispose();
});
document.addEventListener('contextmenu', (event) => event.preventDefault());
bridge.ready();
