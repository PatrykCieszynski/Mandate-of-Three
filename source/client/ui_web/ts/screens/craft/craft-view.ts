import { isItem } from '../../protocol.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import type {
  ItemPresentation,
  ResolveItemIcon,
} from '../../game-ui/item-types.js';
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
export const CRAFT_CURRENCIES = [
  'change_spark',
  'renewal_dust',
  'completion_shard',
  'ascension_ember',
  'renewal_prism',
];
// Explicit currency-use mode, separate from ordinary item carrying/placement.
export function mountCraft(
  root: HTMLElement,
  options: {
    resolveItemIcon: ResolveItemIcon;
    storageRoot?: HTMLElement;
    execute: (p: ItemCommand) => Promise<CommandResult>;
    retry: () => Promise<CommandResult>;
    close: () => void;
    cancelCarry: () => void;
    regions: () => void;
  },
) {
  const doc = root.ownerDocument;
  const surface = doc.createElement('div');
  surface.className = 'craft-input-surface';
  surface.id = 'craft-targeting';
  surface.hidden = true;
  surface.setAttribute('aria-hidden', 'true');
  doc.body.append(surface);
  const cursor = doc.createElement('div');
  cursor.className = 'craft-use-cursor';
  surface.append(cursor);
  const icon = doc.createElement('span'),
    hint = doc.createElement('span');
  icon.className = 'craft-cursor-icon';
  cursor.append(icon, hint);
  const recovery = doc.createElement('div');
  recovery.className = 'craft-recovery';
  recovery.hidden = true;
  const message = doc.createElement('span'),
    retry = doc.createElement('button');
  retry.textContent = 'Odzyskaj wynik';
  recovery.append(message, retry);
  (root.querySelector('.window-content') ?? root).append(recovery);
  let state: CraftSnapshot = {
      active: false,
      pending: false,
      busy: false,
      currency: {},
      effect: '',
      targets: [],
    },
    armed = false,
    inFlight = false,
    disposed = false,
    notice = '';
  function reason(item: ItemPresentation | undefined): string {
    if (!item) return 'Wybierz przedmiot w torbie';
    const target = state.targets.find((i) => i.id === item.id);
    if (!target) return 'Nie można użyć tej waluty na tym przedmiocie';
    const rarity = target.tooltip?.rarity;
    const currency = (state.currency as Partial<ItemPresentation>)
      .definition_id;
    if (currency === 'change_spark' || currency === 'ascension_ember')
      return rarity === 'normal' ? '' : 'Wymaga przedmiotu Normal';
    if (currency === 'renewal_prism')
      return rarity === 'rare' ? '' : 'Wymaga przedmiotu Rare';
    if (rarity !== 'magic') return 'Wymaga przedmiotu Magic';
    if (
      currency === 'completion_shard' &&
      target.tooltip?.affixes?.length !== 1
    )
      return 'Wymaga dokładnie jednego affixu';
    return '';
  }
  function refreshTargets() {
    const decorate = (node: HTMLElement, why: string) => {
      if (armed) {
        node.dataset.craftTarget = why ? 'invalid' : 'valid';
        node.title = why;
      } else {
        delete node.dataset.craftTarget;
        node.removeAttribute('title');
      }
    };
    for (const node of root.querySelectorAll<HTMLElement>('.inventory-item')) {
      decorate(
        node,
        reason(state.targets.find((i) => i.id === node.dataset.id)),
      );
    }
    for (const node of options.storageRoot?.querySelectorAll<HTMLElement>(
      '.storage-grid .ui-item-slot',
    ) ?? []) {
      decorate(node, 'Przenieś przedmiot ze Storage do torby');
    }
  }
  // Page changes replace slot nodes without a domain snapshot. Observe only
  // child replacement; decorations change attributes and cannot retrigger this.
  const slotsChanged = new doc.defaultView!.MutationObserver(() => {
    if (!disposed) refreshTargets();
  });
  slotsChanged.observe(root, { subtree: true, childList: true });
  if (options.storageRoot)
    slotsChanged.observe(options.storageRoot, {
      subtree: true,
      childList: true,
    });
  function render() {
    surface.hidden = !armed;
    icon.replaceChildren();
    const currency = state.currency as Partial<ItemPresentation>;
    if (currency.id)
      paintItemIcon(icon, currency as ItemPresentation, {
        resolveItemIcon: options.resolveItemIcon,
      });
    hint.textContent =
      inFlight || state.busy
        ? 'Oczekiwanie…'
        : state.pending
          ? 'Najpierw odzyskaj wynik'
          : notice || `${currency.name ?? ''} · kliknij cel · Shift: powtarzaj`;
    recovery.hidden = !state.pending || state.busy || inFlight;
    message.textContent = 'Wynik przemiany niepotwierdzony. ';
    retry.disabled = inFlight || state.busy;
    refreshTargets();
    options.regions();
  }
  function cancel() {
    if (!armed) return false;
    armed = false;
    notice = '';
    options.close();
    render();
    return true;
  }
  async function use(item: ItemPresentation, shift: boolean) {
    if (!armed || inFlight || state.busy || state.pending) return;
    const why = reason(item);
    if (why) {
      notice = why;
      render();
      return;
    }
    const target = state.targets.find((i) => i.id === item.id)!;
    inFlight = true;
    notice = '';
    render();
    try {
      const result = await options.execute({
        id: target.id,
        revision: target.revision,
      });
      if (disposed) return;
      if (result.ok) {
        if (!shift || !(state.currency as Partial<ItemPresentation>).id)
          cancel();
      } else notice = `Nie ukończono: ${result.error ?? 'unknown'}`;
    } catch {
      notice = 'Brak potwierdzenia — odzyskaj wynik';
    } finally {
      inFlight = false;
      if (!disposed) render();
    }
  }
  // Window capture runs before document-level item carrying. Cancel without
  // consuming the event, so the first click in another window still works.
  function outsidePointer(event: PointerEvent) {
    if (
      armed &&
      event.button === 0 &&
      event.target instanceof doc.defaultView!.Node &&
      !root.contains(event.target)
    )
      cancel();
  }
  function pointer(event: PointerEvent) {
    if (!armed) return;
    if (event.button === 2) {
      event.preventDefault();
      event.stopImmediatePropagation();
      cancel();
      return;
    }
    if (event.button !== 0) return;
    if (
      event.target instanceof doc.defaultView!.Element &&
      root.contains(event.target) &&
      event.target.closest('button,[role=tab]')
    )
      return;
    if (
      event.target instanceof doc.defaultView!.Node &&
      recovery.contains(event.target)
    )
      return;
    // A normal drag never reaches crafting. Use mode consumes a deliberate click
    // before any Inventory activation or placement can run.
    event.preventDefault();
    event.stopImmediatePropagation();
    options.cancelCarry();
    const node =
      event.target instanceof doc.defaultView!.Element
        ? event.target.closest<HTMLElement>('.inventory-item')
        : null;
    if (node && root.contains(node)) {
      const item = state.targets.find((i) => i.id === node.dataset.id);
      if (item) void use(item, event.shiftKey);
      else {
        notice = 'Nieprawidłowy cel';
        render();
      }
    }
  }
  function move(event: PointerEvent) {
    cursor.style.left = `${Math.max(0, Math.min(event.clientX + 14, (doc.defaultView?.innerWidth ?? 0) - 260))}px`;
    cursor.style.top = `${Math.max(0, Math.min(event.clientY + 14, (doc.defaultView?.innerHeight ?? 0) - 72))}px`;
  }
  function key(event: KeyboardEvent) {
    if (event.key === 'Escape' && cancel()) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }
  function blur() {
    cancel();
  }
  async function recover() {
    if (inFlight || state.busy) return;
    inFlight = true;
    render();
    try {
      const result = await options.retry();
      if (result.ok || !state.pending) {
        if (!cancel()) options.close();
      }
    } catch {
      notice = 'Nie udało się odzyskać wyniku';
    } finally {
      inFlight = false;
      if (!disposed) render();
    }
  }
  retry.addEventListener('click', () => void recover());
  doc.defaultView?.addEventListener('pointerdown', outsidePointer, true);
  doc.addEventListener('pointerdown', pointer, true);
  doc.addEventListener('pointermove', move, true);
  doc.addEventListener('keydown', key, true);
  doc.defaultView?.addEventListener('blur', blur);
  return {
    regions: [surface],
    engaged: () => armed,
    cancel,
    refreshTargets,
    reason,
    use,
    setState(next: CraftSnapshot) {
      const opening = next.active && !state.active;
      state = next;
      if (opening && !next.pending) {
        options.cancelCarry();
        armed = true;
      }
      if (!next.active) armed = false;
      if (armed && !(next.currency as Partial<ItemPresentation>).id) cancel();
      render();
    },
    dispose() {
      disposed = true;
      slotsChanged.disconnect();
      armed = false;
      doc.defaultView?.removeEventListener('pointerdown', outsidePointer, true);
      doc.removeEventListener('pointerdown', pointer, true);
      doc.removeEventListener('pointermove', move, true);
      doc.removeEventListener('keydown', key, true);
      doc.defaultView?.removeEventListener('blur', blur);
      surface.remove();
      recovery.remove();
      refreshTargets();
    },
  };
}
