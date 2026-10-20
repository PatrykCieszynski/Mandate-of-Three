import { isObject, isItem } from '../../protocol.js';
import { isMarketSnapshot, type MarketSnapshot } from './market-model.js';
import type { ItemPresentation } from '../../game-ui/item-types.js';
export interface MarketResult {
  offerId: string;
  shopId: number;
  shopName: string;
  revision: number;
  price: number | null;
  item: ItemPresentation;
}
export interface AffixFilter {
  stat_id: string;
  minimum: number;
}
export interface MarketSearch {
  definition_id: string;
  upgrade_min: number;
  upgrade_max: number;
  price_min: number;
  price_max: number;
  affix_filters: AffixFilter[];
  sort: 'price_asc' | 'price_desc';
  cursor: string;
  limit: number;
}
export type MarketBrowserSnapshot =
  | { active: false }
  | {
      active: true;
      purchasePending?: boolean;
      purchaseBusy?: boolean;
      catalogQuery?: string;
      criteria?: MarketSearch;
      catalog: { definition_id: string; name: string; icon_id: string }[];
      stats: Record<
        string,
        { label: string; unit: string; min: number; max: number }
      >;
      results: MarketResult[];
      cursor: string;
      shop: MarketSnapshot | Record<string, never>;
      highlight: string;
      error: string;
    };
const integer = (v: unknown, min = 0) =>
  typeof v === 'number' &&
  Number.isSafeInteger(v) &&
  v >= min &&
  v <= 9000000000000000;
export function isBrowserSnapshot(v: unknown): v is MarketBrowserSnapshot {
  if (!isObject(v) || typeof v.active !== 'boolean') return false;
  if (!v.active) return Object.keys(v).length === 1;
  return (
    (!('catalogQuery' in v) ||
      (typeof v.catalogQuery === 'string' && v.catalogQuery.length <= 80)) &&
    (!('purchasePending' in v) || typeof v.purchasePending === 'boolean') &&
    (!('purchaseBusy' in v) || typeof v.purchaseBusy === 'boolean') &&
    (!('criteria' in v) || isSearchCriteria(v.criteria)) &&
    Array.isArray(v.catalog) &&
    v.catalog.length <= 100 &&
    v.catalog.every(
      (i) =>
        isObject(i) &&
        typeof i.definition_id === 'string' &&
        typeof i.name === 'string' &&
        typeof i.icon_id === 'string',
    ) &&
    isObject(v.stats) &&
    Object.keys(v.stats).length <= 32 &&
    Object.values(v.stats).every(
      (s) =>
        isObject(s) &&
        typeof s.label === 'string' &&
        typeof s.unit === 'string' &&
        typeof s.min === 'number' &&
        Number.isFinite(s.min) &&
        typeof s.max === 'number' &&
        Number.isFinite(s.max),
    ) &&
    Array.isArray(v.results) &&
    v.results.length <= 50 &&
    v.results.every(
      (r) =>
        isObject(r) &&
        typeof r.offerId === 'string' &&
        /^[a-f0-9]{32}$/.test(r.offerId) &&
        integer(r.shopId, 1) &&
        typeof r.shopName === 'string' &&
        integer(r.revision) &&
        (r.price === null || integer(r.price, 1)) &&
        isItem(r.item),
    ) &&
    typeof v.cursor === 'string' &&
    v.cursor.length <= 64 &&
    isObject(v.shop) &&
    (Object.keys(v.shop).length === 0 || isMarketSnapshot(v.shop)) &&
    typeof v.highlight === 'string' &&
    v.highlight.length <= 32 &&
    typeof v.error === 'string'
  );
}

export function isSearchCriteria(v: unknown): v is MarketSearch {
  if (!isObject(v)) return false;
  const fields = [
    'definition_id',
    'upgrade_min',
    'upgrade_max',
    'price_min',
    'price_max',
    'affix_filters',
    'sort',
    'cursor',
    'limit',
  ];
  return (
    Object.keys(v).length === 9 &&
    fields.every((k) => k in v) &&
    typeof v.definition_id === 'string' &&
    v.definition_id.length <= 64 &&
    integer(v.upgrade_min) &&
    Number(v.upgrade_min) <= 9 &&
    integer(v.upgrade_max) &&
    Number(v.upgrade_max) <= 9 &&
    Number(v.upgrade_min) <= Number(v.upgrade_max) &&
    integer(v.price_min) &&
    integer(v.price_max) &&
    Number(v.price_min) <= Number(v.price_max) &&
    (v.sort === 'price_asc' || v.sort === 'price_desc') &&
    typeof v.cursor === 'string' &&
    v.cursor.length <= 64 &&
    integer(v.limit, 1) &&
    Number(v.limit) <= 50 &&
    Array.isArray(v.affix_filters) &&
    v.affix_filters.length <= 4 &&
    v.affix_filters.every(
      (f) =>
        isObject(f) &&
        typeof f.stat_id === 'string' &&
        f.stat_id.length <= 64 &&
        typeof f.minimum === 'number' &&
        Number.isFinite(f.minimum),
    )
  );
}
