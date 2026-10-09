// Asset-only allowlist; runtime keys and TypeScript identifiers share one source.
export const skinKeys=Object.freeze(['window.frame','window.title',
  'window.frame.corner.tl','window.frame.corner.tr','window.frame.corner.bl','window.frame.corner.br',
  'window.frame.edge.top','window.frame.edge.bottom','window.frame.edge.left','window.frame.edge.right',
  'button.close.normal','button.close.hover','button.close.pressed','slot.normal','tab.normal','tab.active','currency.yang','equipment.background'] as const);
export type SkinKey = typeof skinKeys[number];
