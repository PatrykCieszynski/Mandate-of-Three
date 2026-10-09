export type PreviewAction =
  | { action: 'reset' | 'empty' | 'escape' }
  | { action: 'inventory' | 'equipment' | 'accept'; value: boolean }
  | { action: 'scale' | 'wallet'; value: number };
