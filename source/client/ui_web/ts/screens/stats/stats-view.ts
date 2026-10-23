import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { CommandResult } from '../../protocol/contracts.js';
import {
  attributes,
  type Attribute,
  type StatsSnapshot,
} from './stats-model.js';
export function mountStats(
  root: HTMLElement,
  options: {
    manager: WindowManager;
    spend: (attribute: Attribute) => Promise<CommandResult>;
    retry: () => Promise<CommandResult>;
    refresh: () => Promise<CommandResult>;
    close: () => void;
    regions: () => void;
  },
) {
  const shell = new UiWindow(root, {
    id: 'stats',
    title: 'Character · V',
    className: 'stats-window',
    manager: options.manager,
    placement: {
      kind: 'viewport',
      anchor: 'top-left',
      offset: { x: 18, y: 100 },
    },
    onClose: options.close,
    onRegionsChanged: options.regions,
  });
  const content = document.createElement('div');
  content.className = 'stats-content';
  shell.contentRoot.append(content);
  const fields = new Map<string, HTMLElement>();
  function field(key: string, label: string, parent: HTMLElement = content) {
    const row = document.createElement('div');
    row.className = 'stats-row';
    const title = document.createElement('span');
    title.textContent = label;
    const number = document.createElement('span');
    number.className = 'stats-value';
    number.dataset.stat = key;
    row.append(title, number);
    parent.append(row);
    fields.set(key, number);
    return row;
  }
  function heading(text: string) {
    const h = document.createElement('h2');
    h.textContent = text;
    content.append(h);
  }
  field('level', 'Level');
  field('experience', 'EXP');
  const xp = document.createElement('progress');
  xp.max = 1;
  xp.setAttribute('aria-label', 'Experience');
  content.append(xp);
  heading('Character status');
  field('available_points', 'Available points');
  const buttons: HTMLButtonElement[] = [];
  for (const attribute of attributes) {
    const row = field(attribute, attribute);
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = '+';
    b.setAttribute('aria-label', `Increase ${attribute}`);
    b.onclick = () => {
      void send(() => options.spend(attribute));
    };
    row.append(b);
    buttons.push(b);
  }
  heading('Combat');
  for (const [key, label] of [
    ['health_max', 'HP'],
    ['mana_max', 'MP'],
    ['attack', 'Attack'],
    ['armor', 'Defense'],
    ['attack_speed', 'Attack speed'],
    ['mana_regen', 'MP regen / s'],
  ])
    field(key!, label!);
  field('available_skill_points', 'Skill points');
  const notice = document.createElement('p');
  notice.className = 'stats-notice';
  notice.setAttribute('role', 'status');
  const retry = document.createElement('button');
  retry.type = 'button';
  retry.textContent = 'Retry allocation';
  retry.onclick = () => {
    void send(options.retry);
  };
  const refresh = document.createElement('button');
  refresh.type = 'button';
  refresh.textContent = 'Refresh';
  refresh.onclick = () => {
    void send(options.refresh);
  };
  content.append(notice, retry, refresh);
  let state: StatsSnapshot | undefined,
    inFlight = false,
    localError = '',
    disposed = false;
  const errors: Record<string, string> = {
    timeout: 'No confirmation received.',
    outcome_unknown: 'Result not yet confirmed.',
    storage: 'Server storage is unavailable.',
    points: 'No attribute points available.',
    stale: 'Stats changed. Refresh and try again.',
    session: 'Session unavailable.',
    journal: 'Cannot save or clear the pending allocation.',
    stats_pending: 'Confirm the previous allocation first.',
    rate_limited: 'Too many requests. Try again shortly.',
  };
  async function send(action: () => Promise<CommandResult>) {
    if (inFlight || disposed) return;
    inFlight = true;
    localError = '';
    render();
    try {
      const result = await action();
      if (!result.ok) localError = result.error || 'request';
    } catch {
      localError = 'timeout';
    } finally {
      inFlight = false;
      if (!disposed) render();
    }
  }
  function render() {
    if (!state) return;
    root.hidden = !state.opened;
    const data = state.data;
    for (const [key, element] of fields) {
      let value = '—';
      if (data) {
        if (attributes.includes(key as Attribute))
          value = data.attributes[key as Attribute];
        else if (key === 'experience')
          value = `${data.experience} / ${data.xp_to_next}`;
        else if (key in data.combat) {
          value = new Intl.NumberFormat('en', {
            maximumFractionDigits: 2,
          }).format(data.combat[key]!);
          const current =
            key === 'health_max'
              ? state.vitals.hp
              : key === 'mana_max'
                ? state.vitals.mp
                : undefined;
          if (current !== undefined)
            value = `${Math.floor(current)} / ${value}`;
        } else if (key === 'level') value = data.level;
        else if (key === 'available_points') value = data.available_points;
        else if (key === 'available_skill_points')
          value = data.available_skill_points;
      }
      element.textContent = value;
    }
    xp.value = data?.xp_fraction ?? 0;
    for (const b of buttons)
      b.disabled =
        inFlight ||
        state.busy ||
        state.pending ||
        !state.ready ||
        !data ||
        data.available_points === '0';
    retry.hidden = !state.pending;
    retry.disabled = inFlight || state.busy;
    refresh.disabled = inFlight || state.busy;
    const error = localError || state.error;
    notice.textContent = state.pending
      ? `Pending ${state.pending_attribute} allocation. ${errors[error] || (error ? 'Could not confirm the result.' : 'Retry to confirm the result.')}`
      : error
        ? errors[error] || 'Could not load character stats.'
        : !state.ready
          ? 'Loading character stats…'
          : '';
    shell.refresh();
    options.regions();
  }
  return {
    setState(value: StatsSnapshot) {
      const opening = root.hidden && value.opened;
      state = value;
      localError = '';
      render();
      if (opening) shell.handle.activate();
    },
    closeIfActive() {
      if (root.hidden) return false;
      options.close();
      return true;
    },
    dispose() {
      disposed = true;
      shell.dispose();
    },
  };
}
