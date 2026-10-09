// Only this adapter knows the optional, exact legacy PNG staging location.
const chromeKeys={
  'window-fill':'window.frame','title-center':'window.title','slot':'slot.normal','yang':'currency.yang','equipment-base':'equipment.background',
  'close-normal':'button.close.normal','close-hover':'button.close.hover','close-pressed':'button.close.pressed',
  ...Object.fromEntries(['tl','tr','bl','br'].map(corner=>['corner-'+corner,'window.frame.corner.'+corner])),
  ...Object.fromEntries(['top','bottom','left','right'].map(edge=>['edge-'+edge,'window.frame.edge.'+edge]))
};
export async function loadLegacySkin(){
  try {
    const {skin,itemIcons,uiIcons}=await import('../inventory/legacy_skin/skin.js');
    // Old local manifests used paths relative to inventory/skin.js.
    const base=new URL('../inventory/skin.js',import.meta.url);
    const urls=entries=>Object.fromEntries(Object.entries(entries||{}).map(([key,path])=>[key,new URL(path,base).href]));
    const assets=skin.assets||Object.fromEntries(Object.entries(skin.chrome||{}).map(([key,path])=>[chromeKeys[key],path]).filter(([key])=>key));
    return {skin:{assets:urls(assets)},itemIcons:urls(itemIcons||skin.icons),uiIcons:uiIcons||{currencies:assets['currency.yang']?{yang:urls(assets)['currency.yang']}:{}}};
  }catch{return {skin:{assets:{}},itemIcons:{},uiIcons:{}};}
}
