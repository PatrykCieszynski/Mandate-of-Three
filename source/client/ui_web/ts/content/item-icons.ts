import type {AssetPaths} from '../core/assets/types.js';
import type {ItemIconId} from '../game-ui/item-types.js';
// Content identity comes from ItemDefinition.icon_id, independently of UI glyphs.
export class ItemIconResolver {
  declare icons: Map<ItemIconId, string>;
  constructor(icons: AssetPaths={},baseUrl: string | URL=import.meta.url){this.replace(icons,baseUrl);}
  replace(icons: AssetPaths={},baseUrl: string | URL=import.meta.url){
    this.icons=new Map(Object.entries(icons).filter(([id,path])=>id&&typeof path==='string'&&path).map(([id,path])=>[id,new URL(path,baseUrl).href]));
  }
  resolve(icon_id: ItemIconId){return this.icons.get(icon_id)||null;}
}
