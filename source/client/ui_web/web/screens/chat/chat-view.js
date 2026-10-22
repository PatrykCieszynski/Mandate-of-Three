import { UiWindow } from '../../core/window/ui-window.js';
export const channels = [
    'general',
    'trade',
    'local',
    'party',
    'guild',
];
export function isChatSnapshot(v) {
    if (!v || typeof v !== 'object')
        return false;
    const o = v, id = (x) => Number.isSafeInteger(x) && Number(x) >= 0;
    const message = (m) => {
        if (!m || typeof m !== 'object')
            return false;
        const x = m;
        return (id(x.id) &&
            id(x.sender) &&
            id(x.target) &&
            typeof x.name === 'string' &&
            x.name.length <= 128 &&
            typeof x.text === 'string' &&
            [...x.text].length <= 256 &&
            [...channels, 'system', 'whisper'].includes(x.channel));
    };
    return (id(o.self) &&
        typeof o.guild_available === 'boolean' &&
        Array.isArray(o.messages) &&
        o.messages.length <= 200 &&
        o.messages.every(message) &&
        Array.isArray(o.muted) &&
        o.muted.length <= 1024 &&
        o.muted.every(id) &&
        Array.isArray(o.conversations) &&
        o.conversations.length <= 16 &&
        o.conversations.every((c) => c &&
            id(c.id) &&
            typeof c.name === 'string' &&
            c.name.length <= 128 &&
            ['open', 'closed', 'minimized'].includes(c.mode) &&
            id(c.unread) &&
            Array.isArray(c.messages) &&
            c.messages.length <= 100 &&
            c.messages.every(message)));
}
export function mountChat(root, options) {
    let state = {
        self: 0,
        guild_available: false,
        messages: [],
        conversations: [],
        muted: [],
    }, expanded = false, filter = 'all', disposed = false;
    const whispers = new Map();
    const shell = new UiWindow(root, {
        id: 'chat',
        className: 'chat-window',
        title: 'Chat',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'bottom-left',
            offset: { x: 12, y: 12 },
        },
        onClose: () => {
            expanded = false;
            refreshMain();
        },
        onRegionsChanged: options.regions,
    });
    const content = shell.contentRoot;
    content.classList.add('chat-content');
    const tabs = document.createElement('nav'), log = document.createElement('div'), form = document.createElement('form'), channel = document.createElement('select'), input = document.createElement('input'), notice = document.createElement('p');
    notice.setAttribute('role', 'status');
    log.className = 'chat-log';
    log.setAttribute('role', 'log');
    input.dataset.uiText = '';
    input.maxLength = 512;
    input.setAttribute('aria-label', 'Chat message');
    channel.setAttribute('aria-label', 'Send channel');
    const button = (label, action) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.textContent = label;
        b.onclick = action;
        return b;
    };
    const command = async (type, p) => {
        try {
            const result = await options.command(type, p);
            notice.textContent = result.ok
                ? ''
                : String(result.error ?? 'Request rejected').replaceAll('_', ' ');
            return result.ok;
        }
        catch {
            notice.textContent = 'No response. Message delivery is uncertain.';
            return false;
        }
    };
    const open = (id, name) => {
        if (id !== state.self && id > 0)
            void command('chat.open', { target: id, name });
    };
    function paintLog(element, messages, privateLog = false) {
        const near = element.scrollHeight - element.scrollTop - element.clientHeight < 32, top = element.scrollTop;
        element.replaceChildren();
        for (const m of messages) {
            const row = document.createElement('p');
            row.className = `chat-line channel-${m.channel}`;
            const name = button(privateLog
                ? m.sender === state.self
                    ? 'You'
                    : m.name
                : `[${m.channel}] ${m.name}`, () => open(m.sender, m.name));
            if (m.channel === 'system')
                name.disabled = true;
            const text = document.createElement('span');
            text.textContent = `: ${m.text}`;
            row.append(name, text);
            element.append(row);
        }
        if (near)
            element.scrollTop = element.scrollHeight;
        else
            element.scrollTop = top;
    }
    function refreshMain() {
        root.classList.toggle('chat-expanded', expanded);
        paintLog(log, state.messages
            .filter((m) => filter === 'all' || m.channel === filter)
            .slice(expanded ? 0 : -5));
        shell.refresh();
        options.regions();
    }
    for (const name of ['all', ...channels])
        tabs.append(button(name, () => {
            filter = name;
            refreshMain();
        }));
    tabs.append(button('History', () => {
        expanded = !expanded;
        refreshMain();
    }));
    for (const name of channels) {
        const o = document.createElement('option');
        o.value = name;
        o.textContent = name;
        channel.append(o);
    }
    form.append(channel, input);
    content.append(tabs, log, form, notice);
    const find = document.createElement('input');
    find.dataset.uiText = '';
    find.maxLength = 64;
    find.setAttribute('aria-label', 'Whisper player name');
    find.placeholder = 'Whisper player name';
    const findButton = button('Whisper', () => {
        void command('chat.send', { action: 'lookup', name: find.value.trim() });
    });
    content.append(find, findButton);
    form.onsubmit = (e) => {
        e.preventDefault();
        const text = input.value.trim();
        if (!text)
            return;
        void command('chat.send', {
            action: 'send',
            channel: channel.value,
            text,
        }).then((ok) => {
            if (ok && input.value.trim() === text)
                input.value = '';
        });
    };
    const blur = (field) => {
        field.blur();
    };
    const keys = (e) => {
        if (e.key === 'Escape' &&
            e.target instanceof HTMLElement &&
            root.ownerDocument.activeElement?.matches('[data-ui-text]')) {
            e.preventDefault();
            e.stopImmediatePropagation();
            blur(root.ownerDocument.activeElement);
            return;
        }
        if (e.key === 'Enter' &&
            !e.repeat &&
            e.target instanceof HTMLElement &&
            !e.target.matches('input,textarea,select,[contenteditable]') &&
            !e.target.closest('[data-ui-window]')) {
            e.preventDefault();
            input.focus();
        }
    };
    document.addEventListener('keydown', keys, true);
    find.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            findButton.click();
        }
    });
    function createWhisper(c) {
        const r = document.createElement('main');
        r.className = 'chat-whisper';
        r.id = `whisper-${c.id}`;
        document.body.append(r);
        const w = new UiWindow(r, {
            id: r.id,
            className: 'whisper-window',
            title: `Whisper · ${c.name}`,
            manager: options.manager,
            placement: {
                kind: 'viewport',
                anchor: 'bottom-left',
                offset: { x: 510 + whispers.size * 24, y: -110 - whispers.size * 24 },
            },
            onClose: () => {
                field.blur();
                void command('chat.conversation', { target: c.id, mode: 'closed' });
            },
            onRegionsChanged: options.regions,
        });
        const history = document.createElement('div');
        history.className = 'chat-log';
        history.setAttribute('role', 'log');
        const field = document.createElement('input');
        field.dataset.uiText = '';
        field.maxLength = 512;
        field.setAttribute('aria-label', `Message ${c.name}`);
        const f = document.createElement('form');
        f.append(field);
        f.onsubmit = (e) => {
            e.preventDefault();
            const text = field.value.trim();
            if (text)
                void command('chat.send', {
                    action: 'send',
                    channel: 'whisper',
                    target: c.id,
                    text,
                }).then((ok) => {
                    if (ok && field.value.trim() === text)
                        field.value = '';
                });
        };
        const minimize = button('Minimize', () => {
            field.blur();
            void command('chat.conversation', { target: c.id, mode: 'minimized' });
        });
        const mute = button('Mute / unmute', () => {
            void command('chat.mute', {
                target: c.id,
                muted: !state.muted.includes(c.id),
            });
        });
        w.contentRoot.append(minimize, mute, history, f);
        const badge = button('', () => {
            void command('chat.conversation', { target: c.id, mode: 'open' });
        });
        badge.className = 'chat-whisper-badge';
        w.contentRoot.append(badge);
        const entry = {
            root: r,
            shell: w,
            log: history,
            input: field,
            badge,
            last: '',
        };
        whispers.set(c.id, entry);
        return entry;
    }
    return {
        get regions() {
            return [shell.panel, ...[...whispers.values()].map((w) => w.shell.panel)];
        },
        focus() {
            input.focus();
        },
        escape() {
            const active = document.activeElement;
            if (active instanceof HTMLElement && active.matches('[data-ui-text]')) {
                active.blur();
                return true;
            }
            return false;
        },
        setState(value) {
            if (disposed)
                return;
            state = value;
            const guild = channel.querySelector('option[value="guild"]');
            if (guild) {
                guild.disabled = !state.guild_available;
                guild.textContent = state.guild_available
                    ? 'guild'
                    : 'guild (unavailable)';
            }
            refreshMain();
            for (const [id, w] of whispers)
                if (!state.conversations.some((c) => c.id === id)) {
                    w.shell.dispose();
                    w.root.remove();
                    whispers.delete(id);
                }
            for (const c of state.conversations) {
                const w = whispers.get(c.id) ?? createWhisper(c);
                w.root.hidden = c.mode === 'closed';
                w.root.classList.toggle('chat-minimized', c.mode === 'minimized');
                w.badge.textContent = `${c.name} (${c.unread} unread) · Open`;
                w.badge.hidden = c.mode !== 'minimized';
                if (c.mode !== 'open')
                    w.input.blur();
                const next = JSON.stringify(c.messages);
                if (w.last !== next) {
                    paintLog(w.log, c.messages, true);
                    w.last = next;
                }
                w.shell.refresh();
            }
            options.regions();
        },
        dispose() {
            disposed = true;
            document.removeEventListener('keydown', keys, true);
            input.blur();
            find.blur();
            shell.dispose();
            for (const w of whispers.values()) {
                w.input.blur();
                w.shell.dispose();
                w.root.remove();
            }
            whispers.clear();
        },
    };
}
