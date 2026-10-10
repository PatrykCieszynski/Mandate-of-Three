import type { ItemCommand } from '../../protocol/contracts.js';
export type UpgradeSnapshot =
  | { active: false }
  | {
      active: true;
      npcInstanceId: string;
      serviceId: string;
      upgradeId: string;
      itemDefinitionId: string;
      itemName: string;
      fromLevel: 0;
      toLevel: 1;
      yangCost: number;
      materialDefinitionId: string;
      materialName: string;
      materialAmount: number;
      materialOwned: number;
      successRate: 100;
      candidate:
        | Record<string, never>
        | (ItemCommand & { level: number; attack: number; nextAttack: number });
    };
export type UpgradeCommand = ItemCommand & {
  npc_instance_id: string;
  service_id: string;
};
export interface NpcDropTarget {
  npcInstanceId: string;
  serviceId: string;
  itemDefinitionId: string;
  fromLevel: number;
  x: number;
  y: number;
  w: number;
  h: number;
}
export interface NpcDropTargets {
  width: number;
  height: number;
  targets: NpcDropTarget[];
}
