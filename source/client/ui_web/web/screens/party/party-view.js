import { UiWindow } from '../../core/window/ui-window.js';
export function isParty(value) {
    if (!value || typeof value !== 'object')
        return false;
    const p = value, id = (v) => Number.isSafeInteger(v) && Number(v) >= 0, person = (v) => !!v &&
        typeof v === 'object' &&
        id(v.id) &&
        typeof v.name === 'string' &&
        Number.isSafeInteger(v.level);
    return (id(p.id) &&
        id(p.leader) &&
        id(p.self) &&
        typeof p.xp_mode === 'string' &&
        ['equal', 'by_level', 'carry'].includes(p.xp_mode) &&
        typeof p.drop_mode === 'string' &&
        ['round_robin', 'by_damage', 'free'].includes(p.drop_mode) &&
        Array.isArray(p.members) &&
        p.members.length <= 8 &&
        p.members.every((m) => person(m) &&
            typeof m.online === 'boolean' &&
            typeof m.same_instance === 'boolean' &&
            id(m.hp) &&
            id(m.max_hp)) &&
        Array.isArray(p.candidates) &&
        p.candidates.length <= 64 &&
        p.candidates.every(person) &&
        !!p.invite &&
        typeof p.invite === 'object' &&
        (!('from' in p.invite) || id(p.invite.from)) &&
        (!('name' in p.invite) || typeof p.invite.name === 'string') &&
        (!('opened' in p) || typeof p.opened === 'boolean'));
}
export function mountParty(root, options) {
    const shell = new UiWindow(root, {
        id: 'party',
        title: 'Party · P',
        className: 'party-window',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'top-left',
            offset: { x: 20, y: 110 },
        },
        onClose: options.close,
        onRegionsChanged: options.regions,
    });
    const content = document.createElement('div');
    content.className = 'party-content';
    shell.contentRoot.append(content);
    let state, pending = false, error = '', structure = '', draftXp = 'equal', draftDrop = 'round_robin';
    const button = (label, cmd) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.textContent = label;
        b.disabled = pending;
        b.onclick = () => {
            void send(cmd);
        };
        return b;
    };
    async function send(command) {
        if (pending)
            return;
        pending = true;
        error = '';
        render();
        try {
            const result = await options.command(command);
            if (!result.ok)
                error = result.error ?? 'request';
        }
        catch {
            error = 'timeout';
        }
        finally {
            pending = false;
            render();
        }
    }
    function render() {
        if (!state)
            return;
        root.hidden = state.opened === false;
        content.replaceChildren();
        const heading = document.createElement('p');
        heading.textContent = state.id
            ? `Party ${state.members.length}/8`
            : 'No party';
        content.append(heading);
        if (state.invite.from) {
            const invitation = document.createElement('p');
            invitation.textContent = `Invitation from ${state.invite.name}`;
            content.append(invitation, button('Accept', { action: 'accept' }), button('Decline', { action: 'decline' }));
        }
        for (const member of state.members) {
            const row = document.createElement('div');
            row.className = 'party-member';
            const label = document.createElement('span');
            label.textContent = `${member.id === state.leader ? '★ ' : ''}${member.name} · Lv ${member.level}${member.online ? (member.same_instance ? '' : ' · other instance') : ' · offline'}`;
            const hp = document.createElement('progress');
            hp.max = Math.max(1, member.max_hp);
            hp.value = member.hp;
            hp.setAttribute('aria-label', `${member.name} HP`);
            hp.dataset.member = String(member.id);
            row.append(label, hp);
            if (state.leader === state.self && member.id !== state.self)
                row.append(button('Leader', { action: 'leader', target: member.id }), button('Kick', { action: 'kick', target: member.id }));
            content.append(row);
        }
        if (!state.id || state.leader === state.self) {
            const select = document.createElement('select');
            select.setAttribute('aria-label', 'Invite player');
            for (const candidate of state.candidates) {
                const option = document.createElement('option');
                option.value = String(candidate.id);
                option.textContent = `${candidate.name} · Lv ${candidate.level}`;
                select.append(option);
            }
            const invite = document.createElement('button');
            invite.textContent = 'Invite';
            invite.disabled = pending || state.candidates.length === 0;
            invite.onclick = () => {
                void send({ action: 'invite', target: Number(select.value) });
            };
            content.append(select, invite);
        }
        if (state.id) {
            if (state.leader === state.self) {
                const xp = document.createElement('select'), drop = document.createElement('select');
                xp.setAttribute('aria-label', 'EXP mode');
                drop.setAttribute('aria-label', 'Drop mode');
                for (const mode of ['equal', 'by_level', 'carry']) {
                    const o = document.createElement('option');
                    o.value = mode;
                    o.textContent = mode;
                    xp.append(o);
                }
                for (const mode of ['round_robin', 'by_damage', 'free']) {
                    const o = document.createElement('option');
                    o.value = mode;
                    o.textContent = mode;
                    drop.append(o);
                }
                xp.value = draftXp;
                drop.value = draftDrop;
                xp.onchange = () => {
                    draftXp = xp.value;
                };
                drop.onchange = () => {
                    draftDrop = drop.value;
                };
                xp.disabled = pending;
                drop.disabled = pending;
                const apply = document.createElement('button');
                apply.textContent = 'Apply modes';
                apply.disabled = pending;
                apply.onclick = () => {
                    void send({
                        action: 'modes',
                        xp_mode: xp.value,
                        drop_mode: drop.value,
                    });
                };
                content.append(xp, drop, apply);
            }
            else {
                const mode = document.createElement('p');
                mode.textContent = `EXP: ${state.xp_mode} · Drop: ${state.drop_mode}`;
                content.append(mode);
            }
            content.append(button('Leave party', { action: 'leave' }));
        }
        if (error) {
            const notice = document.createElement('p');
            notice.setAttribute('role', 'status');
            notice.textContent = error;
            content.append(notice);
        }
        shell.refresh();
        options.regions();
    }
    return {
        regions: [shell.panel],
        setState(value) {
            if (state?.id !== value.id ||
                state.xp_mode !== value.xp_mode ||
                state.drop_mode !== value.drop_mode) {
                draftXp = value.xp_mode;
                draftDrop = value.drop_mode;
            }
            const next = JSON.stringify({
                ...value,
                members: value.members.map(({ hp, max_hp, ...member }) => member),
            });
            state = value;
            if (next === structure) {
                for (const member of value.members) {
                    const hp = root.querySelector(`progress[data-member="${member.id}"]`);
                    if (hp) {
                        hp.max = Math.max(1, member.max_hp);
                        hp.value = member.hp;
                    }
                }
                return;
            }
            structure = next;
            render();
        },
        dispose() {
            shell.dispose();
        },
    };
}
