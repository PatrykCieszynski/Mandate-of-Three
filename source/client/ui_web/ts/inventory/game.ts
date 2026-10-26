import { CRAFT_CURRENCIES, mountCraft } from '../screens/craft/craft-view.js';
import { mountTrade } from '../screens/trade/trade-view.js';
import { QuickItemTargets } from './quick-item-targets.js';
import { mountVendor } from '../screens/vendor/vendor-view.js';
import { mountStats } from '../screens/stats/stats-view.js';
import { mountChat } from '../screens/chat/chat-view.js';
import { mountBottomHud } from './bottom-hud.js';
import { mountParty } from '../screens/party/party-view.js';
import { mountExchange } from '../screens/market/exchange-view.js';
import { mountMarketBrowser } from '../screens/market/browser-view.js';
import { mountMarket } from '../screens/market/market-view.js';
import { mountNpcWorldDrop } from '../screens/upgrade/npc-world-drop.js';
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
import {
  WebBridge,
  reportInteractiveRegions,
  reportTextFocus,
} from '../bridge.js';
import { DomainStore } from '../store.js';
import { mountInventory } from '../screens/inventory/inventory-view.js';
import { mountEquipment } from '../screens/equipment/equipment-view.js';
const legacy = await loadLegacySkin();
await applySkin(document.documentElement, legacy.skin);
uiIcons.replace(legacy.uiIcons, new URL('./', import.meta.url));
const itemIcons = new ItemIconResolver({
  ...legacy.itemIcons,
  cleansing_salt: new URL('../content/cleansing_salt.svg', import.meta.url)
    .href,
  awakening_seal: new URL('../content/awakening_seal.svg', import.meta.url)
    .href,
  ascension_ember: new URL('../content/ascension_ember.svg', import.meta.url)
    .href,
  renewal_prism: new URL('../content/renewal_prism.svg', import.meta.url).href,
  change_spark: new URL('../content/change_spark.svg', import.meta.url).href,
  renewal_dust: new URL('../content/renewal_dust.svg', import.meta.url).href,
  completion_shard: new URL('../content/completion_shard.svg', import.meta.url)
    .href,
  upgrade_ore: new URL('../content/upgrade_ore.svg', import.meta.url).href,
});
export const resolveItemIcon = (id: ItemIconId) => itemIcons.resolve(id);
export const manager = new WindowManager();
manager.setViewport({ width: innerWidth, height: innerHeight }, 1);
const root = findElement(document, '#inventory', 'main'),
  storageRoot = findElement(document, '#storage', 'main'),
  equipmentRoot = findElement(document, '#equipment', 'main'),
  shopRoot = findElement(document, '#shop', 'main'),
  vendorRoot = findElement(document, '#vendor', 'main'),
  exchangeRoot = findElement(document, '#exchange', 'main'),
  marketBrowserRoot = findElement(document, '#market-browser', 'main'),
  marketVisitorRoot = findElement(document, '#market-visitor', 'main'),
  marketRoot = findElement(document, '#market', 'main'),
  upgradeRoot = findElement(document, '#upgrade', 'main'),
  npcRoot = findElement(document, '#npc-menu', 'main'),
  npcServiceRoot = findElement(document, '#npc-service', 'main'),
  store = new DomainStore();
