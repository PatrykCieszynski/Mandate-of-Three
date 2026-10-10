import type { UpgradeSnapshot, UpgradeCommand } from './upgrade-model.js';
import type {
  CommandResult,
  WalletSnapshot,
} from '../../protocol/contracts.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type {
  ItemPresentation,
  ResolveItemIcon,
} from '../../game-ui/item-types.js';
import type { ItemDragRuntime } from '../../game-ui/drag/item-drag-runtime.js';
import type { InventorySnapshot } from '../../protocol/contracts.js';
import type { NpcInteractionSnapshot } from '../npc/npc-model.js';
import { UiWindow } from '../../core/window/ui-window.js';
import { UiButton } from '../../core/primitives/ui-button.js';
import { UiSlot } from '../../core/primitives/ui-slot.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { itemRarity } from '../../game-ui/items/item-tooltip-model.js';
import {
  OwnedItemDragSubject,
  itemWindowControls,
} from '../../game-ui/items/item-drag-policy.js';
import { npcOpening, NpcServiceKind } from '../npc/npc-model.js';
import {
  MAX_UPGRADE_LEVEL,
  previewItemLevel,
  upgradeExample,
  upgradePreview,
} from './upgrade-preview.js';
export function mountUpgrade(
  root: HTMLElement,
  options: {
    manager: WindowManager;
    drag: ItemDragRuntime;
    resolveItemIcon: ResolveItemIcon;
    onClose: () => void;
    select?: (command: UpgradeCommand) => Promise<CommandResult>;
    execute?: (command: UpgradeCommand) => Promise<CommandResult>;
    devPreview?: boolean;
    onRegionsChanged?: () => void;
  },
) {
  let recipe: UpgradeSnapshot = { active: false },
    inventory: InventorySnapshot | null = null,
    wallet: WalletSnapshot = {},
    pending = false,
    generation = 0,
    notice = '';
  let item: ItemPresentation | null = null,
    level = 0,
    confirmed = false,
    key = '',
    disposed = false;
  const shell = new UiWindow(root, {
    id: 'upgrade',
    title: 'Upgrade',
    className: 'upgrade-window',
    manager: options.manager,
    placement: {
      kind: 'relative',
      target: 'inventory',
      side: 'left',
      align: 'start',
      gap: 12,
      fallback: {
        kind: 'viewport',
        anchor: 'top-left',
        offset: { x: 16, y: 180 },
      },
    },
    scrollBorder: 2,
    hideHorizontalOverflow: true,
    canDrag: () => !options.drag.active,
    onCancel: () => options.drag.cancel(),
    onClose: () => closeIfActive(),
    ...(options.onRegionsChanged
      ? { onRegionsChanged: options.onRegionsChanged }
      : {}),
  });
  shell.contentRoot.innerHTML = `<div class="upgrade-body"><div class="upgrade-item-summary"><div class="upgrade-item-target" aria-label="Item to upgrade"></div>
    <div class="upgrade-item-details"><h2 class="upgrade-name"></h2><p class="upgrade-category"></p>
    <p class="upgrade-prompt">Drag an Iron Sword from Inventory into the slot.</p></div></div>
    <div class="upgrade-comparison"><p class="upgrade-transition"></p><div class="upgrade-properties"></div>
    <div class="upgrade-affixes"></div><div class="upgrade-requirements"></div></div>
    <div class="upgrade-recipe"><div class="upgrade-material"><span class="upgrade-material-symbol" aria-hidden="true">◆</span><span class="upgrade-material-name"></span></div>
    <p class="upgrade-cost"></p><p class="upgrade-chance">Success: 100%</p></div>
    <p class="upgrade-max">Maximum upgrade level reached.</p></div>
    <p class="upgrade-notice">Preview only. Items and Yang are unchanged.</p>
    <div class="upgrade-confirmation" role="group" aria-label="Confirm upgrade" hidden><p class="upgrade-confirm-text"></p></div>
    <div class="upgrade-primary-actions upgrade-actions"></div>`;
  const find = <T extends HTMLElement = HTMLElement>(selector: string) =>
    root.querySelector<T>(selector)!;
  const target = find('.upgrade-item-target'),
    name = find('.upgrade-name'),
    confirmation = find('.upgrade-confirmation');
  const tip = ItemTooltip(root, { geometry: () => options.manager });
  const slot = UiSlot({
    className: 'ui-item-slot upgrade-slot',
    label: 'Item to upgrade',
  });
  target.append(slot);
  // Explicit opt-in on the separate dev page; never mount tooling in the game.
  const devControls = options.devPreview ? createDevControls() : undefined;
  function createDevControls() {
    const controls = document.createElement('div');
    controls.className = 'upgrade-preview-controls';
    controls.innerHTML =
      '<div class="upgrade-level-controls"><span>Preview level</span><output class="upgrade-level" aria-label="Preview level">+0</output></div>';
    const output = controls.querySelector<HTMLOutputElement>('output')!;
    const example = UiButton({
      label: 'Preview Iron Sword',
      className: 'upgrade-example',
      onClick: () => choose(upgradeExample),
    });
    const previous = UiButton({ label: '−', onClick: () => changeLevel(-1) });
    const next = UiButton({ label: '+', onClick: () => changeLevel(1) });
    previous.element.setAttribute('aria-label', 'Previous preview level');
    next.element.setAttribute('aria-label', 'Next preview level');
    output.before(previous.element);
    output.after(next.element);
    controls.append(example.element);
    find('.upgrade-notice').before(controls);
    return { element: controls, output, example, previous, next };
  }
  function changeLevel(delta: number) {
    if (!options.devPreview || !item || confirmed) return;
    level = Math.max(0, Math.min(MAX_UPGRADE_LEVEL, level + delta));
    tip.hide();
    render();
  }
  const upgrade = UiButton({
    label: 'Upgrade',
    className: 'upgrade-cta',
    onClick: () => {
      if (!canUpgrade()) return;
      confirmed = true;
      tip.hide();
      render();
      yes.element.focus({ preventScroll: true });
    },
  });
  const cancel = UiButton({
    label: 'Cancel',
    className: 'upgrade-cancel',
    onClick: () => closeIfActive(),
  });
  const yes = UiButton({
    label: 'Confirm',
    className: 'upgrade-cta',
    onClick: () => {
      if (!confirmed || !item || !canUpgrade()) return;
      confirmed = false;
      if (options.devPreview) {
        level++;
        render();
        return;
      }
      void submit('execute', item);
    },
  });
  const no = UiButton({
    label: 'Back',
    onClick: () => {
      confirmed = false;
      render();
      upgrade.element.focus({ preventScroll: true });
    },
  });
  const confirmActions = document.createElement('div');
  confirmActions.className = 'upgrade-actions';
  confirmActions.append(yes.element, no.element);
  confirmation.append(confirmActions);
  find('.upgrade-primary-actions').append(upgrade.element, cancel.element);
  shell.listen(slot, 'pointermove', (event) => {
    if (item && !options.drag.active && !confirmed)
      tip.show(event, presentation()!.current);
  });
  shell.listen(slot, 'pointerleave', () => tip.hide());
  const bindings = itemWindowControls(options.drag, root);
  bindings.push(
    options.drag.registerControl(confirmation, 'cancel'),
    options.drag.registerControl(find('.upgrade-primary-actions'), 'cancel'),
    options.drag.registerTarget<OwnedItemDragSubject | null>({
      element: target,
      preview: (payload) => {
        const subject =
          payload.subject instanceof OwnedItemDragSubject &&
          payload.subject.container === 'inventory'
            ? payload.subject
            : null;
        const valid =
          !confirmed &&
          !pending &&
          !!subject &&
          (options.devPreview
            ? previewItemLevel(subject.item) !== null
            : !!recipe.active &&
              subject.item.definition_id === recipe.itemDefinitionId &&
              subject.item.upgrade_level === recipe.fromLevel);
        const marker = document.createElement('div');
        marker.className = 'upgrade-drop-preview' + (valid ? '' : ' invalid');
        marker.textContent = valid ? 'Select item' : 'Iron Sword required';
        return {
          valid,
          data: subject,
          visual: { element: marker, parent: target },
        };
      },
      drop: (_payload, preview) => {
        if (preview.valid && preview.data) choose(preview.data.item);
      },
    }),
  );
  if (devControls)
    bindings.push(options.drag.registerControl(devControls.element, 'cancel'));
  function choose(value: ItemPresentation) {
    const initial = options.devPreview
      ? previewItemLevel(value)
      : (value.upgrade_level ?? null);
    if (!options.devPreview) {
      if (initial !== null && initial === 0 && !root.hidden && !disposed)
        void submit('select', value);
      return;
    }
    if (initial === null || root.hidden || disposed) return;
    options.drag.cancel();
    item = structuredClone(value);
    level = initial;
    confirmed = false;
    tip.hide();
    render();
  }
  function canUpgrade() {
    if (!item || pending) return false;
    if (options.devPreview) return level < MAX_UPGRADE_LEVEL;
    return (
      recipe.active &&
      'id' in recipe.candidate &&
      recipe.candidate.level === recipe.fromLevel &&
      recipe.materialOwned >= recipe.materialAmount &&
      wallet.ready === true &&
      (wallet.balance ?? 0) >= recipe.yangCost
    );
  }
  async function submit(action: 'select' | 'execute', value: ItemPresentation) {
    if (!recipe.active || pending || disposed) return;
    const token = generation;
    const command = {
      npc_instance_id: recipe.npcInstanceId,
      service_id: recipe.serviceId,
      id: value.id,
      revision: value.revision,
    };
    pending = true;
    notice = '';
    render();
    let result: CommandResult;
    try {
      result = (await options[action]?.(command)) ?? {
        ok: false,
        error: 'unavailable',
      };
    } catch {
      result = { ok: false, error: 'timeout' };
    }
    if (disposed || token !== generation) return;
    pending = false;
    notice = result.ok
      ? action === 'execute'
        ? 'Upgrade successful.'
        : ''
      : `Rejected: ${result.error ?? 'request'}`;
    render();
  }
  function syncCandidate() {
    if (options.devPreview || !recipe.active) return;
    const candidate = recipe.candidate;
    item =
      'id' in candidate
        ? (inventory?.items.find(
            (i) => i.id === candidate.id && i.revision === candidate.revision,
          ) ?? null)
        : null;
    level = 'level' in candidate ? candidate.level : 0;
  }
  function presentation() {
    if (!item) return null;
    if (options.devPreview) return upgradePreview(item, level);
    const candidate = recipe.active ? recipe.candidate : {};
    const next =
      recipe.active &&
      'level' in candidate &&
      candidate.level === recipe.fromLevel
        ? {
            ...item,
            name: item.name.replace(/ \+[0-9]$/, ` +${recipe.toLevel}`),
            tooltip: {
              ...item.tooltip,
              properties: [`Attack: ${candidate.nextAttack}`],
            },
          }
        : null;
    return {
      current: {
        ...item,
        tooltip: {
          ...item.tooltip,
          properties: item.tooltip?.properties ?? [],
        },
      },
      next,
      cost: recipe.active ? recipe.yangCost : 0,
      materialCount: recipe.active ? recipe.materialAmount : 0,
    };
  }
  function lines(selector: string, values: readonly string[]) {
    const node = find(selector);
    node.replaceChildren(
      ...values.map((text) => {
        const p = document.createElement('p');
        p.textContent = text;
        return p;
      }),
    );
    node.hidden = !values.length;
  }
  function render() {
    if (disposed) return;
    const preview = presentation();
    slot.style.height = `${(item?.height ?? 2) * 40 - 2}px`;
    if (preview)
      paintItemIcon(slot, preview.current, {
        resolveItemIcon: options.resolveItemIcon,
        quantity: false,
      });
    else {
      slot.replaceChildren();
      const empty = document.createElement('span');
      empty.className = 'upgrade-empty-slot';
      empty.textContent = '+';
      slot.append(empty);
    }
    name.textContent = preview?.current.name ?? 'Select an item';
    name.dataset.rarity = itemRarity(item?.tooltip?.affixes?.length ?? 0);
    find('.upgrade-category').textContent = item?.tooltip?.category ?? '';
    find('.upgrade-category').hidden = !item?.tooltip?.category;
    find('.upgrade-prompt').hidden = !!item;
    find('.upgrade-comparison').hidden = !item;
    find('.upgrade-transition').textContent = preview?.next
      ? `+${level} → +${level + 1}`
      : `+${level}`;
    lines(
      '.upgrade-properties',
      (preview?.current.tooltip.properties ?? []).map((line, index) => {
        const nextLine = preview?.next?.tooltip.properties[index];
        const currentLine = line.replace(/^Attack: /, 'Attack ');
        return nextLine && nextLine !== line
          ? `${currentLine} → ${nextLine.replace(/^Attack: /, '')}`
          : currentLine;
      }),
    );
    lines(
      '.upgrade-affixes',
      item?.tooltip?.affixes?.flatMap((affix) => [...affix.lines]) ?? [],
    );
    lines('.upgrade-requirements', item?.tooltip?.requirements ?? []);
    find('.upgrade-recipe').hidden = !preview?.next;
    find('.upgrade-material-name').textContent = options.devPreview
      ? `Upgrade material × ${preview?.materialCount ?? 0}`
      : recipe.active
        ? `${recipe.materialName} × ${recipe.materialAmount} (owned: ${recipe.materialOwned})`
        : '';
    find('.upgrade-cost').textContent =
      `${(preview?.cost ?? 0).toLocaleString('en-US')} Yang`;
    find('.upgrade-max').hidden = !item || !!preview?.next;
    find('.upgrade-max').textContent = options.devPreview
      ? 'Maximum upgrade level reached.'
      : 'Only +0 → +1 is available.';
    find('.upgrade-notice').textContent = options.devPreview
      ? 'Preview only. Items and Yang are unchanged.'
      : pending
        ? 'Waiting for server…'
        : notice ||
          (recipe.active
            ? 'The item stays in Inventory. Upgrade consumes material and Yang.'
            : 'Waiting for upgrade service…');
    if (devControls) {
      devControls.previous.setDisabled(!item || confirmed || level === 0);
      devControls.next.setDisabled(
        !item || confirmed || level === MAX_UPGRADE_LEVEL,
      );
      devControls.output.value = `+${level}`;
      devControls.example.setDisabled(confirmed);
    }
    confirmation.hidden = !confirmed;
    find('.upgrade-confirm-text').textContent =
      `Upgrade to ${preview?.next?.name ?? ''} for ${(preview?.cost ?? 0).toLocaleString('en-US')} Yang?`;
    upgrade.element.hidden = confirmed;
    cancel.element.hidden = confirmed;
    upgrade.setDisabled(!canUpgrade());
    yes.setDisabled(!canUpgrade());
    no.setDisabled(pending);
    shell.refresh();
    options.onRegionsChanged?.();
  }
  function closeIfActive() {
    if (root.hidden) return false;
    options.drag.cancel();
    tip.hide();
    if (confirmed && !pending) {
      confirmed = false;
      render();
      upgrade.element.focus({ preventScroll: true });
    } else options.onClose();
    return true;
  }
  return {
    regions: [shell.panel],
    closeIfActive,
    setNpcState(snapshot: NpcInteractionSnapshot) {
      const opening = npcOpening(snapshot);
      const nextKey =
        snapshot.active &&
        opening.mode === 'service' &&
        opening.service.kind === NpcServiceKind.UPGRADE
          ? `${snapshot.npcInstanceId}:${opening.service.id}`
          : '';
      if (key !== nextKey) {
        generation++;
        pending = false;
        notice = '';
        item = null;
        level = 0;
        confirmed = false;
        tip.hide();
      }
      const wasHidden = root.hidden;
      key = nextKey;
      root.hidden = !key;
      render();
      if (key && wasHidden) shell.handle.activate();
    },
    setInventory(snapshot: InventorySnapshot) {
      inventory = snapshot;
      if (!options.devPreview) {
        syncCandidate();
        render();
        return;
      }
      if (!item || item.id === upgradeExample.id) return;
      const current = snapshot.items.find((entry) => entry.id === item!.id);
      if (!current || previewItemLevel(current) === null) {
        item = null;
        confirmed = false;
        tip.hide();
        render();
      } else if (current.revision !== item.revision) choose(current);
    },
    setState(snapshot: UpgradeSnapshot) {
      const changed =
        recipe.active !== snapshot.active ||
        (recipe.active &&
          snapshot.active &&
          (recipe.npcInstanceId !== snapshot.npcInstanceId ||
            recipe.serviceId !== snapshot.serviceId));
      if (changed) {
        generation++;
        pending = false;
        confirmed = false;
        notice = '';
      }
      recipe = structuredClone(snapshot);
      syncCandidate();
      if (!recipe.active && !options.devPreview) item = null;
      render();
    },
    setWallet(snapshot: WalletSnapshot) {
      wallet = snapshot;
      render();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      generation++;
      bindings.forEach((binding) => binding.dispose());
      [upgrade, cancel, yes, no].forEach((button) => button.dispose());
      if (devControls)
        [devControls.example, devControls.previous, devControls.next].forEach(
          (button) => button.dispose(),
        );
      tip.dispose();
      shell.dispose();
    },
  };
}
