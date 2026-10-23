export const attributes = ['STR', 'DEX', 'VIT', 'INT'] as const;
export type Attribute = (typeof attributes)[number];
export interface StatsData {
  attributes: Record<Attribute, string>;
  level: string;
  experience: string;
  xp_to_next: string;
  xp_fraction: number;
  available_points: string;
  available_skill_points: string;
  revision: string;
  combat: Record<string, number>;
}
export interface StatsSnapshot {
  opened: boolean;
  ready: boolean;
  busy: boolean;
  pending: boolean;
  pending_attribute: string;
  error: string;
  data?: StatsData;
  vitals: { hp?: number; mp?: number };
}
export function isStats(value: unknown): value is StatsSnapshot {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const s = value as Record<string, unknown>;
  const object = (v: unknown): v is Record<string, unknown> =>
    !!v && typeof v === 'object' && !Array.isArray(v);
  const decimal = (v: unknown) =>
    typeof v === 'string' &&
    /^(0|[1-9][0-9]{0,18})$/.test(v) &&
    BigInt(v) <= 9223372036854775807n;
  const finite = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
  if (
    !['opened', 'ready', 'busy', 'pending'].every(
      (k) => typeof s[k] === 'boolean',
    ) ||
    typeof s.error !== 'string' ||
    s.error.length > 160 ||
    typeof s.pending_attribute !== 'string' ||
    !['', ...attributes].includes(s.pending_attribute) ||
    !object(s.vitals) ||
    !Object.entries(s.vitals).every(
      ([k, v]) => ['hp', 'mp'].includes(k) && finite(v) && Number(v) >= 0,
    )
  )
    return false;
  if (s.data === undefined) return s.ready === false;
  const d = s.data;
  if (!object(d) || !object(d.attributes)) return false;
  const a = d.attributes;
  return (
    object(d) &&
    object(d.attributes) &&
    attributes.every((k) => decimal(a[k])) &&
    [
      'level',
      'experience',
      'xp_to_next',
      'available_points',
      'available_skill_points',
      'revision',
    ].every((k) => decimal(d[k])) &&
    d.level !== '0' &&
    d.xp_to_next !== '0' &&
    finite(d.xp_fraction) &&
    Number(d.xp_fraction) >= 0 &&
    Number(d.xp_fraction) <= 1 &&
    object(d.combat) &&
    Object.values(d.combat).every(finite)
  );
}
