export function UiButton({ element = document.createElement('button'), label = '', className = '', onClick = () => { }, } = {}) {
    element.type = 'button';
    if (className)
        element.className = className;
    element.textContent = label;
    element.addEventListener('click', onClick);
    return {
        element,
        setDisabled(value) {
            element.disabled = !!value;
        },
        dispose() {
            element.removeEventListener('click', onClick);
        },
    };
}
