// Standalone development preview. The game entry never imports this module.
import { mountUpgrade } from '../screens/upgrade/upgrade-view.js';
import { WindowManager } from '../core/window/window-manager.js';
import { ItemDragRuntime } from '../game-ui/drag/item-drag-runtime.js';
import { ItemIconResolver } from '../content/item-icons.js';
import { loadLegacySkin } from '../skins/legacy.js';
import { applySkin } from '../core/assets/skin.js';
import { uiIcons } from '../core/assets/ui-icons.js';
const legacy = await loadLegacySkin();
await applySkin(document.documentElement, legacy.skin);
uiIcons.replace(legacy.uiIcons, new URL('./', import.meta.url));
const icons = new ItemIconResolver(legacy.itemIcons),
  manager = new WindowManager();
manager.setViewport({ width: innerWidth, height: innerHeight }, 1);
const drag = new ItemDragRuntime({
  scale: () => manager.scale,
  onRegionsChanged: () => {},
});
const view = mountUpgrade(document.querySelector<HTMLElement>('#upgrade')!, {
  manager,
  drag,
  resolveItemIcon: (id) => icons.resolve(id),
  devPreview: true,
  onClose: () => view.setNpcState({ active: false }),
});
view.setNpcState({
  active: true,
  npcInstanceId: 'dev-blacksmith',
  npcDefinitionId: 'blacksmith',
  name: 'Blacksmith',
  selectedServiceId: 'upgrade',
  services: [{ id: 'upgrade', kind: 1, label: 'Upgrade', enabled: true }],
});
window.addEventListener('resize', () =>
  manager.setViewport({ width: innerWidth, height: innerHeight }, 1),
);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !event.repeat) view.closeIfActive();
});
window.addEventListener('pagehide', () => {
  view.dispose();
  drag.dispose();
  manager.dispose();
});
