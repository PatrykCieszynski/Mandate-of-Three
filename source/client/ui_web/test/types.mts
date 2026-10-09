import type {WebBridge} from '../web/bridge.js';
import type {ItemIconId} from '../web/game-ui/item-types.js';
import type {UiIconId, Skin} from '../web/core/assets/types.js';
import type {DomainSnapshot} from '../web/protocol/contracts.js';
import {UiWindow} from '../web/core/window/ui-window.js';
import type {WindowManager} from '../web/core/window/window-manager.js';
// Negative examples make strict contract regressions fail the test compilation.
export function checkContracts(bridge: WebBridge,manager: WindowManager,root: HTMLElement) {
  bridge.request('inventory.move_item',{id:'item',revision:1,x:0,y:0,page:0});
  // @ts-expect-error A move needs the complete identity and position.
  bridge.request('inventory.move_item',{x:1});
  // @ts-expect-error Native command names are explicit.
  bridge.request('get_tree().quit',{});
  // @ts-expect-error Stable window identity is required.
  manager.register({element:root});
  // @ts-expect-error Registration has no renderer callback contract.
  manager.register({id:'test',element:root,paint:()=>{}});
  // @ts-expect-error Content is composed through contentRoot.
  new UiWindow(root,{id:'test',title:'Test',manager,content:'<p>Test</p>'});
  // @ts-expect-error Relative placement requires an explicit side.
  manager.register({id:'test',element:root,placement:{kind:'relative',target:'inventory'}});
  // @ts-expect-error Geometry is numeric.
  manager.setViewport({width:'1920',height:1080});
  const itemId: ItemIconId='sword';
  // @ts-expect-error Content identifiers do not become UI icon identifiers.
  const uiId: UiIconId=itemId;
  // @ts-expect-error Skins supply semantic assets, not inventory geometry.
  const skin: Skin={assets:{'inventory.columns':'5'}};
  // @ts-expect-error View snapshots do not accept unchecked item records.
  const state: DomainSnapshot={inventory:{columns:5,rows:9,pages:4,items:[{id:'item'}]}};
  return {uiId,skin,state};
}
