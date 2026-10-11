class_name HitReaction
extends RefCounted
## Stable wire values. Stun remains a separate status, not a reaction.
enum Type { NONE = 0, FLINCH = 1, KNOCKBACK = 2, KNOCKDOWN = 3 }
enum Phase { NONE = 0, DOWN = 1, GETTING_UP = 2 }
