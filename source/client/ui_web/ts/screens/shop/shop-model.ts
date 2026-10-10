import type { ItemTooltipDetails } from '../../game-ui/items/item-tooltip-model.js';
export interface ShopOfferPresentation {
  offerId: string;
  itemDefinitionId: string;
  name: string;
  iconId: string;
  height: number;
  quantity: number;
  price: number;
  description?: string;
  tooltip?: ItemTooltipDetails;
}
export type ShopSnapshot =
  | { active: false }
  | {
      active: true;
      npcInstanceId: string;
      serviceId: string;
      shopId: string;
      name: string;
      currency: 'yang';
      offers: ShopOfferPresentation[];
    };
export type ShopBuyCommand = {
  npc_instance_id: string;
  service_id: string;
  offer_id: string;
} & (
  | { x?: never; y?: never; page?: never }
  | { x: number; y: number; page: number }
);
