import type { ItemPresentation } from '../../game-ui/item-types.js';
// Temporary presentation fixture. No gameplay recipe, roll, wallet or item mutation.
export const MAX_UPGRADE_LEVEL = 9;
export const upgradeExample: ItemPresentation = {
  id: 'upgrade-preview',
  revision: 0,
  name: 'Żelazny miecz +0',
  icon_id: 'iron_sword',
  height: 2,
  quantity: 1,
  tooltip: { category: 'Sword', properties: ['Attack: 10'] },
};
export function previewItemLevel(item: ItemPresentation): number | null {
  if (item.icon_id !== 'iron_sword' || item.quantity !== 1) return null;
  const match = / \+([0-9])$/.exec(item.name);
  return match ? Number(match[1]) : null;
}
export function upgradePreview(item: ItemPresentation, level: number) {
  const original = previewItemLevel(item);
  if (
    original === null ||
    !Number.isInteger(level) ||
    level < 0 ||
    level > MAX_UPGRADE_LEVEL
  )
    throw Error('Unsupported upgrade preview');
  const name = item.name.replace(/ \+[0-9]$/, ''),
    next = level < MAX_UPGRADE_LEVEL ? level + 1 : null;
  const properties = (at: number) =>
    (item.tooltip?.properties ?? []).map((line) => {
      const attack = /^Attack: (-?\d+(?:\.\d+)?)$/.exec(line);
      return attack
        ? `Attack: ${Number(attack[1]) + (at - original) * 2}`
        : line;
    });
  return {
    current: {
      ...item,
      name: `${name} +${level}`,
      tooltip: { ...item.tooltip, properties: properties(level) },
    },
    next:
      next === null
        ? null
        : {
            ...item,
            name: `${name} +${next}`,
            tooltip: { ...item.tooltip, properties: properties(next) },
          },
    cost: next === null ? null : next * 1000,
    materialCount: next === null ? null : Math.ceil(next / 3),
  };
}
