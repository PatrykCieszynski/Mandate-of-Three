import { isItem } from '../../protocol.js';
import { UiWindow } from '../../core/window/ui-window.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import type {
  ItemPresentation,
  ResolveItemIcon,
} from '../../game-ui/item-types.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { CommandResult, ItemCommand } from '../../protocol/contracts.js';
export interface CraftSnapshot {
  active: boolean;
  pending: boolean;
  busy: boolean;
  currency: ItemPresentation | Record<string, never>;
  effect: string;
  targets: ItemPresentation[];
}
export function isCraft(v: unknown): v is CraftSnapshot {
  if (!v || typeof v !== 'object') return false;
  const s = v as Record<string, unknown>;
  const item = isItem;
  return (
    typeof s.active === 'boolean' &&
    typeof s.pending === 'boolean' &&
    typeof s.busy === 'boolean' &&
    typeof s.effect === 'string' &&
    s.effect.length <= 512 &&
    Array.isArray(s.targets) &&
    s.targets.length <= 180 &&
    s.targets.every(item) &&
    !!s.currency &&
    typeof s.currency === 'object' &&
    (Object.keys(s.currency).length === 0 || item(s.currency))
  );
}
export function mountCraft(
  root: HTMLElement,
  options: {
    manager: WindowManager;
    resolveItemIcon: ResolveItemIcon;
    execute: (p: ItemCommand) => Promise<CommandResult>;
    retry: () => Promise<CommandResult>;
    close: () => void;
    regions: () => void;
  },
) {
  const shell = new UiWindow(root, {
    id: 'craft',
    title: 'Przemiana',
    className: 'craft-window',
    manager: options.manager,
    placement: {
      kind: 'relative',
      target: 'inventory',
      side: 'left',
      align: 'start',
      gap: 8,
      fallback: {
        kind: 'viewport',
        anchor: 'top-left',
        offset: { x: 24, y: 180 },
      },
    },
    onClose: options.close,
    onRegionsChanged: options.regions,
  });
  const body = document.createElement('div');
  body.className = 'craft-body';
  shell.contentRoot.append(body);
  const currency = document.createElement('div');
  currency.className = 'craft-currency';
  const symbol = document.createElement('span');
  symbol.className = 'craft-symbol';
  const name = document.createElement('strong');
  currency.append(symbol, name);
  const effect = document.createElement('p'),
    select = document.createElement('select'),
    target = document.createElement('div'),
    details = document.createElement('p'),
    notice = document.createElement('p'),
    actions = document.createElement('div'),
    apply = document.createElement('button'),
    retry = document.createElement('button');
  select.setAttribute('aria-label', 'Przedmiot do przemiany');
  target.className = 'craft-target';
  details.className = 'craft-details';
  notice.className = 'craft-notice';
  actions.className = 'craft-actions';
  apply.textContent = 'Użyj · 1 szt.';
  retry.textContent = 'Odzyskaj wynik';
  actions.append(apply, retry);
  body.append(currency, effect, select, target, details, notice, actions);
  const tooltip = ItemTooltip(root, { geometry: () => options.manager });
  let state: CraftSnapshot = {
      active: false,
      pending: false,
      busy: false,
      currency: {},
      effect: '',
      targets: [],
    },
    selected = '',
    pending = false;
  function render() {
    root.hidden = !state.active;
    const c = state.currency as Partial<ItemPresentation>;
    name.textContent = c.name ?? 'Odzyskiwanie przemiany';
    symbol.replaceChildren();
    if (c.icon_id)
      paintItemIcon(symbol, c as ItemPresentation, {
        resolveItemIcon: options.resolveItemIcon,
      });
    effect.textContent = state.effect;
    select.replaceChildren();
    const prompt = document.createElement('option');
    prompt.value = '';
    prompt.textContent = 'Wybierz przedmiot z torby';
    select.append(prompt);
    for (const i of state.targets) {
      const o = document.createElement('option');
      o.value = i.id;
      o.textContent = i.name;
      select.append(o);
    }
    if (!state.targets.some((i) => i.id === selected)) selected = '';
    select.value = selected;
    const item = state.targets.find((i) => i.id === selected);
    target.replaceChildren();
    if (item)
      paintItemIcon(target, item, { resolveItemIcon: options.resolveItemIcon });
    details.textContent = item
      ? `${item.tooltip?.rarity ?? 'normal'} · +${item.upgrade_level ?? 0} · ${item.tooltip?.affixes?.length ?? 0} affixów`
      : '';
    apply.disabled = pending || state.busy || state.pending || !item || !c.id;
    select.disabled = pending || state.busy || state.pending;
    retry.hidden = !state.pending;
    retry.disabled = pending || state.busy;
    shell.refresh();
    options.regions();
  }
  select.addEventListener('change', () => {
    selected = select.value;
    notice.textContent = '';
    render();
  });
  target.addEventListener('mousemove', (e) => {
    const i = state.targets.find((i) => i.id === selected);
    if (i) tooltip.show(e, i);
  });
  target.addEventListener('mouseleave', () => tooltip.hide());
  async function run(recover: boolean) {
    if (pending) return;
    const item = state.targets.find((i) => i.id === selected);
    if (!recover && !item) return;
    pending = true;
    render();
    try {
      const r = await (recover
        ? options.retry()
        : options.execute({ id: item!.id, revision: item!.revision }));
      notice.textContent = r.ok
        ? 'Przemiana zakończona.'
        : `Nie ukończono: ${r.error ?? 'unknown'}`;
    } catch {
      notice.textContent = 'Brak potwierdzenia. Odzyskaj wynik.';
    } finally {
      pending = false;
      render();
    }
  }
  apply.addEventListener('click', () => void run(false));
  retry.addEventListener('click', () => void run(true));
  return {
    regions: [shell.panel],
    setState(next: CraftSnapshot) {
      const opening = !state.active && next.active;
      state = next;
      render();
      if (opening) shell.handle.activate();
    },
    closeIfActive() {
      if (root.hidden || options.manager.activeWindowId !== 'craft')
        return false;
      options.close();
      return true;
    },
    dispose() {
      tooltip.dispose();
      shell.dispose();
    },
  };
}
