import type { StatsSnapshot } from '../web/screens/stats/stats-model.js';
export function statsFixture(): StatsSnapshot {
  return {
    opened: false,
    ready: true,
    busy: false,
    pending: false,
    pending_attribute: '',
    error: '',
    vitals: { hp: 340, mp: 80 },
    data: {
      attributes: { STR: '12', DEX: '5', VIT: '8', INT: '6' },
      level: '7',
      experience: '210',
      xp_to_next: '490',
      xp_fraction: 210 / 490,
      available_points: '4',
      available_skill_points: '6',
      revision: '1',
      combat: {
        attack: 36.25,
        attack_speed: 100.5,
        health_max: 360,
        mana_max: 80,
        armor: 2,
        mana_regen: 0.8,
      },
    },
  };
}
