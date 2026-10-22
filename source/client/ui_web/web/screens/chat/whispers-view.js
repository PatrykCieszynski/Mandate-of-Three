import { UiWindow } from '../../core/window/ui-window.js';
// One window; stable per-character panes retain drafts and reading position.
export function mountWhispers(options, command) {
    const root = document.createElement('main');
    root.id = 'private-chat';
    root.className = 'chat-whisper';
    root.hidden = true;
    const dockRoot = document.createElement('aside');
    dockRoot.id = 'whisper-notifications';
    dockRoot.hidden = true;
    document.body.append(root, dockRoot);
    let state;
    let disposed = false;
    const panes = new Map();
    const current = () => state?.conversations.find((c) => c.mode === 'open');
    const action = (label, run) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.onclick = run;
        return button;
    };
    const option = (text, value) => {
        const o = document.createElement('option');
        o.textContent = text;
        o.value = value;
        return o;
    };
    const select = (id) => {
        void command('chat.conversation', { target: id, mode: 'open' });
    };
    const minimize = () => {
        const c = current();
        if (c) {
            panes.get(c.id)?.field.blur();
            void command('chat.conversation', { target: c.id, mode: 'minimized' });
        }
    };
    const shell = new UiWindow(root, {
        id: root.id,
        title: 'Private messages',
        className: 'whisper-window',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'bottom-left',
            offset: { x: 510, y: -70 },
        },
        onClose: minimize,
        onRegionsChanged: options.regions,
    });
    const dock = new UiWindow(dockRoot, {
        id: dockRoot.id,
        title: 'Private conversations',
        className: 'whisper-dock',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'top-right',
            offset: { x: -12, y: 190 },
        },
        onRegionsChanged: options.regions,
    });
    const tabs = document.createElement('div');
    tabs.className = 'whisper-tabs';
    tabs.setAttribute('role', 'tablist');
    tabs.setAttribute('aria-label', 'Private conversations');
    const overflow = document.createElement('select');
    overflow.className = 'whisper-conversations';
    overflow.setAttribute('aria-label', 'All private conversations');
    overflow.onchange = () => {
        if (overflow.value)
            select(Number(overflow.value));
    };
    const row = document.createElement('div');
    row.className = 'whisper-tab-row';
    row.append(tabs, overflow);
    const controls = document.createElement('div');
    controls.className = 'whisper-controls';
    const recipient = document.createElement('span');
    recipient.className = 'whisper-recipient';
    const mute = action('Mute', () => {
        const c = current();
        if (c)
            void command('chat.mute', {
                target: c.id,
                muted: !state.muted.includes(c.id),
            });
    });
    const close = action('Close conversation', () => {
        const c = current();
        if (!c)
            return;
        panes.get(c.id)?.field.blur();
        const next = state.conversations.find((other) => other.id !== c.id && other.mode !== 'closed');
        void command('chat.conversation', { target: c.id, mode: 'closed' }).then((ok) => {
            if (ok && next && !disposed && !current())
                select(next.id);
        });
    });
    controls.append(recipient, mute, close, action('Minimize', minimize));
    shell.contentRoot.append(row, controls);
    const envelope = action('', () => {
        const choices = state?.conversations ?? [];
        const c = choices.find((c) => c.unread > 0) ??
            current() ??
            choices.find((c) => c.mode !== 'closed') ??
            choices[0];
        if (c)
            select(c.id);
    });
    envelope.className = 'whisper-envelope';
    dock.contentRoot.append(envelope);
    function create(c) {
        const pane = document.createElement('section');
        pane.id = `whisper-${c.id}`;
        pane.setAttribute('role', 'tabpanel');
        pane.setAttribute('aria-label', `Conversation with ${c.name}`);
        const tab = action(c.name, () => select(c.id));
        tab.id = `whisper-tab-${c.id}`;
        tab.setAttribute('role', 'tab');
        tab.setAttribute('aria-controls', pane.id);
        pane.setAttribute('aria-labelledby', tab.id);
        tabs.append(tab);
        const log = document.createElement('div');
        log.className = 'chat-log';
        log.setAttribute('role', 'log');
        const field = document.createElement('input');
        field.dataset.uiText = '';
        field.maxLength = 512;
        const form = document.createElement('form');
        const send = document.createElement('button');
        send.type = 'submit';
        send.textContent = 'Send';
        form.append(field, send);
        pane.append(log, form);
        shell.contentRoot.append(pane);
        form.onsubmit = (e) => {
            e.preventDefault();
            const text = field.value.trim();
            if (!text)
                return;
            // Capture this pane/recipient; switching tabs while awaiting cannot clear another draft.
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
        const entry = { root: pane, tab, log, field, last: '' };
        panes.set(c.id, entry);
        return entry;
    }
    function paint(c, pane, self) {
        const signature = JSON.stringify(c.messages);
        if (signature === pane.last)
            return;
        const follow = pane.log.scrollHeight - pane.log.scrollTop - pane.log.clientHeight < 32;
        const top = pane.log.scrollTop;
        pane.log.replaceChildren();
        for (const m of c.messages) {
            const row = document.createElement('p');
            row.className = 'chat-line channel-whisper';
            row.textContent = `${m.sender === self ? 'You' : m.name}: ${m.text}`;
            pane.log.append(row);
        }
        pane.log.scrollTop = follow ? pane.log.scrollHeight : top;
        pane.last = signature;
    }
    return {
        get regions() {
            return [shell.panel, dock.panel];
        },
        setState(value) {
            state = value;
            const active = current();
            root.hidden = !active;
            for (const [id, p] of panes)
                if (!value.conversations.some((c) => c.id === id)) {
                    p.field.blur();
                    p.root.remove();
                    p.tab.remove();
                    panes.delete(id);
                }
            overflow.replaceChildren(option('⋯', ''));
            for (const c of value.conversations) {
                const p = panes.get(c.id) ?? create(c);
                const selected = c.id === active?.id;
                p.root.hidden = !selected;
                p.tab.hidden = c.mode === 'closed';
                p.tab.textContent = c.name + (c.unread ? ` · ${c.unread}` : '');
                p.tab.setAttribute('aria-selected', String(selected));
                p.tab.classList.toggle('unread', c.unread > 0);
                p.field.setAttribute('aria-label', `Message ${c.name}`);
                p.field.placeholder = `Message ${c.name}…`;
                if (!selected)
                    p.field.blur();
                // Hidden panes stay untouched until selected: preserve scroll/follow state.
                if (selected)
                    paint(c, p, value.self);
                overflow.append(option(c.name + (c.unread ? ` (${c.unread} unread)` : ''), String(c.id)));
            }
            recipient.textContent = active ? `To ${active.name}` : '';
            mute.textContent =
                active && value.muted.includes(active.id) ? 'Unmute' : 'Mute';
            const unread = value.conversations.filter((c) => c.unread > 0).length;
            envelope.textContent = `✉${unread ? ` ${unread}` : ''}`;
            envelope.setAttribute('aria-label', `Private messages, ${unread} unread conversations`);
            envelope.title =
                value.conversations
                    .filter((c) => c.unread > 0)
                    .map((c) => `${c.name}: ${c.unread}`)
                    .join('\n') || 'Private conversations';
            dockRoot.hidden = !value.conversations.length;
            shell.refresh();
            dock.refresh();
            options.regions();
        },
        dispose() {
            disposed = true;
            for (const p of panes.values())
                p.field.blur();
            panes.clear();
            shell.dispose();
            dock.dispose();
            root.remove();
            dockRoot.remove();
        },
    };
}
