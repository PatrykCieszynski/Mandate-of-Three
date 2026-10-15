import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { ResolveItemIcon } from '../../game-ui/item-types.js';
import type { CommandResult } from '../../protocol/contracts.js';
import { UiItemSlot } from '../../game-ui/items/ui-item-slot.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import {
  marketCommandId,
  type MarketCommand,
  type MarketOffer,
} from './market-model.js';
import type {
  MarketBrowserSnapshot,
  MarketSearch,
  MarketResult,
  AffixFilter,
} from './browser-model.js';
interface Options {
  manager: WindowManager;
  resolveItemIcon: ResolveItemIcon;
  catalog: (query: string) => Promise<CommandResult>;
  search: (p: MarketSearch) => Promise<CommandResult>;
  visit: (shop: number, offer: string) => Promise<CommandResult>;
  buy: (p: MarketCommand) => Promise<CommandResult>;
  close: () => void;
  regions: () => void;
}
export function mountMarketBrowser(
  root: HTMLElement,
  shopRoot: HTMLElement,
  o: Options,
) {
  const shell = new UiWindow(root, {
    id: 'market-browser',
    title: 'Trading Glass',
    className: 'market-browser-window',
    manager: o.manager,
    placement: {
      kind: 'viewport',
      anchor: 'top-left',
      offset: { x: 30, y: 80 },
    },
    onClose: o.close,
    onRegionsChanged: o.regions,
  });
  const visitor = new UiWindow(shopRoot, {
    id: 'market-visitor',
    title: 'Player Shop',
    className: 'market-visitor-window',
    manager: o.manager,
    placement: {
      kind: 'relative',
      target: 'market-browser',
      side: 'right',
      gap: 12,
      fallback: {
        kind: 'viewport',
        anchor: 'top-right',
        offset: { x: 30, y: 80 },
      },
    },
    onClose: () => {
      shopRoot.hidden = true;
      o.regions();
    },
    onRegionsChanged: o.regions,
  });
  let state: MarketBrowserSnapshot = { active: false },
    selected: MarketOffer | undefined,
    pending = false,
    disposed = false,
    timer: ReturnType<typeof setTimeout> | undefined,
    lastSearch: MarketSearch | undefined;
  let buyIntent: MarketCommand | undefined;
  let criteriaKey = '';
  const tooltip = ItemTooltip(root, { geometry: () => o.manager }),
    shopTooltip = ItemTooltip(shopRoot, { geometry: () => o.manager });
  const filter = document.createElement('div');
  filter.className = 'market-filters';
  const query = input('Base item'),
    definitions = document.createElement('select');
  definitions.setAttribute('aria-label', 'Base item definition');
  definitions.dataset.uiText = '';
  const from = select('Upgrade from'),
    to = select('Upgrade to');
  for (let n = 0; n <= 9; n++) {
    from.add(new Option('+' + n, String(n)));
    to.add(new Option('+' + n, String(n)));
  }
  to.value = '9';
  const priceMin = input('Minimum Yang'),
    priceMax = input('Maximum Yang');
  priceMin.value = '0';
  priceMax.value = '9000000000000000';
  const sort = select('Sort');
  sort.add(new Option('Price ascending', 'price_asc'));
  sort.add(new Option('Price descending', 'price_desc'));
  const bonuses = document.createElement('div');
  bonuses.className = 'market-bonuses';
  const stat = select('Bonus stat'),
    minimum = input('Minimum bonus');
  minimum.value = '0';
  const conditions: AffixFilter[] = [];
  const conditionList = document.createElement('div');
  const status = document.createElement('p');
  status.setAttribute('role', 'status');
  status.className = 'market-status';
  const table = document.createElement('table');
  table.className = 'market-results';
  const header = document.createElement('thead');
  header.innerHTML =
    '<tr><th>Item</th><th>Qty</th><th>Yang</th><th>Shop</th></tr>';
  const body = document.createElement('tbody');
  table.append(header, body);
  const next = button(
    'Next page',
    () => void search(state.active ? state.cursor : ''),
  );
  next.disabled = true;
  filter.append(
    query,
    definitions,
    from,
    to,
    priceMin,
    priceMax,
    sort,
    button('Search', () => void search('')),
  );
  bonuses.append(
    stat,
    minimum,
    button('Add AND bonus', () => {
      if (
        conditions.length >= 4 ||
        conditions.some((c) => c.stat_id === stat.value)
      )
        return;
      const value = Number(minimum.value);
      if (!Number.isFinite(value)) return;
      conditions.push({ stat_id: stat.value, minimum: value });
      renderConditions();
    }),
    button('Reset bonuses', () => {
      conditions.length = 0;
      renderConditions();
    }),
    conditionList,
  );
  shell.contentRoot.append(filter, bonuses, status, table, next);
  const shopName = document.createElement('p'),
    shopGridRoot = document.createElement('div');
  shopGridRoot.className = 'market-grid';
  const grid = UiItemGrid(shopGridRoot, { slotSize: () => 40 });
  const offerInfo = document.createElement('p'),
    buy = button('Buy selected item', () => void purchase());
  buy.disabled = true;
  const retry = button('Retry same purchase', () => void purchase(true));
  retry.hidden = true;
  // Placeholder only: private messages have no server command yet.
  const whisper = button('Whisper seller (soon)', () => {});
  whisper.disabled = true;
  whisper.title = 'Private messages are not implemented yet.';
  whisper.hidden = true;
  visitor.contentRoot.append(shopName, shopGridRoot, offerInfo, buy, whisper, retry);
  function input(label: string) {
    const n = document.createElement('input');
    n.type = 'text';
    n.setAttribute('aria-label', label);
    n.placeholder = label;
    n.dataset.uiText = '';
    return n;
  }
  function select(label: string) {
    const n = document.createElement('select');
    n.setAttribute('aria-label', label);
    n.dataset.uiText = '';
    return n;
  }
  function button(label: string, fn: () => void) {
    const n = document.createElement('button');
    n.type = 'button';
    n.className = 'ui-button';
    n.textContent = label;
    n.addEventListener('click', fn);
    return n;
  }
  function renderConditions() {
    conditionList.textContent = conditions
      .map(
        (c) =>
          (state.active ? state.stats[c.stat_id]?.label : c.stat_id) +
          ' ≥ ' +
          c.minimum,
      )
      .join(' AND ');
  }
  async function search(cursor: string) {
    if (pending || !state.active) return;
    if (Number(from.value) > Number(to.value)) {
      status.textContent = 'Upgrade from must not exceed to.';
      return;
    }
    const min = Number(priceMin.value),
      max = Number(priceMax.value);
    if (
      !Number.isSafeInteger(min) ||
      !Number.isSafeInteger(max) ||
      min < 0 ||
      max < min
    ) {
      status.textContent = 'Invalid Yang bounds.';
      return;
    }
    const p: MarketSearch =
      cursor && lastSearch
        ? { ...lastSearch, cursor }
        : {
            definition_id: definitions.value,
            upgrade_min: Number(from.value),
            upgrade_max: Number(to.value),
            price_min: min,
            price_max: max,
            affix_filters: conditions.map((c) => ({ ...c })),
            sort: sort.value as MarketSearch['sort'],
            cursor,
            limit: 20,
          };
    pending = true;
    status.textContent = 'Searching…';
    try {
      const r = await o.search(p);
      if (!disposed && !r.ok) status.textContent = r.error ?? 'Rejected';
    } finally {
      pending = false;
    }
  }
  async function purchase(replay = false) {
    if (pending || !state.active) return;
    if (
      !replay &&
      (!selected || !('active' in state.shop) || !state.shop.active)
    )
      return;
    if (!replay && selected?.price === null) return;
    if (!replay && selected && 'shopId' in state.shop)
      buyIntent = {
        command_id: marketCommandId(),
        shop_id: state.shop.shopId,
        offer_id: selected.id,
        revision: selected.revision,
        price: selected.price,
      };
    if (!buyIntent) return;
    pending = true;
    buy.disabled = true;
    retry.hidden = true;
    offerInfo.textContent = 'Waiting for server…';
    try {
      const r = await o.buy(buyIntent);
      if (disposed) return;
      offerInfo.textContent = r.ok ? 'Purchased.' : (r.error ?? 'Rejected');
      retry.hidden = r.ok || r.error !== 'timeout';
      if (r.ok) buyIntent = undefined;
      await o.visit(
        Number(
          buyIntent?.shop_id ??
            ('shopId' in state.shop ? state.shop.shopId : 0),
        ),
        selected?.id ?? '',
      );
    } catch {
      if (!disposed) {
        offerInfo.textContent = 'Unknown outcome.';
        retry.hidden = false;
      }
    } finally {
      pending = false;
      buy.disabled =
        !selected ||
        !state.active ||
        !('status' in state.shop) ||
        state.shop.status !== 'active' ||
        selected?.price === null;
    }
  }
  function choose(offer: MarketOffer) {
    selected = offer;
    offerInfo.textContent =
      offer.item.name + ' · ' + (offer.price === null ? 'Do negocjacji' : offer.price.toLocaleString('en-US') + ' Yang');
    whisper.hidden = offer.price !== null;
    buy.disabled =
      offer.price === null ||
      pending ||
      !state.active ||
      !('status' in state.shop) ||
      state.shop.status !== 'active';
    shopGridRoot
      .querySelectorAll('[data-id]')
      .forEach((n) =>
        n.classList.toggle(
          'market-highlight',
          (n as HTMLElement).dataset.id === offer.item.id,
        ),
      );
  }
  shell.listen(query, 'input', () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      void o.catalog(query.value);
    }, 200);
  });
  shell.listen(query, 'keydown', (e) => {
    if (e.key === 'Enter') void search('');
  });
  function render() {
    if (!state.active) return;
    const criteria = state.criteria,
      key = JSON.stringify(criteria ?? null),
      changed = key !== criteriaKey;
    if (changed && criteria) {
      lastSearch = structuredClone(criteria);
      from.value = String(criteria.upgrade_min);
      to.value = String(criteria.upgrade_max);
      priceMin.value = String(criteria.price_min);
      priceMax.value = String(criteria.price_max);
      sort.value = criteria.sort;
      conditions.splice(
        0,
        conditions.length,
        ...criteria.affix_filters.map((f) => ({ ...f })),
      );
    }
    criteriaKey = key;
    if (document.activeElement !== query && state.catalogQuery !== undefined)
      query.value = state.catalogQuery;
    const value =
      changed && criteria ? criteria.definition_id : definitions.value;
    definitions.replaceChildren(
      ...state.catalog.map((c) => new Option(c.name, c.definition_id)),
    );
    if (state.catalog.some((c) => c.definition_id === value))
      definitions.value = value;
    const statValue = stat.value;
    stat.replaceChildren(
      ...Object.entries(state.stats).map(
        ([id, s]) => new Option(s.label + ' (' + s.unit + ')', id),
      ),
    );
    if (state.stats[statValue]) stat.value = statValue;
    body.replaceChildren();
    for (const result of state.results) {
      const row = document.createElement('tr');
      row.tabIndex = 0;
      row.dataset.offerId = result.offerId;
      const cell = document.createElement('td'),
        icon = document.createElement('span');
      icon.className = 'market-result-icon';
      paintItemIcon(icon, result.item, { resolveItemIcon: o.resolveItemIcon });
      cell.append(icon, document.createTextNode(result.item.name));
      row.append(cell);
      for (const text of [
        String(result.item.quantity),
        result.price === null ? 'Do negocjacji' : result.price.toLocaleString('en-US'),
        result.shopName,
      ]) {
        const c = document.createElement('td');
        c.textContent = text;
        row.append(c);
      }
      row.addEventListener('pointermove', (e) => tooltip.show(e, result.item));
      row.addEventListener('pointerleave', () => tooltip.hide());
      const open = () => {
        tooltip.hide();
        void o.visit(result.shopId, result.offerId);
      };
      row.addEventListener('click', open);
      row.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') open();
      });
      body.append(row);
    }
    status.textContent =
      state.error ||
      (state.results.length
        ? 'Select a result to open its whole shop.'
        : 'No matching offers.');
    next.disabled = !state.cursor;
    if ('active' in state.shop && state.shop.active) {
      const openedShop = shopRoot.hidden;
      shopRoot.hidden = false;
      shopName.textContent = state.shop.name + ' · ' + state.shop.status;
      grid.render(
        { columns: 5, rows: 8, items: state.shop.offers.map((x) => x.item) },
        (item) => {
          const n = UiItemSlot({
            item,
            slotSize: 40,
            resolveItemIcon: o.resolveItemIcon,
          });
          const offer =
            state.active && 'active' in state.shop && state.shop.active
              ? state.shop.offers.find((x) => x.item.id === item.id)
              : undefined;
          if (offer) {
            n.addEventListener('click', () => choose(offer));
            n.addEventListener('pointermove', (e) => shopTooltip.show(e, item));
            n.addEventListener('pointerleave', () => shopTooltip.hide());
          }
          return n;
        },
      );
      const highlight = state.highlight;
      const chosen =
        state.shop.offers.find((x) => x.id === selected?.id) ??
        state.shop.offers.find((x) => x.id === highlight);
      selected = undefined;
      buy.disabled = true;
      whisper.hidden = true;
      if (openedShop) visitor.handle.activate();
      if (chosen) choose(chosen);
      else if (state.highlight)
        offerInfo.textContent = 'This offer is no longer available.';
    } else shopRoot.hidden = true;
    renderConditions();
    shell.refresh();
    visitor.refresh();
    o.regions();
  }
  return {
    regions: [shell.panel, visitor.panel],
    setState(v: MarketBrowserSnapshot) {
      const opened = root.hidden && v.active;
      state = v;
      root.hidden = !v.active;
      if (!v.active) {
        if (
          document.activeElement instanceof HTMLElement &&
          (root.contains(document.activeElement) ||
            shopRoot.contains(document.activeElement))
        )
          document.activeElement.blur();
        shopRoot.hidden = true;
        tooltip.hide();
        shopTooltip.hide();
      } else render();
      if (opened) shell.handle.activate();
    },
    closeIfActive() {
      if (root.hidden) return false;
      o.close();
      return true;
    },
    dispose() {
      disposed = true;
      if (timer) clearTimeout(timer);
      tooltip.dispose();
      shopTooltip.dispose();
      grid.dispose();
      shell.dispose();
      visitor.dispose();
    },
  };
}
