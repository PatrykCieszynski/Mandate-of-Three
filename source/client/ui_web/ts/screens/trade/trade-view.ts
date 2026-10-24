import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { CommandResult } from '../../protocol/contracts.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import { OwnedItemDragSubject } from '../../game-ui/items/item-drag-policy.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import {
  isItemTooltipDetails,
  type ItemTooltipDetails,
} from '../../game-ui/items/item-tooltip-model.js';
import type {
  ItemPresentation,
  ResolveItemIcon,
} from '../../game-ui/item-types.js';
export interface TradeItem {
  uid: string;
  revision: string;
  name: string;
  amount: string;
  icon: string;
  tooltip?: ItemTooltipDetails;
}
export interface TradeOffer {
  name: string;
  items: TradeItem[];
  yang: string;
}
export interface TradeSnapshot {
  id: string;
  phase: string;
  version: number;
  self: number;
  candidates: { id: number; name: string }[];
  incoming?: boolean;
  own_side?: number;
  accepted?: boolean[];
  offers?: TradeOffer[];
  opened?: boolean;
  pending?: boolean;
  recover_id?: string;
  client_error?: string;
  error?: string;
}
export type TradeCommand =
  | { action: 'invite'; target: number }
  | { action: 'join' | 'cancel' | 'recover'; trade_id: string }
  | { action: 'confirm'; trade_id: string; version: number }
  | {
      action: 'offer';
      trade_id: string;
      version: number;
      items: { uid: string; revision: string }[];
      yang: string;
    };
