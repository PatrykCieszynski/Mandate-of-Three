// Content identity comes from ItemDefinition.icon_id, independently of UI glyphs.
export class ItemIconResolver {
  constructor(icons={},baseUrl=import.meta.url){this.replace(icons,baseUrl);}
  replace(icons={},baseUrl=import.meta.url){
    this.icons=new Map(Object.entries(icons).filter(([id,path])=>id&&typeof path==='string'&&path).map(([id,path])=>[id,new URL(path,baseUrl).href]));
  }
  resolve(icon_id){return this.icons.get(icon_id)||null;}
}