let regions: ReturnType<typeof reportInteractiveRegions> | undefined;
const bridge = new WebBridge({
  onTooltipDetails: (alt) => setItemTooltipDetails(document, alt, 'native'),
  onShortcut: (key) => {
    if (key === 'Enter') {
      chat.focus();
      return;
    }
    if (craft.cancel()) return;
    if (chat.escape()) return;
    if (drag.cancel()) return;
    if (
      (manager.activeWindowId === 'stats' && stats.closeIfActive()) ||
      exchange.closeIfActive() ||
      marketBrowser.closeIfActive() ||
      market.closeIfActive() ||
      craft.cancel() ||
      upgrade.closeIfActive() ||
      npc.closeIfActive()
    )
      return;
    if (!storageRoot.hidden) {
      void bridge.request('storage.close', {}).catch(() => {});
      return;
    }
    if (!root.hidden) view.cancelOrClose();
    else if (!equipmentRoot.hidden) equipment.close();
    else stats.closeIfActive();
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
      message.type === 'upgrade.updated' ||
      message.type === 'vendor.updated' ||
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
    if (message.type === 'ui.snapshot' || message.type === 'exchange.updated')
      exchange.setState(state.exchange ?? { active: false });
    if (
      message.type === 'ui.snapshot' ||
      message.type === 'market_browser.updated'
    )
      marketBrowser.setState(state.market_browser ?? { active: false });
    if (message.type === 'ui.snapshot' || message.type === 'market.updated')
      market.setState(state.market ?? { active: false });
    if (
      (message.type === 'ui.snapshot' ||
        message.type === 'inventory.updated') &&
      state.inventory
    )
      market.setInventory(state.inventory);
    if (message.type === 'ui.snapshot' || message.type === 'wallet.updated')
      market.setWallet(state.wallet ?? {});
    if (
      (message.type === 'ui.snapshot' || message.type === 'craft.updated') &&
      state.craft
    )
      craft.setState(state.craft);
    updateGameViews(message.type, state, {
      inventory: view,
      equipment,
      inventoryRoot: root,
      equipmentRoot,
      manager,
      viewport: () => ({ width: innerWidth, height: innerHeight }),
      onRegionsChanged: () => regions?.refresh(),
    });
    if (root.hidden) craft.cancel();
    craft.refreshTargets();
    if (
      (message.type === 'ui.snapshot' || message.type === 'hotbar.updated') &&
      state.hotbar
    )
      bottomHud.render(state.hotbar);
    if (message.type === 'ui.snapshot' || message.type === 'hud.updated') {
      bottomHud.setScale(manager.scale);
    }
    if (
      (message.type === 'ui.snapshot' || message.type === 'trade.updated') &&
      state.trade
    )
      trade.setState(state.trade);
    if (
      (message.type === 'ui.snapshot' || message.type === 'party.updated') &&
      state.party
    )
      party.setState(state.party);
    if (
      (message.type === 'ui.snapshot' || message.type === 'chat.updated') &&
      state.chat
    )
      chat.setState(state.chat);
    if (
      (message.type === 'ui.snapshot' || message.type === 'stats.updated') &&
      state.stats
    )
      stats.setState(state.stats);
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
    if (message.type === 'ui.snapshot' || message.type === 'upgrade.updated')
      upgrade.setState(state.upgrade ?? { active: false });
    if (message.type === 'ui.snapshot' || message.type === 'wallet.updated')
      upgrade.setWallet(state.wallet ?? {});
    if (
      message.type === 'ui.snapshot' ||
      message.type === 'npc_targets.updated'
    )
      worldDrop.setState(
        state.npc_targets ?? { width: 0, height: 0, targets: [] },
      );
    if (message.type === 'ui.snapshot' || message.type === 'shop.updated')
      shop.setState(state.shop ?? { active: false });
    if (
      (message.type === 'ui.snapshot' || message.type === 'vendor.updated') &&
      state.vendor
    )
      vendor.setState(state.vendor);
    quickTargets.sync();
  },
});
const drag = new ItemDragRuntime({
  scale: () => manager.scale,
  onRegionsChanged: () => {
    worldDrop?.setCarrying(drag.active);
    regions?.refresh();
  },
});
const bottomHud = mountBottomHud(
  findElement(document, '#bottom-hud', 'aside'),
  {
    drag,
    resolveItemIcon,
    assign: (slot, id) => bridge.request('hotbar.assign', { slot, id }),
    clear: (slot) => bridge.request('hotbar.clear', { slot }),
    activate: (slot) => bridge.request('hotbar.activate', { slot }),
    system: (action) => bridge.request('hud.action', { action }),
    regions: () => regions?.refresh(),
  },
);
bottomHud.setScale(manager.scale);
const worldDrop = mountNpcWorldDrop(
  drag,
  (npc, service, item) =>
    bridge.request('npc.upgrade_item', {
      npc_instance_id: npc,
      service_id: service,
      ...item,
    }),
  () => regions?.refresh(),
);
const view = mountInventory(root, {
  blockCarry: () => craft.engaged(),
  retry: () => bridge.request('inventory.retry', {}),
  drag,
  quickTransfer: (item) => quickTargets.receive(item),
  withdrawItem: (item, position) => storage.withdrawToInventory(item, position),
  buyShopOffer: (subject, position) => shop.buyOffer(subject, position),
  receiveEquipped: (item, position) => equipment.unequip(item, position),
  manager,
  resolveItemIcon,
  activateItem: (payload) => {
    const selected = readDomainSnapshot(store.state)?.inventory?.items.find(
      (i) => i.id === payload.id,
    );
    if (CRAFT_CURRENCIES.includes(selected?.definition_id ?? '')) {
      drag.cancel();
      return bridge.request('item.activate', payload);
    }
    if (!marketRoot.hidden) return market.selectInventory(payload);
    if (!upgradeRoot.hidden) return upgrade.selectItem(payload);
    return bridge.request('item.activate', payload);
  },
  moveItem: (payload) => bridge.request('inventory.move_item', payload),
  onClose: () => bridge.request('inventory.close', {}).catch(() => {}),
  onRegionsChanged: () => regions?.refresh(),
});
const craft = mountCraft(root, {
  storageRoot,
  resolveItemIcon,
  execute: (p) => bridge.request('craft.execute', p),
  retry: () => bridge.request('craft.retry', {}),
  close: () => {
    void bridge.request('craft.close', {}).catch(() => {});
  },
  cancelCarry: () => drag.cancel(),
  regions: () => regions?.refresh(),
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
  retry: () => bridge.request('storage.retry', {}),
  manager,
  resolveItemIcon,
  onClose: () => {
    drag.cancel();
    void bridge.request('storage.close', {}).catch(() => {});
  },
  onRegionsChanged: () => regions?.refresh(),
});
const vendor = mountVendor(vendorRoot, {
  manager,
  drag,
  resolveItemIcon,
  command: (action, payload) =>
    bridge.request(`vendor.${action}`, payload as never),
  close: () => {
    drag.cancel();
    void bridge.request('vendor.close', {}).catch(() => {});
  },
  regions: () => regions?.refresh(),
});
const shop = mountShop(shopRoot, {
  manager,
  drag,
  resolveItemIcon,
  buy: (payload) => bridge.request('shop.buy', payload),
  sell: () => {
    void bridge.request('vendor.open', {}).catch(() => {});
  },
  retry: () => bridge.request('shop.retry', {}),
  dismissRecovery: () => {
    void bridge.request('shop.dismiss_recovery', {}).catch(() => {});
  },
  onClose: () => {
    drag.cancel();
    npc.closeIfActive();
  },
  onRegionsChanged: () => regions?.refresh(),
});
const exchangeTypes = {
  deposit: 'exchange.deposit',
  withdraw: 'exchange.withdraw',
  order: 'exchange.order',
  cancel_order: 'exchange.cancel_order',
} as const;
const exchange = mountExchange(exchangeRoot, {
  manager,
  drag,
  command: (action, p) => bridge.request(exchangeTypes[action], p),
  retry: () => bridge.request('exchange.retry', {}),
  close: () => {
    void bridge.request('exchange.close', {});
  },
  regions: () => regions?.refresh(),
});
const marketBrowser = mountMarketBrowser(marketBrowserRoot, marketVisitorRoot, {
  manager,
  resolveItemIcon,
  catalog: (query) => bridge.request('market.browser.catalog', { query }),
  search: (p) => bridge.request('market.browser.search', p),
  visit: (shop_id, offer_id) =>
    bridge.request('market.browser.visit', { shop_id, offer_id }),
  buy: (p) => bridge.request('market.buy', p),
  retryPurchase: () => bridge.request('market.retry_seller', {}),
  close: () => {
    void bridge.request('market.browser.close', {});
  },
  regions: () => regions?.refresh(),
});
const market = mountMarket(marketRoot, {
  manager,
  drag,
  resolveItemIcon,
  command: (action, payload) => bridge.request(`market.${action}`, payload),
  retrySeller: () => bridge.request('market.retry_seller', {}),
  collectRevenue: (retry) =>
    bridge.request(
      retry ? 'market.retry_revenue' : 'market.collect_revenue',
      {},
    ),
  onClose: () => {
    drag.cancel();
    void bridge.request('market.close', {}).catch(() => {});
  },
  onRegionsChanged: () => regions?.refresh(),
});
const stats = mountStats(findElement(document, '#stats', 'main'), {
  manager,
  spend: (attribute) => bridge.request('stats.spend', { attribute }),
  retry: () => bridge.request('stats.retry', {}),
  refresh: () => bridge.request('stats.refresh', {}),
  close: () => {
    void bridge.request('stats.close', {}).catch(() => {});
  },
  regions: () => regions?.refresh(),
});
const trade = mountTrade(findElement(document, '#trade', 'main'), {
  manager,
  drag,
  resolveItemIcon,
  command: (p) => bridge.request('trade.command', p),
  close: () => {
    void bridge.request('trade.close', {});
  },
  regions: () => regions?.refresh(),
});
const party = mountParty(findElement(document, '#party', 'main'), {
  manager,
  command: (p) => bridge.request('party.command', p),
  close: () => {
    void bridge.request('party.close', {});
  },
  regions: () => regions?.refresh(),
});
const chat = mountChat(findElement(document, '#chat', 'main'), {
  manager,
  command: (type, p) => bridge.request(type, p),
  regions: () => regions?.refresh(),
});
const textFocus = reportTextFocus(bridge);
const upgrade = mountUpgrade(upgradeRoot, {
  select: (payload) => bridge.request('upgrade.select', payload),
  execute: (payload) => bridge.request('upgrade.execute', payload),
  retry: () => bridge.request('upgrade.retry', {}),
  dismissRecovery: () => {
    void bridge.request('upgrade.dismiss_recovery', {}).catch(() => {});
  },
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
const quickTargets = new QuickItemTargets([
  { root: storageRoot, receive: (item) => storage.tryQuickDeposit(item) },
  { root: upgradeRoot, receive: (item) => upgrade.selectItem(item) },
  { root: marketRoot, receive: (item) => market.selectInventory(item) },
  {
    root: findElement(document, '#trade', 'main'),
    receive: (item) => trade.offerItem(item),
  },
  { root: vendorRoot, receive: (item) => vendor.offerItem(item) },
]);
regions = reportInteractiveRegions(
  bridge,
  [
    ...bottomHud.regions,
    ...trade.regions,
    ...party.regions,
    ...worldDrop.regions,
    ...shop.regions,
    ...vendor.regions,
    ...exchange.regions,
    ...marketBrowser.regions,
    ...market.regions,
    ...craft.regions,
    ...upgrade.regions,
    ...npc.regions,
    ...view.regions,
    ...equipment.regions,
    ...storage.regions,
    ...drag.regions,
  ],
  () => chat.regions,
);
window.addEventListener('pagehide', () => {
  chat.dispose();
  bottomHud.dispose();
  party.dispose();
  trade.dispose();
  worldDrop.dispose();
  craft.dispose();
  upgrade.dispose();
  shop.dispose();
  vendor.dispose();
  exchange.dispose();
  marketBrowser.dispose();
  market.dispose();
  textFocus.dispose();
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
    if (
      craft.cancel() ||
      drag.cancel() ||
      exchange.closeIfActive() ||
      marketBrowser.closeIfActive() ||
      market.closeIfActive() ||
      upgrade.closeIfActive() ||
      npc.closeIfActive()
    ) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  },
  true,
);
document.addEventListener('contextmenu', (event) => event.preventDefault());
bridge.ready();
