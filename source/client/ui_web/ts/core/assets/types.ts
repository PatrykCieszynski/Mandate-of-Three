import type { SkinKey } from './skin-keys.js';
export type { SkinKey } from './skin-keys.js';
export type AssetPaths = Record<string, string>;
export type AssetLoader = (url: string) => Promise<boolean>;
export interface Skin {
  assets?: Partial<Record<SkinKey, string>>;
}
export const uiIconDomains = Object.freeze([
  'buffs',
  'debuffs',
  'status',
  'skills',
  'actions',
  'currencies',
  'quests',
  'glyphs',
] as const);
export type UiIconDomain = (typeof uiIconDomains)[number];
export type UiIconId = `${UiIconDomain}.${string}`;
export type UiIconGroups = Partial<Record<UiIconDomain, AssetPaths>>;
