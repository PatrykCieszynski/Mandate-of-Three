import { mountUpgrade } from '../screens/upgrade/upgrade-view.js';
import { setItemTooltipDetails } from '../game-ui/items/item-tooltip.js';
import { mountShop } from '../screens/shop/shop-view.js';
import { NpcServiceKind } from '../screens/npc/npc-model.js';
import { mountNpcInteraction } from '../screens/npc/npc-interaction.js';
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
  shopRoot = findElement(document, '#shop', 'main'),
  upgradeRoot = findElement(document, '#upgrade', 'main'),
  npcRoot = findElement(document, '#npc-menu', 'main'),
  npcServiceRoot = findElement(document, '#npc-service', 'main'),
  store = new DomainStore();
let regions: ReturnType<typeof reportInteractiveRegions> | undefined;
const bridge = new WebBridge({
  onTooltipDetails: (alt) => setItemTooltipDetails(document, alt, 'native'),
  onShortcut: () => {
    if (drag.cancel()) return;
    if (upgrade.closeIfActive() || npc.closeIfActive()) return;
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
      message.type === 'hud.updated' ||
      message.type === 'shop.updated' ||
      message.type === 'npc.updated'
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
    if (message.type === 'ui.snapshot' || message.type === 'npc.updated') {
      npc.setState(state.npc ?? { active: false });
      upgrade.setNpcState(state.npc ?? { active: false });
    }
    if (
      (message.type === 'ui.snapshot' ||
        message.type === 'inventory.updated') &&
      state.inventory
    )
      upgrade.setInventory(state.inventory);
    if (message.type === 'ui.snapshot' || message.type === 'shop.updated')
      shop.setState(state.shop ?? { active: false });
  },
});
const drag = new ItemDragRuntime({
  scale: () => manager.scale,
  onRegionsChanged: () => regions?.refresh(),
});
const view = mountInventory(root, {
  drag,
  quickDeposit: (item) => storage.tryQuickDeposit(item),
  withdrawItem: (item, position) => storage.withdrawToInventory(item, position),
  buyShopOffer: (subject, position) => shop.buyOffer(subject, position),
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
const shop = mountShop(shopRoot, {
  manager,
  drag,
  resolveItemIcon,
  buy: (payload) => bridge.request('shop.buy', payload),
  onClose: () => {
    drag.cancel();
    npc.closeIfActive();
  },
  onRegionsChanged: () => regions?.refresh(),
});
const upgrade = mountUpgrade(upgradeRoot, {
  manager,
  drag,
  resolveItemIcon,
  onClose: () => npc.closeIfActive(),
  onRegionsChanged: () => regions?.refresh(),
});
const npc = mountNpcInteraction(npcRoot, npcServiceRoot, {
  manager,
  handlesService: (kind) =>
    kind === NpcServiceKind.SHOP || kind === NpcServiceKind.UPGRADE,
  clearService: () => {
    void bridge.request('npc.clear_service', {}).catch(() => {});
  },
  onServiceOpened: (selection) => {
    if (selection.service.kind === NpcServiceKind.SHOP)
      void bridge
        .request('shop.open', {
          npc_instance_id: selection.npcInstanceId,
          service_id: selection.service.id,
        })
        .then((result) => {
          if (!result.ok)
            npc.serviceFailed(selection, result.error ?? 'request');
        })
        .catch(() => npc.serviceFailed(selection, 'timeout'));
  },
  selectService: (selection) =>
    bridge.request('npc.select_service', {
      npc_instance_id: selection.npcInstanceId,
      service_id: selection.service.id,
    }),
  onClose: () => {
    void bridge.request('npc.close', {}).catch(() => {});
  },
  onRegionsChanged: () => regions?.refresh(),
});
regions = reportInteractiveRegions(bridge, [
  ...shop.regions,
  ...upgrade.regions,
  ...npc.regions,
  ...view.regions,
  ...equipment.regions,
  ...storage.regions,
  ...drag.regions,
]);
window.addEventListener('pagehide', () => {
  upgrade.dispose();
  shop.dispose();
  npc.dispose();
  drag.dispose();
  storage.dispose();
  view.dispose();
  equipment.dispose();
  regions?.dispose();
  bridge.clearPending('reload');
  manager.dispose();
});
document.addEventListener(
  'keydown',
  (event) => {
    if (event.key !== 'Escape' || event.repeat) return;
    if (drag.cancel() || upgrade.closeIfActive() || npc.closeIfActive()) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  },
  true,
);
document.addEventListener('contextmenu', (event) => event.preventDefault());
bridge.ready();
