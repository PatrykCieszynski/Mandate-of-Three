// One replaceable skin boundary; exact legacy copies are optional and ignored.
export const icons = {};
try {
  const {skin} = await import('./legacy_skin/skin.js');
  for (const [name, path] of Object.entries(skin.chrome))
    document.documentElement.style.setProperty(`--skin-${name}`, `url("${new URL(path, import.meta.url)}")`);
  if (skin.chrome["close-normal"]) document.documentElement.classList.add("has-skin");
  Object.assign(icons, Object.fromEntries(Object.entries(skin.icons).map(([name,path]) => [name,new URL(path,import.meta.url).href])));
} catch { /* Clean checkout uses the CSS skin and text icon fallback. */ }
