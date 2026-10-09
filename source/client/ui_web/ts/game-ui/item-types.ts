export type ItemIconId = string;
export interface ItemPresentation {
  id: string; revision: number; name: string; icon_id: ItemIconId;
  height: number; quantity: number; description?: string;
}
export type ResolveItemIcon = (id: ItemIconId) => string | null;
