const paths: Record<string, string>={
blade:'<path d="M15 34 31 5 35 3 34 9 20 37Z" fill="#c8c8ac"/><path d="m12 29 13 7m-10-2-5 8" stroke="#bd985a" stroke-width="3"/>',
spear:'<path d="M9 40 29 9" stroke="#ad8050" stroke-width="3"/><path d="m25 11 5-9 6 3-5 10Z" fill="#bbc6b3"/>',
potion:'<path d="M17 4h10v9l5 7v19H12V20l5-7Z" fill="#942e32" stroke="#d5aa72"/><path d="M17 4h10v6H17Z" fill="#b5a78b"/><path d="M16 22v11" stroke="#ffb9a0" stroke-width="2"/>',
mana:'<path d="M17 4h10v9l5 7v19H12V20l5-7Z" fill="#235985" stroke="#a3bdcf"/><path d="M17 4h10v6H17Z" fill="#b5a78b"/><path d="M16 22v11" stroke="#b5e2ff" stroke-width="2"/>',
helm:'<path d="M10 32V17Q22-3 34 17v15l-9 7-3-17-3 17Z" fill="#6d7466" stroke="#ceb787"/><path d="M10 21h24M22 6v16" stroke="#e1c698"/>',
armor:'<path d="m12 5 10 5 10-5 9 10-8 6-3-5v23H14V16l-3 5-8-6Z" fill="#596553" stroke="#baa271"/><path d="M22 10v28m-7-17h14" stroke="#c0af86"/>',
boots:'<path d="M10 7h10v20l5 8v5H7V29ZM26 7h10v20l5 8v5H23V29Z" fill="#735335" stroke="#baa271"/>',
ring:'<circle cx="22" cy="25" r="12" fill="none" stroke="#c7a362" stroke-width="4"/><path d="m22 5 6 8-6 6-6-6Z" fill="#67aaa0" stroke="#d6be7f"/>',
material:'<path d="m8 16 14-9 15 10-3 20-20 2Z" fill="#657775" stroke="#afc2ad"/><path d="m8 16 15 7 14-6m-14 6-9 16" fill="none" stroke="#b0c4c0"/>',
scroll:'<path d="M12 8h23l-7 29H7Z" fill="#a88a57" stroke="#dac18b"/><path d="m16 14 12 0m-14 6h12m-14 6h10" stroke="#573a24" stroke-width="2"/>'};
export const icon = (kind: string) => `<svg viewBox="0 0 44 44" aria-hidden="true">${paths[kind]??paths.material}</svg>`;
