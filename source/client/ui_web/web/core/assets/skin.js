// Asset-only allowlist: a skin cannot supply sizes, footprints or gameplay rules.
import { skinKeys } from './skin-keys.js';
export { skinKeys } from './skin-keys.js';
export const skinVariable = (key) => '--skin-' + key.replaceAll('.', '-');
export function loadImage(url) {
    return new Promise(resolve => { const image = new Image(); image.onload = () => resolve(true); image.onerror = () => resolve(false); image.src = url; });
}
export async function applySkin(root, skin = {}, { baseUrl = import.meta.url, loadAsset = loadImage } = {}) {
    const assets = Object.fromEntries(await Promise.all(skinKeys.map(async (key) => {
        const path = skin.assets?.[key];
        if (typeof path !== 'string' || !path)
            return [key, null];
        try {
            const url = new URL(path, baseUrl).href;
            return [key, await loadAsset(url) ? url : null];
        }
        catch {
            return [key, null];
        }
    })));
    for (const key of ['button.close.hover', 'button.close.pressed'])
        assets[key] ||= assets['button.close.normal'] ?? null;
    for (const key of skinKeys)
        root.style.setProperty(skinVariable(key), assets[key] ? `url(${JSON.stringify(assets[key])})` : 'none');
    root.classList.toggle('has-close-asset', !!assets['button.close.normal']);
    root.classList.toggle('has-equipment-skin', !!assets['equipment.background']);
    return assets;
}
