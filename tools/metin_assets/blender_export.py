"""Blender entry point. Reuses the proven Warrior load/material/export settings
and hair bind procedure; the dog recipe's UV, scale and orientation are retained.
No GR2 decoding is implemented here; BlenderGR2rs owns models and animations.
"""
import bpy
import json
import math
from pathlib import Path
import sys
import traceback
from mathutils import Matrix

request = json.loads(Path(sys.argv[sys.argv.index('--') + 1]).read_text(encoding='utf-8-sig'))
sys.path.insert(0, request['importer_root'])
from BlenderGR2rs import gr2_native
from BlenderGR2rs.gr2_importer import import_gr2, import_gr2_animation


def fail(status, message):
    raise RuntimeError(status + ': ' + message)


def load(path):
    before = set(bpy.context.scene.objects)
    result = import_gr2(bpy.context, str(path), import_scale=.01, import_animations=False,
                        placement_rotation=(0, 0, 0), flip_uv_v=True)
    if result != {'FINISHED'}:
        fail('IMPORT_FAILED', str(path))
    return [o for o in bpy.context.scene.objects if o not in before]


def materialize(objects, job):
    textures = []
    for obj in objects:
        if obj.type != 'MESH':
            continue
        if not obj.data.materials:
            fail('MISSING_TEXTURE', 'No material slots: ' + obj.name)
        for index, old in enumerate(obj.data.materials):
            images = [n.image for n in old.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image] if old and old.use_nodes else []
            name = Path(images[0].filepath.replace('\\', '/')).name.lower() if images else ''
            resolved = job['texture_files'].get(name)
            if 'hair' in obj.name.lower() and job.get('hair_texture_file'):
                resolved = job['hair_texture_file']
            if not resolved and len(job['texture_files']) == 1:
                resolved = next(iter(job['texture_files'].values()))
            if not resolved:
                fail('MISSING_TEXTURE', obj.name + ' / ' + name)
            image = bpy.data.images.load(resolved, check_existing=True)
            if image.size[0] <= 0 or image.size[1] <= 0:
                fail('MISSING_TEXTURE', resolved)
            image.colorspace_settings.name = 'sRGB'
            image.pack()
            mat = bpy.data.materials.new(obj.name + '_PBR')
            mat.use_nodes = True
            bsdf = mat.node_tree.nodes.get('Principled BSDF')
            bsdf.inputs['Roughness'].default_value = .85
            tex = mat.node_tree.nodes.new('ShaderNodeTexImage')
            tex.image = image
            mat.node_tree.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
            if 'hair' in obj.name.lower():
                cutout = mat.node_tree.nodes.new('ShaderNodeMath')
                cutout.operation = 'ROUND'
                mat.node_tree.links.new(tex.outputs['Alpha'], cutout.inputs[0])
                mat.node_tree.links.new(cutout.outputs[0], bsdf.inputs['Alpha'])
                mat.surface_render_method = 'DITHERED'
            obj.data.materials[index] = mat
            textures.append({'mesh': obj.name, 'source': resolved, 'size': list(image.size),
                             'alpha': 'MASK' if 'hair' in obj.name.lower() else 'OPAQUE'})
    return textures


def export(path, animated):
    path.parent.mkdir(parents=True, exist_ok=True)
    if bpy.ops.export_scene.gltf(filepath=str(path), export_format='GLB', export_animations=animated,
            export_animation_mode='ACTIONS', export_anim_single_armature=True, export_force_sampling=True,
            export_anim_slide_to_zero=True, export_skins=True, export_yup=True,
            export_image_format='AUTO', export_extras=False) != {'FINISHED'}:
        fail('EXPORT_FAILED', str(path))


def attach_hair(arm, job):
    hair = load(job['hair_file'])
    # Required depsgraph update is retained from the successful Warrior spike.
    bpy.context.view_layer.update()
    hair_arm = next(o for o in hair if o.type == 'ARMATURE')
    weighted_errors = {}
    for obj in hair:
        if obj.type != 'MESH':
            continue
        world = obj.matrix_world.copy()
        used = {obj.vertex_groups[g.group].name for v in obj.data.vertices for g in v.groups if g.weight > 0}
        if not all(name in arm.data.bones for name in used):
            fail('INVALID_SKELETON', 'Hair weights do not match body')
        weighted_errors.update({name: max(abs(hair_arm.data.bones[name].matrix_local[r][c] - arm.data.bones[name].matrix_local[r][c])
                                       for r in range(4) for c in range(4)) for name in used})
        if max(weighted_errors.values(), default=0) > .001:
            fail('INVALID_SKELETON', 'Hair bind matrices differ from body')
        obj.parent = arm
        obj.matrix_world = world
        for mod in obj.modifiers:
            if mod.type == 'ARMATURE':
                mod.object = arm
    bpy.data.objects.remove(hair_arm, do_unlink=True)
    return weighted_errors


