import { UiWindow } from '../../core/window/ui-window.js';
import { UiButton } from '../../core/primitives/ui-button.js';
export function mountNpcServiceMenu(root, options) {
    const shell = new UiWindow(root, {
        id: 'npc-menu',
        title: 'NPC Services',
        className: 'npc-window',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'top-left',
            offset: { x: 320, y: 180 },
        },
        onClose: options.onClose,
        ...(options.onRegionsChanged
            ? { onRegionsChanged: options.onRegionsChanged }
            : {}),
    });
    const list = document.createElement('div');
    list.className = 'npc-services';
    const status = document.createElement('p');
    status.className = 'npc-status';
    status.setAttribute('role', 'status');
    shell.contentRoot.append(list, status);
    let buttons = [];
    return {
        regions: [shell.panel],
        setState(snapshot, pending = false, error = '') {
            buttons.forEach((button) => button.dispose());
            buttons = [];
            list.replaceChildren();
            status.textContent = error;
            status.hidden = !error;
            shell.panel.querySelector('h1').textContent = snapshot.active
                ? snapshot.name
                : 'NPC Services';
            if (snapshot.active)
                for (const service of snapshot.services) {
                    const button = UiButton({
                        label: service.label,
                        className: 'npc-service',
                        onClick: () => options.onSelect(service),
                    });
                    button.element.dataset.serviceId = service.id;
                    button.element.dataset.kind = String(service.kind);
                    if (service.iconId)
                        button.element.dataset.iconId = service.iconId;
                    button.setDisabled(!service.enabled || pending);
                    buttons.push(button);
                    list.append(button.element);
                }
            shell.refresh();
        },
        activate() {
            shell.handle.activate();
        },
        refresh() {
            shell.refresh();
        },
        dispose() {
            buttons.forEach((button) => button.dispose());
            shell.dispose();
        },
    };
}
