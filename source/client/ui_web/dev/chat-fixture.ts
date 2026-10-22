import type {
  ChatSnapshot,
  ChatMessage,
  Conversation,
} from '../web/screens/chat/chat-view.js';
import { isObject } from '../web/protocol.js';
const people = [
  { id: 2, name: 'Yuna' },
  { id: 3, name: 'Baek' },
];
let sequence = 100;
export function chatFixture(): ChatSnapshot {
  return {
    self: 1,
    guild_available: false,
    muted: [],
    messages: [
      {
        id: 1,
        channel: 'system',
        sender: 0,
        name: 'System',
        target: 0,
        text: 'Development preview — no game server or database.',
      },
      {
        id: 2,
        channel: 'general',
        sender: 2,
        name: 'Yuna',
        target: 0,
        text: 'Anyone exploring the forest?',
      },
      {
        id: 3,
        channel: 'trade',
        sender: 3,
        name: 'Baek',
        target: 0,
        text: 'Buying upgrade materials. Whisper me.',
      },
      {
        id: 4,
        channel: 'local',
        sender: 2,
        name: 'Yuna',
        target: 0,
        text: 'Meet near the blacksmith.',
      },
      {
        id: 5,
        channel: 'party',
        sender: 3,
        name: 'Baek',
        target: 0,
        text: 'Ready for the next Metin.',
      },
    ],
    conversations: [
      {
        id: 2,
        name: 'Yuna',
        mode: 'open',
        unread: 0,
        messages: [
          {
            id: 6,
            channel: 'whisper',
            sender: 2,
            name: 'Yuna',
            target: 1,
            text: 'Want to join our party?',
          },
          {
            id: 7,
            channel: 'whisper',
            sender: 1,
            name: 'You',
            target: 2,
            text: 'Yes, on my way.',
          },
        ],
      },
      {
        id: 3,
        name: 'Baek',
        mode: 'minimized',
        unread: 1,
        messages: [
          {
            id: 8,
            channel: 'whisper',
            sender: 3,
            name: 'Baek',
            target: 1,
            text: 'I have a sword for you.',
          },
        ],
      },
    ],
  };
}
function open(state: ChatSnapshot, id: number, name: string): Conversation {
  let convo = state.conversations.find((c) => c.id === id);
  if (!convo) {
    convo = { id, name, mode: 'open', unread: 0, messages: [] };
    state.conversations.push(convo);
  }
  convo.mode = 'open';
  convo.unread = 0;
  return convo;
}
export function receiveChatFixture(state: ChatSnapshot, whisper = false) {
  const sender = whisper ? 3 : 2;
  if (state.muted.includes(sender)) return;
  const message: ChatMessage = {
    id: ++sequence,
    channel: whisper ? 'whisper' : 'general',
    sender,
    name: whisper ? 'Baek' : 'Yuna',
    target: whisper ? 1 : 0,
    text: whisper
      ? 'Incoming private message. Minimize this window to test its unread badge.'
      : 'A new public message, including long text to check wrapping and scrolling while reading older messages. The forest is busy today.',
  };
  if (whisper) {
    let convo = state.conversations.find((c) => c.id === sender);
    if (!convo) convo = open(state, sender, message.name);
    if (convo.mode === 'closed') convo.mode = 'open';
    if (convo.mode === 'minimized') convo.unread++;
    convo.messages.push(message);
    convo.messages = convo.messages.slice(-100);
  } else {
    state.messages.push(message);
    state.messages = state.messages.slice(-200);
  }
}
export function chatCommand(
  state: ChatSnapshot,
  type: string,
  p: unknown,
): { ok: boolean; error?: string } {
  if (!isObject(p)) return { ok: false, error: 'payload' };
  if (type === 'chat.send' && p.action === 'lookup') {
    const person = people.find(
      (person) =>
        person.name.toLowerCase() === String(p.name).trim().toLowerCase(),
    );
    if (!person) return { ok: false, error: 'recipient_offline' };
    open(state, person.id, person.name);
    return { ok: true };
  }
  if (
    type === 'chat.open' &&
    Number.isSafeInteger(p.target) &&
    Number(p.target) > 1
  ) {
    open(state, Number(p.target), String(p.name));
    return { ok: true };
  }
  const convo = state.conversations.find((c) => c.id === p.target);
  if (
    type === 'chat.conversation' &&
    convo &&
    ['open', 'closed', 'minimized'].includes(String(p.mode))
  ) {
    convo.mode = p.mode as Conversation['mode'];
    if (p.mode === 'open') convo.unread = 0;
    return { ok: true };
  }
  if (type === 'chat.mute' && convo && typeof p.muted === 'boolean') {
    state.muted = state.muted.filter((id) => id !== convo.id);
    if (p.muted) state.muted.push(convo.id);
    return { ok: true };
  }
  if (type === 'chat.send' && p.action === 'send') {
    if (p.channel === 'guild') return { ok: false, error: 'guild_unavailable' };
    const text = String(p.text ?? '').trim();
    if (!text || [...text].length > 256)
      return { ok: false, error: 'invalid_text' };
    if (
      !['general', 'trade', 'local', 'party', 'whisper'].includes(
        String(p.channel),
      )
    )
      return { ok: false, error: 'payload' };
    if (
      p.channel === 'whisper' &&
      !people.some((person) => person.id === p.target)
    )
      return { ok: false, error: 'recipient_offline' };
    const message: ChatMessage = {
      id: ++sequence,
      channel: p.channel as ChatMessage['channel'],
      sender: 1,
      name: 'You',
      target: p.channel === 'whisper' ? Number(p.target) : 0,
      text,
    };
    if (p.channel === 'whisper') {
      const person = people.find((person) => person.id === p.target)!;
      const dest = convo ?? open(state, person.id, person.name);
      dest.messages.push(message);
      dest.messages = dest.messages.slice(-100);
    } else {
      state.messages.push(message);
      state.messages = state.messages.slice(-200);
    }
    return { ok: true };
  }
  return { ok: false, error: 'payload' };
}
