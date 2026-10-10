import { UiWindow } from '../../core/window/ui-window.js';
import type { WindowManager } from '../../core/window/window-manager.js';
import type { CommandResult } from '../../protocol/contracts.js';
import { mountNpcServiceMenu } from './npc-service-menu.js';
import { NpcServiceKind, npcOpening } from './npc-model.js';
import type {
  NpcInteractionSnapshot,
  NpcServicePresentation,
  NpcServiceOpeningContext,
  NpcServiceSelection,
} from './npc-model.js';
// NPC composition owns 0/1/many routing. Feature screens never decide that policy.
export function mountNpcInteraction(
  menuRoot: HTMLElement,
  serviceRoot: HTMLElement,
  options: {
    manager: WindowManager;
    selectService: (selection: NpcServiceSelection) => Promise<CommandResult>;
    onClose: () => void;
    clearService?: () => void;
    handlesService?: (kind: NpcServiceKind) => boolean;
    onServiceOpened?: (selection: NpcServiceSelection) => void;
    onRegionsChanged?: () => void;
  },
) {
  let state: NpcInteractionSnapshot = { active: false },
    pending = false,
    disposed = false,
    error = '',
    autoKey = '',
    generation = 0;
  let openingContext: NpcServiceOpeningContext | undefined,
    lastOpened = '';
  const menu = mountNpcServiceMenu(menuRoot, {
    manager: options.manager,
    onSelect: (service) => {
      void openService(service);
    },
    onClose: closeSelectedService,
    ...(options.onRegionsChanged
      ? { onRegionsChanged: options.onRegionsChanged }
      : {}),
  });
  // Explicit service target stub: domains replace its content when their slice lands.
  const target = new UiWindow(serviceRoot, {
    id: 'npc-service',
    title: 'NPC Service',
    className: 'npc-window',
    manager: options.manager,
    placement: {
      kind: 'viewport',
      anchor: 'top-left',
      offset: { x: 320, y: 180 },
    },
    onClose: closeSelectedService,
    ...(options.onRegionsChanged
      ? { onRegionsChanged: options.onRegionsChanged }
      : {}),
  });
  const notice = document.createElement('p');
  notice.className = 'npc-service-notice';
  target.contentRoot.append(notice);
  function render() {
    const opening = npcOpening(state),
      wasMenu = menuRoot.hidden,
      wasService = serviceRoot.hidden;
    const showMenu = opening.mode === 'menu' || error !== '';
    menuRoot.hidden = !showMenu;
    serviceRoot.hidden =
      opening.mode !== 'service' ||
      !!options.handlesService?.(opening.service.kind);
    menu.setState(state, pending, error);
    if (opening.mode === 'service' && state.active) {
      autoKey = '';
      target.panel.querySelector('h1')!.textContent = opening.service.label;
      notice.textContent = 'This service is not available yet.';
      if (!serviceRoot.hidden) {
        target.refresh();
        if (wasService) target.handle.activate();
      }
      const key = state.npcInstanceId + ':' + opening.service.id;
      if (key !== lastOpened) {
        lastOpened = key;
        options.onServiceOpened?.({
          npcInstanceId: state.npcInstanceId,
          service: opening.service,
          ...(openingContext ? { context: openingContext } : {}),
        });
      }
    } else lastOpened = '';
    if (showMenu && wasMenu) menu.activate();
    options.onRegionsChanged?.();
    if (opening.mode === 'select' && state.active) {
      const key = state.npcInstanceId + ':' + opening.service.id;
      if (autoKey !== key) {
        autoKey = key;
        void openService(opening.service);
      }
    }
  }
  function closeSelectedService() {
    if (
      state.active &&
      state.selectedServiceId &&
      state.services.filter((service) => service.enabled).length > 1 &&
      options.clearService
    )
      options.clearService();
    else options.onClose();
  }
  async function openService(
    service: NpcServicePresentation,
    context?: NpcServiceOpeningContext,
  ): Promise<CommandResult> {
    if (!state.active || pending || !service.enabled)
      return { ok: false, error: 'no_interaction' };
    const current = state.services.find(
      (entry) =>
        entry.id === service.id && entry.kind === service.kind && entry.enabled,
    );
    if (!current) return { ok: false, error: 'unknown_service' };
    openingContext = context;
    lastOpened = '';
    const requestGeneration = generation;
    pending = true;
    error = '';
    menu.setState(state, true);
    let result: CommandResult;
    try {
      result = await options.selectService({
        npcInstanceId: state.npcInstanceId,
        service: current,
        ...(context ? { context } : {}),
      });
    } catch (reason) {
      result = {
        ok: false,
        error: reason instanceof Error ? reason.message : 'request',
      };
    }
    if (!disposed && generation === requestGeneration) {
      pending = false;
      if (!result.ok) error = `Service rejected: ${result.error || 'request'}`;
      render();
    }
    return result;
  }
  return {
    regions: [...menu.regions, target.panel],
    openService,
    serviceFailed(selection: NpcServiceSelection, reason: string) {
      if (
        !state.active ||
        state.npcInstanceId !== selection.npcInstanceId ||
        state.selectedServiceId !== selection.service.id
      )
        return;
      error = `Service rejected: ${reason}`;
      render();
    },
    setState(snapshot: NpcInteractionSnapshot) {
      const changed =
        state.active !== snapshot.active ||
        (state.active &&
          snapshot.active &&
          state.npcInstanceId !== snapshot.npcInstanceId);
      if (changed) {
        generation++;
        pending = false;
        error = '';
        autoKey = '';
        openingContext = undefined;
        lastOpened = '';
      }
      state = structuredClone(snapshot);
      render();
    },
    closeIfActive() {
      if (!state.active) return false;
      closeSelectedService();
      return true;
    },
    dispose() {
      disposed = true;
      generation++;
      menu.dispose();
      target.dispose();
    },
  };
}
