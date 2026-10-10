import { ItemDragRuntime } from '../game-ui/drag/item-drag-runtime.js';
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
    if (drag.cancel()) return;
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
      message.type === 'equipment.updated' ||
      message.type === 'hud.updated'
    )
      drag.cancel();
    if (
      (message.type === 'ui.snapshot' || message.type === 'storage.updated') &&
      state.storage
    )
      storage.setState(state.storage);
    if (message.type === 'ui.snapshot' || message.type === 'hud.updated') {
      const opened = storageRoot.hidden && state.hud?.storage_open === true;
      storageRoot.hidden = !(
        state.hud?.storage_open && state.hud?.inventory_open
      );
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
const drag = new ItemDragRuntime({
  scale: () => manager.scale,
  onRegionsChanged: () => regions?.refresh(),
});
const view = mountInventory(root, {
  drag,
  quickDeposit: (item) =>
    storage.tryQuickDeposit(item),
  withdrawItem: (item, position) => storage.withdrawToInventory(item, position),
  receiveEquipped: (item, position) => equipment.unequip(item, position),
  manager,
  resolveItemIcon,
  activateItem: (payload) => bridge.request('item.activate', payload),
  moveItem: (payload) => bridge.request('inventory.move_item', payload),
  onClose: () => bridge.request('inventory.close', {}).catch(() => {}),
  onRegionsChanged: () => regions?.refresh(),
});
const equipment = mountEquipment(equipmentRoot, {
  drag,
  equipItem: (payload) => bridge.request('equipment.equip', payload),
  manager,
  resolveItemIcon,
  unequipItem: (payload) => bridge.request('equipment.unequip', payload),
  onClose: () => bridge.request('equipment.close', {}).catch(() => {}),
  onRegionsChanged: () => regions?.refresh(),
});
const storage = mountStorage(storageRoot, {
  drag,
  transfer: (payload) => bridge.request('storage.transfer', payload),
  manager,
  resolveItemIcon,
  onClose: () => {
    drag.cancel();
    void bridge.request('storage.close', {}).catch(() => {});
  },
  onRegionsChanged: () => regions?.refresh(),
});
regions = reportInteractiveRegions(bridge, [
  ...view.regions,
  ...equipment.regions,
  ...storage.regions,
  ...drag.regions,
]);
window.addEventListener('pagehide', () => {
  drag.dispose();
  storage.dispose();
  view.dispose();
  equipment.dispose();
  regions?.dispose();
  bridge.clearPending('reload');
  manager.dispose();
});
document.addEventListener('contextmenu', (event) => event.preventDefault());
bridge.ready();
