export type PreviewAction =
  | {
      action: 'reset' | 'empty' | 'escape' | 'chat-message' | 'whisper-message';
    }
  | {
      action:
        | 'trade'
        | 'craft'
        | 'vendor'
        | 'stats'
        | 'inventory'
        | 'equipment'
        | 'storage'
        | 'hotbar'
        | 'accept'
        | 'tooltip-details';
      value: boolean;
    }
  | { action: 'scale' | 'wallet'; value: number };
