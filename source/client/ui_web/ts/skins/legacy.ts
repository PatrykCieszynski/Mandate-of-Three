import type {AssetPaths, Skin, SkinKey, UiIconGroups} from '../core/assets/types.js';
import {isObject} from '../protocol.js';
import {uiIconDomains} from '../core/assets/types.js';
// Only this adapter knows the optional, exact legacy PNG staging location.
const chromeKeys: Record<string, SkinKey>={
  'window-fill':'window.frame','title-center':'window.title','slot':'slot.normal','yang':'currency.yang','equipment-base':'equipment.background',
  'close-normal':'button.close.normal','close-hover':'button.close.hover','close-pressed':'button.close.pressed',
  'corner-tl':'window.frame.corner.tl','corner-tr':'window.frame.corner.tr','corner-bl':'window.frame.corner.bl','corner-br':'window.frame.corner.br',
  'edge-top':'window.frame.edge.top','edge-bottom':'window.frame.edge.bottom','edge-left':'window.frame.edge.left','edge-right':'window.frame.edge.right'
};
export async function loadLegacySkin(): Promise<{skin: Skin; itemIcons: AssetPaths; uiIcons: UiIconGroups}> {
  try {
    const manifestPath='../inventory/legacy_skin/skin.js';
    const manifest: unknown=await import(manifestPath);
    if(!isObject(manifest)||!isObject(manifest.skin))throw new Error('Invalid legacy skin');
    const {skin,itemIcons,uiIcons}=manifest;
    // Old local manifests used paths relative to inventory/skin.js.
    const base=new URL('../inventory/skin.js',import.meta.url);
    const urls=(entries: unknown): AssetPaths=>{
      if(entries === undefined)return {};
      if(!isObject(entries))throw new Error('Invalid asset paths');
      return Object.fromEntries(Object.entries(entries).map(([key,path])=>{
        if(typeof path!=='string')throw new Error('Invalid asset path');
        return [key,new URL(path,base).href];
      }));
    };
    const chrome=isObject(skin.chrome)?skin.chrome:{};
    const assets=skin.assets||Object.fromEntries(Object.entries(chrome).flatMap(([key,path])=>{
      const semantic=chromeKeys[key];return semantic?[[semantic,path]]:[];
    }));
    const groups: UiIconGroups={};
    if(uiIcons){
      if(!isObject(uiIcons))throw new Error('Invalid UI icons');
      for(const domain of uiIconDomains){
        if(domain in uiIcons)groups[domain]=urls(uiIcons[domain]);
      }
    }else groups.currencies=isObject(assets)&&assets['currency.yang']?{yang:urls(assets)['currency.yang'] ?? ''}:{};
    return {skin:{assets:urls(assets)},itemIcons:urls(itemIcons||skin.icons),uiIcons:groups};
  }catch{return {skin:{assets:{}},itemIcons:{},uiIcons:{}};}
}
