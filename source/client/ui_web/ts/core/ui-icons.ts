import type {UiIconGroups, UiIconId, UiIconDomain} from '../contracts.js';
export const uiIconDomains: readonly UiIconDomain[]=Object.freeze(['buffs','debuffs','status','skills','actions','currencies','quests','glyphs']);
// Global UI presentation icons. Item content has a separate resolver.
export class UiIconRegistry {
  declare icons: Map<string, string>;
  declare listeners: Set<() => void>;
  constructor(){this.icons=new Map();this.listeners=new Set();}
  replace(groups: UiIconGroups={},baseUrl: string | URL=import.meta.url){
    const next=new Map();
    for(const [domain,icons] of Object.entries(groups)){
      if(!uiIconDomains.some(known => known === domain))throw new Error('Unknown UI icon domain: '+domain);
      for(const [id,path] of Object.entries(icons)){
        if(!id||typeof path!=='string'||!path)continue;
        next.set(domain+'.'+id,new URL(path,baseUrl).href);
      }
    }
    this.icons=next;for(const listener of this.listeners)listener();
  }
  resolve(id: UiIconId | undefined){return (id===undefined?null:this.icons.get(id))||null;}
  subscribe(listener: () => void){this.listeners.add(listener);return ()=>this.listeners.delete(listener);}
}
export const uiIcons=new UiIconRegistry();
