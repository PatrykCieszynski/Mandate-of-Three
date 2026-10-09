import { UiButton } from './ui-button.js';
export function UiTab({ label, onSelect, }) {
    const button = UiButton({ label, className: 'ui-tab', onClick: onSelect });
    button.element.setAttribute('role', 'tab');
    return {
        ...button,
        setSelected(value) {
            button.element.setAttribute('aria-selected', String(!!value));
        },
    };
}