const decimal = (v: unknown) => typeof v === 'string' && /^\d{1,18}$/.test(v);
export function isTrade(v: unknown): v is TradeSnapshot {
  if (!v || typeof v !== 'object') return false;
  const s = v as TradeSnapshot;
  return (
    typeof s.id === 'string' &&
    s.id.length <= 96 &&
    typeof s.phase === 'string' &&
    s.phase.length <= 64 &&
    Number.isSafeInteger(s.version) &&
    s.version >= 0 &&
    Number.isSafeInteger(s.self) &&
    Array.isArray(s.candidates) &&
    s.candidates.length <= 64 &&
    s.candidates.every(
      (c) =>
        !!c &&
        typeof c === 'object' &&
        Number.isSafeInteger(c.id) &&
        c.id > 0 &&
        typeof c.name === 'string',
    ) &&
    (s.own_side === undefined || s.own_side === 0 || s.own_side === 1) &&
    (s.accepted === undefined ||
      (Array.isArray(s.accepted) &&
        s.accepted.length === 2 &&
        s.accepted.every((a) => typeof a === 'boolean'))) &&
    (s.offers === undefined ||
      (Array.isArray(s.offers) &&
        s.offers.length === 2 &&
        s.offers.every(
          (o) =>
            !!o &&
            typeof o === 'object' &&
            typeof o.name === 'string' &&
            decimal(o.yang) &&
            Array.isArray(o.items) &&
            o.items.length <= 20 &&
            o.items.every(
              (i) =>
                !!i &&
                typeof i === 'object' &&
                /^[0-9a-f]{32}$/.test(i.uid) &&
                decimal(i.revision) &&
                typeof i.name === 'string' &&
                typeof i.icon === 'string' &&
                (i.tooltip === undefined || isItemTooltipDetails(i.tooltip)) &&
                decimal(i.amount),
            ),
        ))) &&
    ['recover_id', 'client_error', 'error'].every(
      (k) =>
        s[k as keyof TradeSnapshot] === undefined ||
        typeof s[k as keyof TradeSnapshot] === 'string',
    ) &&
    ['opened', 'incoming', 'pending'].every(
      (k) =>
        s[k as keyof TradeSnapshot] === undefined ||
        typeof s[k as keyof TradeSnapshot] === 'boolean',
    )
  );
}
export function mountTrade(
  root: HTMLElement,
  options: {
    manager: WindowManager;
    drag: ItemDragRuntime;
    resolveItemIcon: ResolveItemIcon;
    command: (p: TradeCommand) => Promise<CommandResult>;
    close: () => void;
    regions: () => void;
  },
) {
  const shell = new UiWindow(root, {
    id: 'trade',
    title: 'Trade · T',
    className: 'trade-window',
    manager: options.manager,
    placement: {
      kind: 'viewport',
      anchor: 'top-left',
      offset: { x: 280, y: 100 },
    },
    onClose: options.close,
    onRegionsChanged: options.regions,
  });
  const content = document.createElement('div');
  const tip = ItemTooltip(root, { geometry: () => options.manager });
  content.className = 'trade-content';
  shell.contentRoot.append(content);
  const ownGrid = document.createElement('div');
  ownGrid.className = 'trade-grid';
  let state: TradeSnapshot | undefined,
    flight = false,
    error = '',
    yangDraft: string | undefined;
  const own = () => state?.offers?.[state.own_side ?? 0];
  const send = async (p: TradeCommand) => {
    if (flight) return;
    flight = true;
    render();
    try {
      const r = await options.command(p);
      error = r.ok ? '' : String(r.error ?? 'Request failed');
    } catch {
      error =
        'Connection lost. Recover the trade result before starting another.';
    } finally {
      flight = false;
      render();
    }
  };
  const button = (text: string, p: TradeCommand) => {
    const b = document.createElement('button');
    b.className = 'ui-button';
    b.textContent = text;
    b.disabled = flight;
    b.onclick = () => void send(p);
    return b;
  };
  const offer = (
    items: { uid: string; revision: string }[],
    yang = own()?.yang ?? '0',
  ) => {
    if (state?.phase === 'offer')
      void send({
        action: 'offer',
        trade_id: state.id,
        version: state.version,
        items,
        yang,
      });
  };
  const offerItem = async (item: ItemPresentation) => {
    if (!state || state.phase !== 'offer' || flight) return false;
    const lines =
      own()?.items.map((i) => ({ uid: i.uid, revision: i.revision })) ?? [];
    if (lines.some((i) => i.uid === item.id)) return true;
    if (lines.length >= 20) return false;
    offer([...lines, { uid: item.id, revision: String(item.revision) }]);
    return true;
  };
  const unregister = options.drag.registerTarget({
    element: ownGrid,
    preview: (p) => ({
      valid:
        state?.phase === 'offer' &&
        !flight &&
        p.subject instanceof OwnedItemDragSubject &&
        p.subject.container === 'inventory',
      data: null,
    }),
    drop: async (p) => {
      if (
        p.subject instanceof OwnedItemDragSubject &&
        p.subject.container === 'inventory'
      )
        offerItem(p.subject.item);
    },
  });
  function render() {
    tip.hide();
    content.replaceChildren();
    if (!state) return;
    root.hidden = !state.opened;
    if (!state.opened) {
      shell.refresh();
      options.regions();
      return;
    }
    const status = document.createElement('p');
    status.className = 'trade-status';
    status.textContent =
      error ||
      state.client_error ||
      state.error ||
      ({
        settling: 'Completing exchange…',
        reconcile: 'Updating inventories…',
        complete: 'Exchange complete.',
        cancelled: 'Exchange cancelled.',
        paused: 'Result not confirmed. Recover before trading again.',
      }[state.phase] ??
        '');
    if (state.pending && state.recover_id)
      content.append(
        button('Recover result', {
          action: 'recover',
          trade_id: state.recover_id,
        }),
      );
    if (
      state.phase === 'idle' ||
      (state.offers === undefined &&
        state.phase !== 'invited' &&
        state.phase !== 'unavailable')
    ) {
      const select = document.createElement('select');
      select.setAttribute('aria-label', 'Nearby player');
      state.candidates.forEach((c) => {
        const o = document.createElement('option');
        o.value = String(c.id);
        o.textContent = c.name;
        select.append(o);
      });
      const invite = document.createElement('button');
      invite.className = 'ui-button';
      invite.textContent = 'Invite to trade';
      invite.disabled = flight || !!state.pending || !state.candidates.length;
      invite.onclick = () =>
        void send({ action: 'invite', target: Number(select.value) });
      content.append(select, invite);
    }
    if (state.phase === 'invited') {
      const p = document.createElement('p');
      p.textContent =
        state.offers?.[1 - (state.own_side ?? 0)]?.name ?? 'Trade invitation';
      content.append(p);
      if (state.incoming)
        content.append(
          button('Accept invitation', { action: 'join', trade_id: state.id }),
        );
    }
    if (state.offers) {
      const sides = document.createElement('div');
      sides.className = 'trade-sides';
      const self = state.own_side ?? 0;
      // Counterparty left, own offer right, regardless of who sent the invite.
      [1 - self, self].forEach((index) => {
        const o = state!.offers![index]!;
        const mine = index === self;
        const side = document.createElement('section');
        side.className = 'trade-side';
        side.setAttribute('aria-label', mine ? 'Your offer' : 'Partner offer');
        side.dataset.accepted = String(!!state!.accepted?.[index]);
        const heading = document.createElement('h3');
        heading.textContent = mine ? 'You' : o.name;
        heading.title = o.name;
        const grid = mine ? ownGrid : document.createElement('div');
        grid.className = 'trade-grid';
        grid.replaceChildren();
        for (let n = 0; n < 20; n++) {
          const cell = document.createElement('button');
          cell.className = 'trade-slot ui-slot';
          cell.disabled = flight || !mine || state!.phase !== 'offer';
          const item = o.items[n];
          if (item) {
            cell.title = item.name;
            cell.onpointermove = (e) => tip.show(e, item);
            cell.onpointerleave = () => tip.hide();
            paintItemIcon(
              cell,
              {
                name: item.name,
                icon_id: item.icon,
                quantity: Number(item.amount),
              },
              { resolveItemIcon: options.resolveItemIcon },
            );
            const remove = () =>
              offer(
                o.items
                  .filter((i) => i.uid !== item.uid)
                  .map((i) => ({ uid: i.uid, revision: i.revision })),
              );
            cell.onclick = remove;
            cell.oncontextmenu = (e) => {
              e.preventDefault();
              remove();
            };
          }
          grid.append(cell);
        }
        side.append(heading, grid);
        const money = document.createElement('div');
        money.className = 'trade-money';
        const currency = document.createElement('span');
        currency.className = 'trade-currency';
        currency.textContent = 'Yang';
        money.append(currency);
        if (mine && state!.phase === 'offer') {
          const yang = document.createElement('input');
          yang.inputMode = 'numeric';
          yang.value = yangDraft ?? o.yang;
          yang.disabled = flight;
          yang.oninput = () => {
            yangDraft = yang.value;
            const confirm = content.querySelector<HTMLButtonElement>(
              '[aria-label="Accept current offer"]',
            );
            if (confirm)
              confirm.disabled =
                flight || !!state!.accepted?.[index] || yang.value !== o.yang;
          };
          yang.setAttribute('aria-label', 'Yang offered');
          const update = document.createElement('button');
          update.className = 'ui-button trade-set-yang';
          update.textContent = '✓';
          update.title = 'Set Yang';
          update.setAttribute('aria-label', 'Set Yang');
          update.disabled = flight;
          update.onclick = () => {
            if (/^\d{1,16}$/.test(yang.value))
              offer(
                o.items.map((i) => ({ uid: i.uid, revision: i.revision })),
                yang.value,
              );
          };
          yang.onkeydown = (e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              update.click();
            }
          };
          money.append(yang, update);
        } else {
          const amount = document.createElement('output');
          amount.textContent = o.yang;
          amount.setAttribute(
            'aria-label',
            mine ? 'Your Yang' : 'Partner Yang',
          );
          money.append(amount);
        }
        side.append(money);
        const acceptance = document.createElement('div');
        acceptance.className = 'trade-acceptance';
        const ready = document.createElement('span');
        ready.className = 'trade-ready';
        ready.textContent = state!.accepted?.[index]
          ? '✓ Accepted'
          : 'Not accepted';
        acceptance.append(ready);
        if (mine && state!.phase === 'offer') {
          const confirm = button('Accept', {
            action: 'confirm',
            trade_id: state!.id,
            version: state!.version,
          });
          confirm.setAttribute('aria-label', 'Accept current offer');
          confirm.disabled =
            flight ||
            !!state!.accepted?.[index] ||
            (yangDraft !== undefined && yangDraft !== o.yang);
          confirm.title =
            'Set Yang before accepting this version of both offers';
          acceptance.append(confirm);
        }
        side.append(acceptance);
        sides.append(side);
      });
      content.append(sides);
    }
    if (status.textContent) content.append(status);
    shell.refresh();
    options.regions();
  }
  return {
    regions: [shell.panel],
    offerItem,
    setState(s: TradeSnapshot) {
      const opening = root.hidden && s.opened;
      if (
        s.id !== state?.id ||
        s.offers?.[s.own_side ?? 0]?.yang !== own()?.yang
      )
        yangDraft = undefined;
      state = s;
      render();
      if (opening) shell.handle.activate();
    },
    dispose() {
      unregister.dispose();
      tip.dispose();
      shell.dispose();
    },
  };
}