def convert(job):
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    bpy.context.scene.render.fps = 30
    objects = load(job['model_file'])
    meshes = [o for o in objects if o.type == 'MESH']
    arms = [o for o in objects if o.type == 'ARMATURE']
    if not meshes:
        fail('MISSING_MODEL', 'GR2 has no mesh')
    if len(arms) != 1:
        fail('INVALID_SKELETON', 'Expected exactly one source armature')
    arm = arms[0]
    if job['recipe'] == 'warrior':
        hair_errors = attach_hair(arm, job)
    else:
        hair_errors = {}
    objects = list(bpy.context.scene.objects)
    meshes = [o for o in objects if o.type == 'MESH']
    report = {'blender': bpy.app.version_string, 'importer_revision': request['importer_revision'],
              'bones': len(arm.data.bones), 'bone_names': [b.name for b in arm.data.bones],
              'vertices': sum(len(o.data.vertices) for o in meshes),
              'triangles': sum(len(o.data.polygons) for o in meshes),
              'materials': materialize(objects, job), 'clips': {}, 'hair_weighted_rest_errors': hair_errors,
              'scale': .01, 'axis': 'Godot Y-up', 'forward': 'Godot -Z',
              'orientation_z_degrees': 0 if job['recipe'] == 'sword' else 180,
              'root_motion': 'Native samples retained in GLB; VisualAnimationTools freezes root X/Z per instance'}
    if job['recipe'] == 'sword':
        if len(arm.data.bones) != 1:
            fail('INVALID_SKELETON', 'Rigid sword expected one bone')
        bpy.context.view_layer.update()
        deps = bpy.context.evaluated_depsgraph_get()
        for obj in meshes:
            evaluated = obj.evaluated_get(deps)
            data = bpy.data.meshes.new_from_object(evaluated, depsgraph=deps)
            data.transform(obj.matrix_world)
            obj.modifiers.clear()
            obj.parent = None
            obj.matrix_world = Matrix.Identity(4)
            obj.data = data
        bpy.data.objects.remove(arm, do_unlink=True)
        report.update(rigid=True, forward='Blade +Y; shared hand socket applies +90 degrees local Z')
    else:
        wrapper = bpy.data.objects.new(job['id'], None)
        bpy.context.scene.collection.objects.link(wrapper)
        for obj in objects:
            if obj.parent is None:
                obj.parent = wrapper
        wrapper.rotation_euler.z = math.pi
        actions = []
        roots = [bone for bone in arm.pose.bones if bone.parent is None]
        if len(roots) != 1:
            fail('INVALID_SKELETON', 'Expected one root bone')
        for semantic, path in job['animation_files'].items():
            before = set(bpy.data.actions)
            if import_gr2_animation(bpy.context, path, armature=arm, model_path=job['model_file'], max_fps=30) != {'FINISHED'}:
                fail('IMPORT_FAILED', 'Animation: ' + path)
            new = [a for a in bpy.data.actions if a not in before]
            if len(new) != 1:
                fail('IMPORT_FAILED', 'Expected one action per animation')
            action = new[0]
            action.name = semantic
            action.use_fake_user = True
            actions.append(action)
            arm.animation_data.action = action
            arm.animation_data.action_slot = action.slots[0]
            start, end = action.frame_range
            samples = []
            for frame in range(math.floor(start), math.ceil(end) + 1):
                bpy.context.scene.frame_set(frame)
                bpy.context.view_layer.update()
                samples.append(list(arm.matrix_world @ roots[0].matrix.translation))
            report['clips'][semantic] = {'source': path, 'duration': (end-start)/30,
                'root_delta': [samples[-1][i]-samples[0][i] for i in range(3)],
                'root_range': [max(p[i] for p in samples)-min(p[i] for p in samples) for i in range(3)]}
        if actions:
            arm.animation_data.action = actions[0]
            arm.animation_data.action_slot = actions[0].slots[0]
    bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()
    deps = bpy.context.evaluated_depsgraph_get()
    points = [obj.evaluated_get(deps).matrix_world @ v.co for obj in meshes for v in obj.evaluated_get(deps).data.vertices]
    report['idle_bounds_blender'] = {'min': [min(p[i] for p in points) for i in range(3)],
                                   'max': [max(p[i] for p in points) for i in range(3)]}
    export(Path(job['temporary_output']), bool(job['animation_files']))
    return report


def probe(models):
    results = {}
    for path in models:
        loaded = None
        try:
            loaded = gr2_native.Gr2File.load_from_path(path)
            if not loaded:
                fail('IMPORT_FAILED', path)
            refs = [gr2_native.get_texture_name(loaded.get_texture(i)) for i in range(loaded.texture_count)]
            # Some GR2 versions expose textures only through material bindings.
            for mesh_index in range(loaded.mesh_count):
                mesh = loaded.get_mesh(mesh_index)
                for material_index in range(gr2_native.get_mesh_material_count(mesh)):
                    material = gr2_native.get_mesh_material(mesh, material_index)
                    texture = gr2_native.get_material_diffuse_texture(material)
                    if texture:
                        refs.append(gr2_native.get_texture_name(texture))
            results[path] = {'textures': sorted(set(r for r in refs if r)), 'meshes': loaded.mesh_count,
                             'skeletons': loaded.skeleton_count, 'blender': bpy.app.version_string}
        except Exception as error:
            results[path] = {'error': str(error)}
        finally:
            if loaded:
                loaded.close()
    return results


try:
    if not gr2_native.initialize():
        fail('IMPORT_FAILED', 'Native importer initialization failed')
    if request['operation'] == 'probe':
        result = probe(request['models'])
    else:
        result = {'status': 'SUCCESS', 'findings': convert(request['job'])}
except Exception as error:
    traceback.print_exc()
    message = str(error)
    statuses = ['MISSING_MODEL', 'MISSING_TEXTURE', 'MISSING_ANIMATION', 'IMPORT_FAILED', 'EXPORT_FAILED', 'INVALID_SKELETON', 'UNKNOWN_LAYOUT']
    result = {'status': next((s for s in statuses if message.startswith(s + ':')), 'IMPORT_FAILED'), 'error': message}
Path(request['result']).write_text(json.dumps(result, indent=2), encoding='utf-8')
print('METIN_BLENDER_RESULT_WRITTEN')
