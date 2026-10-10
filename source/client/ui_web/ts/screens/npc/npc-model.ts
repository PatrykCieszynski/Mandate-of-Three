import type { ItemCommand } from '../../protocol/contracts.js';
// Wire values match NpcServiceDefinition.Kind. Never infer kinds from labels.
export enum NpcServiceKind {
  SHOP = 0,
  UPGRADE = 1,
  STORAGE = 2,
  QUEST = 3,
}
export interface NpcServicePresentation {
  id: string;
  kind: NpcServiceKind;
  label: string;
  iconId?: string;
  enabled: boolean;
}
export type NpcInteractionSnapshot =
  | { active: false }
  | {
      active: true;
      npcInstanceId: string;
      npcDefinitionId: string;
      name: string;
      services: NpcServicePresentation[];
      selectedServiceId: string;
    };
// Local presentation intent only; a future Upgrade command must revalidate this item.
export interface NpcServiceOpeningContext {
  preselectedItem?: ItemCommand;
}
export interface NpcServiceSelection {
  npcInstanceId: string;
  service: NpcServicePresentation;
  context?: NpcServiceOpeningContext;
}
export function npcOpening(
  snapshot: NpcInteractionSnapshot,
):
  | { mode: 'none' }
  | { mode: 'menu' }
  | { mode: 'select' | 'service'; service: NpcServicePresentation } {
  if (!snapshot.active) return { mode: 'none' };
  const enabled = snapshot.services.filter((service) => service.enabled);
  const selected = enabled.find(
    (service) => service.id === snapshot.selectedServiceId,
  );
  if (selected) return { mode: 'service', service: selected };
  if (enabled.length === 1 && enabled[0])
    return { mode: 'select', service: enabled[0] };
  return { mode: enabled.length > 1 ? 'menu' : 'none' };
}
