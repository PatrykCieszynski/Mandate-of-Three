import { element as findElement } from '../dom.js';
import { windowTemplate } from './generated/ui-window-template.js';
export function createWindowShell(root, { id, title, className }) {
    root.innerHTML = windowTemplate;
    root.setAttribute('data-ui-window', id);
    const panel = findElement(root, 'section', 'section');
    for (const name of className.split(/\s+/).filter(Boolean))
        panel.classList.add(name);
    panel.id = id + '-window';
    panel.setAttribute('aria-label', title);
    panel.style.left = '0px';
    panel.style.top = '0px';
    return {
        panel,
        header: findElement(panel, '.window-header', 'header'),
        content: findElement(panel, '.window-content', 'div'),
    };
}
