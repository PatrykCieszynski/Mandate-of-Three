export type PreviewAction =
  | { action: 'reset' | 'empty' | 'escape' }
  | {
      action:
        'inventory' | 'equipment' | 'storage' | 'accept' | 'tooltip-details';
      value: boolean;
    }
  | { action: 'scale' | 'wallet'; value: number };
