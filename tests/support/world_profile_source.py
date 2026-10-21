"""Build ignored profiling subclasses from CURRENT production methods.

No maintained fork of movement/AI: extract methods verbatim and inject timers
at exact anchors. Missing/ambiguous anchors stop the benchmark before launch.
Production scripts and defaults are never edited. Generated code is retained
beside raw results so attribution is independently inspectable.
"""
from pathlib import Path
import hashlib
import re

ROOT = Path(__file__).resolve().parents[2]
PROFILE = 'res://tests/support/world_profile.gd'


def method(path, name):
    source = (ROOT / path).read_text(encoding="utf-8")
    match = re.search(rf"^func {name}\([^\n]*\n(?:\t[^\n]*\n|\n)*", source, re.M)
    if not match:
        raise ValueError(f"Profiling method disappeared: {path}:{name}")
    return match[0].rstrip() + "\n"


def replace_once(source, anchor, replacement):
    if source.count(anchor) != 1:
        raise ValueError(f"Profiling anchor must occur exactly once: {anchor!r}")
    return source.replace(anchor, replacement, 1)


def span(source, anchor, key):
    """Time a straight-line block with no return/break escaping that block."""
    indent = re.match(r"\t*", anchor)[0]
    return replace_once(source, anchor,
                        f'{indent}var _p_{key}:=Time.get_ticks_usec()\n' + anchor +
                        f'\n{indent}Profile.add("{key}",_p_{key})')


def wrapper(name, signature, arguments, key, target="super"):
    return (f"func {name}({signature}) -> void:\n"
            f"\tvar started:=Time.get_ticks_usec()\n"
            f"\t{target}.{name}({arguments})\n"
            f'\tProfile.add("{key}",started)\n')


def build(directory):
    directory.mkdir()
    uri = "res://" + directory.relative_to(ROOT).as_posix()
    sources = {}
    player_path = "source/common/gameplay/world3d/actors/player_actor_3d.gd"
    simulate = method(player_path, "simulate")
    simulate = replace_once(simulate, "func simulate(", "func _profile_simulate(")
    simulate = span(simulate, "\tmove_and_slide()", "player_slide")
    simulate = span(simulate, "\tvar existing_exceptions := get_collision_exceptions()\n\tfor mob: PhysicsBody3D in overlaps:\n\t\tif existing_exceptions.has(mob): continue\n\t\tadd_collision_exception_with(mob)\n\t\ttemporary_exceptions.append(mob)", "player_exception_add")
    simulate = span(simulate, "\tfor mob: PhysicsBody3D in temporary_exceptions: remove_collision_exception_with(mob)", "player_exception_remove")
    simulate = span(simulate, "\tvar advance_velocity := _consume_attack_advance(delta)", "player_advance_curve")
    simulate = span(simulate, "\tvar displacement_velocity := damp_knockback(delta) + advance_velocity", "player_knockback_damping")
    # The whole conditional includes test_move + its actor-contact policy.
    start = simulate.index("\tif advance_velocity.length_squared() > 0 and delta > 0:")
    end = simulate.index("\tvar _p_player_slide", start)
    simulate = span(simulate, simulate[start:end].rstrip("\n"), "player_advance_probe")
    overlap = method(player_path, "_overlapping_mob_bodies")
    overlap = replace_once(overlap, "\tfor hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query,256):",
                           '\tvar started:=Time.get_ticks_usec()\n\tvar hits:=get_world_3d().direct_space_state.intersect_shape(query,256)\n\tProfile.add("player_intersect_shape",started)\n\tfor hit: Dictionary in hits:')
    sources["player.gd"] = ('extends PlayerActor3D\n' +
        wrapper("simulate", "delta: float, direction: Vector2", "delta,direction", "player_simulate", "self").replace("self.simulate(", "self._profile_simulate(") + simulate + overlap)
    mob_path = "source/common/gameplay/world3d/actors/mob_actor_3d.gd"
    motion = method(mob_path, "simulate_mob")
    motion = replace_once(motion, "func simulate_mob(", "func _profile_motion(")
    motion = span(motion, "\tmove_and_slide()", "mob_slide")
    sources["mob.gd"] = ('extends MobActor3D\n' +
        wrapper("simulate_mob", "delta: float, direction: Vector2, now: int", "delta,direction,now", "mob_motion", "self").replace("self.simulate_mob(", "self._profile_motion(") + motion)
    spawn = method("source/common/gameplay/mobs/mob_system.gd", "spawn_mob")
    spawn = replace_once(spawn, "MobActor3D.new()", f'preload("{uri}/mob.gd").new()')
    sources["mobs.gd"] = ('extends MobSystem\n' + spawn +
        wrapper("tick", "delta: float, now: int", "delta,now", "mob_tick") +
        wrapper("tick_mob", "dog: MobActor3D, delta: float, now: int", "dog,delta,now", "mob_ai_inclusive"))
    factory = method("source/common/gameplay/world3d/game_world_3d.gd", "_add_character")
    factory = replace_once(factory, "PlayerActor3D.new()", f'preload("{uri}/player.gd").new()')
    sources["map.gd"] = ('extends "res://tests/world_load_bench.gd".BenchMap\n' + factory +
        wrapper("_physics_process", "delta: float", "delta", "world_movement_snapshot"))
    manifest = {}
    for name, source in sources.items():
        source = source.split("\n", 1)[0] + f'\nconst Profile=preload("{PROFILE}")\n' + source.split("\n", 1)[1]
        (directory / name).write_text(source, encoding="utf-8")
        manifest[name] = hashlib.sha256(source.encode()).hexdigest()
    return uri, manifest
