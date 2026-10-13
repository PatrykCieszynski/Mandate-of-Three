import type { InventoryItem } from '../../protocol/contracts.js';
import type { ItemPresentation } from '../../game-ui/item-types.js';
import { isObject, isItem } from '../../protocol.js';
export interface MarketOffer {
  id: string;
  revision: number;
  price: number;
  item: InventoryItem;
}
export type MarketSnapshot =
  | { active: false }
  | {
      active: true;
      shopId: number;
      name: string;
      status: 'active' | 'paused';
      revision: number;
      columns: 5;
      rows: 8;
      offers: MarketOffer[];
      claims: ItemPresentation[];
    };
export interface MarketCommand {
  command_id: string;
  shop_id?: number;
  uid?: string;
  offer_id?: string;
  revision?: number;
  position?: number;
  price?: number;
  name?: string;
  status?: 'active' | 'paused';
}
const integer = (v: unknown, min = 0, max = 9000000000000000) =>
  typeof v === 'number' && Number.isSafeInteger(v) && v >= min && v <= max;
export function isMarketSnapshot(v: unknown): v is MarketSnapshot {
  if (!isObject(v) || typeof v.active !== 'boolean') return false;
  if (!v.active) return Object.keys(v).length === 1;
  return (
    integer(v.shopId, 1) &&
    typeof v.name === 'string' &&
    v.name.length > 0 &&
    v.name.length <= 40 &&
    (v.status === 'active' || v.status === 'paused') &&
    integer(v.revision) &&
    v.columns === 5 &&
    v.rows === 8 &&
    Array.isArray(v.offers) &&
    v.offers.length <= 40 &&
    v.offers.every(
      (o) =>
        isObject(o) &&
        typeof o.id === 'string' &&
        /^[a-f0-9]{32}$/.test(o.id) &&
        integer(o.revision) &&
        integer(o.price, 1) &&
        isItem(o.item) &&
        isObject(o.item) &&
        integer(o.item.x, 0, 4) &&
        integer(o.item.y, 0, 7) &&
        o.item.page === 0 &&
        Number(o.item.y) + o.item.height <= 8,
    ) &&
    Array.isArray(v.claims) &&
    v.claims.length <= 20 &&
    v.claims.every(isItem)
  );
}
export class OwnMarketOffer {
  constructor(readonly offer: MarketOffer) {}
}

export function marketCommandId() {
  return (
    globalThis.crypto?.randomUUID?.() ??
    'market_' + Date.now() + '_' + Math.random().toString(16).slice(2)
  );
}
