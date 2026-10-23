import type { HotbarSnapshot } from './hotbar-model.js';
import { hotbarKeys } from './hotbar-model.js';
import type { CommandResult } from '../protocol/contracts.js';
import type { ItemDragRuntime } from '../game-ui/drag/item-drag-runtime.js';
import type { DragRegistration } from '../game-ui/drag/item-drag-types.js';
import { OwnedItemDragSubject } from '../game-ui/items/item-drag-policy.js';
import { paintItemIcon } from '../game-ui/items/item-icon.js';
import type { ResolveItemIcon } from '../game-ui/item-types.js';
export function mountBottomHud(
  root: HTMLElement,
  options: {
    drag: ItemDragRuntime;
    resolveItemIcon: ResolveItemIcon;
    assign: (slot: number, id: string) => Promise<CommandResult>;
    clear: (slot: number) => Promise<CommandResult>;
    activate: (slot: number) => Promise<CommandResult>;
    system: (
      action: 'inventory' | 'stats' | 'options',
    ) => Promise<CommandResult>;
    regions: () => void;
  },
) {
  const panel = document.createElement('div');
  panel.id = 'bottom-hud-panel';
  panel.className = 'bottom-hud-panel';
  const vitals = document.createElement('div');
  vitals.className = 'bottom-hud-vitals';
  const level = document.createElement('span');
  level.className = 'bottom-hud-level';
  level.textContent = 'Lv —';
  vitals.append(level);
  const meters = new Map<
    string,
    { bar: HTMLProgressElement; label: HTMLElement }
  >();
  for (const name of ['HP', 'MP']) {
    const row = document.createElement('div');
    row.className = 'bottom-hud-meter ' + name.toLowerCase();
    const bar = document.createElement('progress');
    bar.max = 1;
    bar.value = 0;
    bar.setAttribute('aria-label', name);
    const label = document.createElement('span');
    label.textContent = name + ' —';
    row.append(bar, label);
    vitals.append(row);
    meters.set(name, { bar, label });
  }
  panel.append(vitals);
  const slots: { button: HTMLButtonElement; icon: HTMLElement }[] = [];
  const registrations: DragRegistration[] = [];
  let state: HotbarSnapshot | undefined,
    inFlight = false,
    disposed = false,
    localError = '';
  const feedback = document.createElement('div');
  feedback.className = 'bottom-hud-feedback';
  feedback.setAttribute('role', 'status');
  feedback.hidden = true;
  async function send(action: () => Promise<CommandResult>) {
    if (disposed || inFlight) return;
    inFlight = true;
    localError = '';
    update();
    try {
      const result = await action();
      if (!result.ok) localError = result.error || 'request';
    } catch {
      localError = 'timeout';
    } finally {
      inFlight = false;
      if (!disposed) update();
    }
  }
  for (let bank = 0; bank < 2; bank++) {
    const group = document.createElement('div');
    group.className = 'bottom-hud-slots';
    group.setAttribute('role', 'group');
    group.setAttribute(
      'aria-label',
      bank === 0 ? 'Quick slots 1–8' : 'Quick slots F1–F8',
    );
    for (let j = 0; j < 8; j++) {
      const index = bank * 8 + j,
        button = document.createElement('button');
      button.type = 'button';
      button.className = 'bottom-hud-slot';
      button.dataset.slot = String(index);
      const icon = document.createElement('span');
      icon.className = 'bottom-hud-icon';
      const key = document.createElement('span');
      key.className = 'bottom-hud-key';
      key.textContent = hotbarKeys[index]!;
      button.append(icon, key);
      button.onclick = () => {
        if (!options.drag.active) void send(() => options.activate(index));
      };
      button.oncontextmenu = (event) => {
        event.preventDefault();
        if (!options.drag.active) void send(() => options.clear(index));
      };
      registrations.push(
        options.drag.registerTarget({
          element: button,
          preview: (payload) => ({
            valid:
              !inFlight &&
              !!state?.ready &&
              payload.subject instanceof OwnedItemDragSubject &&
              payload.subject.container === 'inventory',
            data: null,
          }),
          drop: (payload) => {
            const subject = payload.subject;
            if (
              subject instanceof OwnedItemDragSubject &&
              subject.container === 'inventory'
            )
              return send(() => options.assign(index, subject.item.id));
          },
        }),
      );
      slots.push({ button, icon });
      group.append(button);
    }
    panel.append(group);
  }
  const system = document.createElement('div');
  system.className = 'bottom-hud-system';
  for (const [action, label] of [
    ['inventory', 'Inventory · I'],
    ['stats', 'Character · V'],
    ['options', 'Options'],
  ] as const) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.onclick = () => {
      void send(() => options.system(action));
    };
    system.append(b);
  }
  panel.append(system, feedback);
  root.append(panel);
  function update() {
    const v = state?.vitals;
    level.textContent = v?.ready ? `Lv ${v.level}` : 'Lv —';
    for (const name of ['HP', 'MP']) {
      const value = name === 'HP' ? v?.hp : v?.mp,
        max = name === 'HP' ? v?.max_hp : v?.max_mp,
        meter = meters.get(name)!;
      meter.bar.max = Math.max(1, max ?? 0);
      meter.bar.value = Math.min(max ?? 0, value ?? 0);
      meter.label.textContent = v?.ready
        ? `${name} ${Math.floor(value ?? 0)} / ${Math.floor(max ?? 0)}`
        : `${name} —`;
    }
    slots.forEach(({ button, icon }, i) => {
      const binding = state?.slots[i],
        assigned = !!binding?.id;
      button.classList.toggle('assigned', assigned);
      button.classList.toggle('unavailable', assigned && !binding?.available);
      // Unavailable assignments still accept a replacement drop or right-click clear.
      button.setAttribute(
        'aria-disabled',
        String(!state?.ready || state.busy || inFlight || !binding?.available),
      );
      button.setAttribute(
        'aria-label',
        `Quick slot ${hotbarKeys[i]}${assigned ? ': ' + binding?.name : ', empty'}`,
      );
      button.title = assigned
        ? `${binding?.name} · ${hotbarKeys[i]}${binding?.available ? '' : ' · unavailable'} · Right click to clear`
        : `Drop an Inventory item · ${hotbarKeys[i]}`;
      const signature = JSON.stringify(binding ?? {});
      if (icon.dataset.content !== signature) {
        icon.dataset.content = signature;
        if (assigned)
          paintItemIcon(
            icon,
            {
              name: binding?.name ?? '',
              icon_id: binding?.icon_id ?? '',
              quantity: binding?.quantity ?? 0,
            },
            { resolveItemIcon: options.resolveItemIcon },
          );
        else icon.replaceChildren();
      }
    });
    const error = localError || state?.error || '';
    const errors: Record<string, string> = {
      unsupported: 'This item has no supported use action yet.',
      no_action: 'This item has no use action.',
      unavailable: 'This shortcut is unavailable.',
      preferences: 'Could not save or load shortcuts.',
      inventory_pending:
        'Resolve the pending Inventory operation before another action.',
      timeout: 'No confirmation received. Check Inventory recovery.',
    };
    feedback.textContent = error
      ? errors[error] || `Action failed: ${error}`
      : '';
    feedback.hidden = !error;
    options.regions();
  }
  return {
    regions: [panel],
    setScale(scale: number) {
      if (!Number.isFinite(scale) || scale <= 0)
        throw Error('Invalid UI scale');
      root.style.setProperty('--ui-scale', String(scale));
    },
    render(value: HotbarSnapshot) {
      state = value;
      localError = '';
      update();
    },
    dispose() {
      disposed = true;
      for (const r of registrations) r.dispose();
      panel.remove();
    },
  };
}
