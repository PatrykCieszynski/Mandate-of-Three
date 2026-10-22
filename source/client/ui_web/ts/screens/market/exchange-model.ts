import { isObject } from '../../protocol.js';
export interface ExchangeAsset {
  asset_id: string;
  name: string;
  stack_limit: number;
  free: number;
  reserved: number;
}
export interface ExchangeOrder {
  id: string;
  asset: string;
  side: 'buy' | 'sell';
  quantity: number;
  remaining: number;
  reserved: number;
  received: number;
  priceNum: number;
  priceDen: number;
  revision: number;
  status: 'active' | 'filled' | 'cancelled';
}
export interface ExchangeDepth {
  side: 'buy' | 'sell';
  asset: string;
  remaining: number;
  priceNum: number;
  priceDen: number;
}
export type ExchangeSnapshot =
  | { active: false }
  | {
      active: true;
      ledgerOnly?: boolean;
      yang: number;
      reservedYang: number;
      assets: ExchangeAsset[];
      orders: ExchangeOrder[];
      depth: ExchangeDepth[];
      fills: { id: number; asset: string; quantity: number; yang: number }[];
      busy: boolean;
      retryAvailable: boolean;
    };
export interface ExchangeDeposit {
  command_id: string;
  uid: string;
  revision: number;
  amount: number;
  source: 'bag' | 'account_storage';
}
export interface ExchangeWithdraw {
  command_id: string;
  asset_id: string;
  amount: number;
  destination: 'bag' | 'claim';
}
export interface ExchangePlace {
  command_id: string;
  have_asset: string;
  want_asset: string;
  quantity: number;
  price_num: number;
  price_den: number;
}
export interface ExchangeCancel {
  command_id: string;
  order_id: string;
  revision: number;
}
export type ExchangeCommand =
  ExchangeDeposit | ExchangeWithdraw | ExchangePlace | ExchangeCancel;
const int = (v: unknown, min = 0, max = 9000000000000000) =>
  typeof v === 'number' && Number.isSafeInteger(v) && v >= min && v <= max;
const price = (v: Record<string, unknown>) =>
  int(v.priceNum, 1, 1000000000) && int(v.priceDen, 1, 1000000000);
export function isExchangeSnapshot(v: unknown): v is ExchangeSnapshot {
  if (!isObject(v) || typeof v.active !== 'boolean') return false;
  if (!v.active) return Object.keys(v).length === 1;
  return (
    int(v.yang) &&
    int(v.reservedYang) &&
    Number(v.reservedYang) <= Number(v.yang) &&
    typeof v.busy === 'boolean' &&
    typeof v.retryAvailable === 'boolean' &&
    (!('ledgerOnly' in v) || typeof v.ledgerOnly === 'boolean') &&
    Array.isArray(v.assets) &&
    v.assets.length <= 32 &&
    v.assets.every(
      (a) =>
        isObject(a) &&
        typeof a.asset_id === 'string' &&
        typeof a.name === 'string' &&
        int(a.stack_limit, 1, 10000) &&
        int(a.free) &&
        int(a.reserved),
    ) &&
    Array.isArray(v.orders) &&
    v.orders.length <= 50 &&
    v.orders.every(
      (o) =>
        isObject(o) &&
        typeof o.id === 'string' &&
        /^[a-f0-9]{32}$/.test(o.id) &&
        typeof o.asset === 'string' &&
        (o.side === 'buy' || o.side === 'sell') &&
        int(o.quantity, 1) &&
        int(o.remaining) &&
        Number(o.remaining) <= Number(o.quantity) &&
        int(o.reserved) &&
        int(o.received) &&
        price(o) &&
        int(o.revision) &&
        (o.status === 'active' ||
          o.status === 'filled' ||
          o.status === 'cancelled'),
    ) &&
    Array.isArray(v.depth) &&
    v.depth.length <= 20 &&
    v.depth.every(
      (d) =>
        isObject(d) &&
        (d.side === 'buy' || d.side === 'sell') &&
        typeof d.asset === 'string' &&
        int(d.remaining, 1) &&
        price(d),
    ) &&
    Array.isArray(v.fills) &&
    v.fills.length <= 20 &&
    v.fills.every(
      (f) =>
        isObject(f) &&
        int(f.id, 1) &&
        typeof f.asset === 'string' &&
        int(f.quantity, 1) &&
        int(f.yang, 1),
    )
  );
}
