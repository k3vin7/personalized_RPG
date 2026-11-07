"""Deterministic Blender build for the Tripo human character.

Source of truth is the untouched Tripo zip in
``assets/characters/tripo_human/source/``. Every run starts from factory
settings, re-reads that zip, and writes the same outputs, so nothing hand-made
survives in a .blend. The script never modifies the zip.

Outputs (all under assets/characters/tripo_human/):
  tripo_human.glb            mesh + skeleton, 2K albedo embedded, no clips
  tripo_human_anims.glb      skeleton + every clip (12 originals untouched +
                             run_looped + chop_single, which are derived copies),
                             with a 1 cm proxy triangle skinned to Hips: Godot
                             only builds a Skeleton3D (and bone tracks) for a
                             skin, so a bare armature's clips would land on
                             plain Node3Ds instead (KayKit ships a mannequin
                             for the same reason)
  tripo_human_albedo_2k.jpg  the 2K game texture (the 4K original stays in the zip)

Run with Blender 5.2 from anywhere:
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/tripo_human_build.py

Pass ``-- --single <path>`` to also write a one-file comparison GLB (mesh +
clips) outside the project, for checking the split against it.

Every measurement is printed as a BUILD_* line so a report can quote it.
"""

import hashlib
import json
import math
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent.parent
ASSET = PROJECT / "assets" / "characters" / "tripo_human"
SOURCE_ZIP = ASSET / "source" / "tripo_convert_81436180-5b3b-495a-ab99-f54c66de42d7.zip"
SOURCE_SHA256 = "e5a0356ee430578a53d076e7a0aa2c6ffcee7dffa341fb2f1847cc43e6ce8eca"
MESH_GLB = ASSET / "tripo_human.glb"
ANIMS_GLB = ASSET / "tripo_human_anims.glb"
TEXTURE_2K = ASSET / "tripo_human_albedo_2k.jpg"

RIG_NAME = "Rig_Tripo"
MESH_NAME = "TripoHuman"
MATERIAL_NAME = "tripo_human_mat"
BONE_PREFIX = "mixamorig:"
FPS = 24
EXPECTED_BONES = 65
EXPECTED_VERTS = 21682
EXPECTED_FACES = 22426
EXPECTED_HEIGHT = 1.0
HEIGHT_TOLERANCE = 0.01
MAX_INFLUENCES = 4
TEXTURE_2K_SIZE = 2048
TEXTURE_JPEG_QUALITY = 92

# The 12 clips Tripo shipped, with their FBX frame ranges (24 fps, frame 1 first).
ORIGINAL_ACTIONS = {
    "box_01": (1, 54), "box_02": (1, 68), "box_03": (1, 62),
    "chop": (1, 159), "dive": (1, 66),
    "front_kick_01": (1, 61), "front_kick_02": (1, 34),
    "run": (1, 31), "standing_relax": (1, 423), "swim": (1, 138),
    "wait": (1, 145), "walk": (1, 57),
}
# Derived clips: (source, first frame, last frame, loop). The frame window was
# read off the curves (tools/blender analysis, 2026-11-06):
#  run: the left foot's lowest point repeats every 15 frames (f6 -> f21); the
#       best-matching start/end pair with a full cycle is f11/f26 (pose delta
#       0.136). The last frame is overwritten with the first so the loop closes.
#  chop: one chop only -- the hands dip to z=0.46 at f30, rise to 0.94 at f45,
#       strike to 0.35 at f54, then hold. f30..f56 is the wind-up + strike;
#       the game stretches it over windup + swing and holds the last frame.
# Not "run_loop": Godot's editor importer strips a "-loop"/"_loop"/"-cycle"
# suffix and the name then collides with "run" (the game's run-time loader
# keeps the name; the editor scan of 2026-11-06 logged the collision).
DERIVED_ACTIONS = {
    "run_looped": ("run", 11, 26, True),
    "chop_single": ("chop", 30, 56, False),
}
LOOPING_ORIGINALS = {"walk", "standing_relax", "wait"}
HANDSLOTS = {
    "handslot.r": ("RightHand", "RightHandIndex1", "RightHandMiddle1", "RightHandPinky1", 1.0),
    "handslot.l": ("LeftHand", "LeftHandIndex1", "LeftHandMiddle1", "LeftHandPinky1", -1.0),
}
HANDSLOT_LENGTH = 0.08
PROXY_NAME = "Rig_Tripo_Proxy"
PROXY_BONE = "Hips"
PROXY_SIZE = 0.01
# Foot bones used to read the stride speed of the in-place locomotion clips.
FEET = ("LeftFoot", "RightFoot")

BLENDER = Path(bpy.app.binary_path)


def say(tag, **fields):
    print("BUILD_%s %s" % (tag, json.dumps(fields, sort_keys=True, default=str)))


def fail(message):
    raise RuntimeError(message)


# ------------------------------------------------------------------ source

def check_source():
    if not SOURCE_ZIP.exists():
        fail("source zip missing: %s" % SOURCE_ZIP)
    digest = hashlib.sha256(SOURCE_ZIP.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        fail("source zip sha256 %s != %s" % (digest, SOURCE_SHA256))
    say("SOURCE", zip=str(SOURCE_ZIP.relative_to(PROJECT)), sha256=digest, bytes=SOURCE_ZIP.stat().st_size)


def extract_source(workdir: Path) -> Path:
    with zipfile.ZipFile(SOURCE_ZIP) as archive:
        names = archive.namelist()
        for name in names:
            if name.startswith("/") or ".." in Path(name).parts:
                fail("unsafe zip entry %s" % name)
        archive.extractall(workdir)
    fbx = [p for p in workdir.rglob("*.fbx")]
    if len(fbx) != 1:
        fail("expected one fbx in the zip, found %s" % fbx)
    say("EXTRACT", entries=names, fbx=fbx[0].name)
    return fbx[0]


# ------------------------------------------------------------------ import

def import_fbx(path: Path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(
        filepath=str(path),
        use_anim=True,
        anim_offset=1.0,
        ignore_leaf_bones=False,
        automatic_bone_orientation=False,
        force_connect_children=False,
        use_custom_normals=True,
        global_scale=1.0,
    )
    if result != {"FINISHED"}:
        fail("fbx import returned %s" % result)
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1.0
    rigs = [o for o in scene.objects if o.type == "ARMATURE"]
    meshes = [o for o in scene.objects if o.type == "MESH"]
    if len(rigs) != 1 or len(meshes) != 1:
        fail("expected 1 armature + 1 mesh, found %d + %d" % (len(rigs), len(meshes)))
    return rigs[0], meshes[0]


def channelbags(action):
    # Blender 4.4+ layered actions: one layer, one keyframe strip, one
    # channelbag per slot. Action.fcurves is gone in 5.x.
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield bag


def action_fcurves(action):
    out = []
    for bag in channelbags(action):
        out.extend(bag.fcurves)
    return out


def remove_fcurve(action, fcurve):
    for bag in channelbags(action):
        if fcurve in list(bag.fcurves):
            bag.fcurves.remove(fcurve)
            return
    fail("could not remove fcurve %s" % fcurve.data_path)


def set_action(rig, action):
    rig.animation_data.action = action
    if action is not None and hasattr(rig.animation_data, "action_slot") and len(action.slots):
        rig.animation_data.action_slot = action.slots[0]


def rest_bbox(rig, meshes):
    rig.data.pose_position = "REST"
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    points = []
    for mesh in meshes:
        evaluated = mesh.evaluated_get(depsgraph)
        data = evaluated.to_mesh()
        points.extend(evaluated.matrix_world @ v.co for v in data.vertices)
        evaluated.to_mesh_clear()
    rig.data.pose_position = "POSE"
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    return low, high


# ------------------------------------------------------------------ validation

def validate_import(rig, mesh):
    scene = bpy.context.scene
    if scene.unit_settings.system != "METRIC":
        fail("scene is not metric")
    bones = rig.data.bones
    if len(bones) != EXPECTED_BONES:
        fail("bone count %d != %d" % (len(bones), EXPECTED_BONES))
    not_prefixed = [b.name for b in bones if not b.name.startswith(BONE_PREFIX)]
    if not_prefixed:
        fail("bones without the %s prefix: %s" % (BONE_PREFIX, not_prefixed))
    if any(not b.use_deform for b in bones):
        fail("a source bone is not deforming")
    for obj in (rig, mesh):
        if any(abs(v - 1.0) > 1e-6 for v in obj.scale):
            fail("%s has scale %s" % (obj.name, tuple(obj.scale)))
        if any(abs(v) > 1e-6 for v in obj.rotation_euler):
            fail("%s has rotation %s" % (obj.name, tuple(obj.rotation_euler)))
    if mesh.parent != rig:
        fail("mesh is not parented to the armature")
    modifiers = [m for m in mesh.modifiers if m.type == "ARMATURE"]
    if len(mesh.modifiers) != 1 or len(modifiers) != 1 or modifiers[0].object != rig:
        fail("mesh modifiers are not exactly one armature modifier on the rig")
    data = mesh.data
    if len(data.vertices) != EXPECTED_VERTS or len(data.polygons) != EXPECTED_FACES:
        fail("mesh is %d verts / %d faces, expected %d / %d" % (
            len(data.vertices), len(data.polygons), EXPECTED_VERTS, EXPECTED_FACES))
    if len(data.uv_layers) != 1:
        fail("expected one uv layer")
    if data.shape_keys is not None:
        fail("unexpected shape keys")
    influences = max(len(v.groups) for v in data.vertices)
    unweighted = sum(1 for v in data.vertices if not v.groups)
    if influences > MAX_INFLUENCES or unweighted:
        fail("skinning: max influences %d, unweighted %d" % (influences, unweighted))
    group_names = {g.name for g in mesh.vertex_groups}
    if not group_names <= {b.name for b in bones}:
        fail("vertex groups not matching bones: %s" % sorted(group_names - {b.name for b in bones}))
    if len(mesh.material_slots) != 1 or mesh.material_slots[0].material is None:
        fail("expected one material")
    images = material_images(mesh.material_slots[0].material)
    if len(images) != 1:
        fail("expected one texture, found %s" % [i.name for i in images])
    if tuple(images[0].size) != (4096, 4096):
        fail("texture is %s, expected 4096x4096" % tuple(images[0].size))
    low, high = rest_bbox(rig, [mesh])
    height = high.z - low.z
    if abs(height - EXPECTED_HEIGHT) > HEIGHT_TOLERANCE:
        fail("rest height %.4f, expected %.2f" % (height, EXPECTED_HEIGHT))
    if abs(low.z) > HEIGHT_TOLERANCE:
        fail("feet are at z=%.4f, expected the floor" % low.z)
    toe = rig.matrix_world @ bones[BONE_PREFIX + "LeftToe_End"].head_local
    heel = rig.matrix_world @ bones[BONE_PREFIX + "LeftFoot"].head_local
    if (toe - heel).y >= 0.0:
        fail("the model does not face -Y in Blender (toe-heel y %.3f)" % (toe - heel).y)
    names = {a.name for a in bpy.data.actions}
    want = {"Armature|%s.001" % n for n in ORIGINAL_ACTIONS}
    if names != want:
        fail("actions %s != expected %s" % (sorted(names), sorted(want)))
    for name, (start, end) in ORIGINAL_ACTIONS.items():
        action = bpy.data.actions["Armature|%s.001" % name]
        got = (int(round(action.frame_range[0])), int(round(action.frame_range[1])))
        if got != (start, end):
            fail("%s frame range %s != %s" % (name, got, (start, end)))
    say("VALIDATED_IMPORT", bones=len(bones), verts=len(data.vertices), faces=len(data.polygons),
        tris=sum(len(p.vertices) - 2 for p in data.polygons), max_influences=influences,
        rest_height=round(height, 4), rest_width_x=round(high.x - low.x, 4),
        rest_depth_y=round(high.y - low.y, 4), feet_z=round(low.z, 4),
        texture=list(images[0].size), actions=len(names), fps=scene.render.fps)


def material_images(material):
    out = []
    if material.node_tree is None:
        return out
    for node in material.node_tree.nodes:
        if node.type == "TEX_IMAGE" and node.image is not None:
            out.append(node.image)
    return out


# ------------------------------------------------------------------ cleanup

def rename_everything(rig, mesh):
    rig.name = RIG_NAME
    rig.data.name = RIG_NAME
    mesh.name = MESH_NAME
    mesh.data.name = MESH_NAME
    mesh.material_slots[0].material.name = MATERIAL_NAME
    # Bone renames go through Blender's rename, which rewrites vertex groups
    # and every action's data paths; checked below rather than trusted.
    for bone in list(rig.data.bones):
        bone.name = bone.name[len(BONE_PREFIX):]
    for action in list(bpy.data.actions):
        action.name = action.name.removeprefix("Armature|").removesuffix(".001")
        action.use_fake_user = True
    bone_names = {b.name for b in rig.data.bones}
    group_names = {g.name for g in mesh.vertex_groups}
    if not group_names <= bone_names:
        fail("vertex groups did not follow the bone rename: %s" % sorted(group_names - bone_names))
    # The bone rename rewrites vertex groups but not the data paths of actions
    # that are not assigned to the object, so every action is rewritten here.
    prefixed_path = 'pose.bones["%s' % BONE_PREFIX
    rewritten = 0
    for action in bpy.data.actions:
        for fcurve in action_fcurves(action):
            if fcurve.data_path.startswith(prefixed_path):
                fcurve.data_path = fcurve.data_path.replace(BONE_PREFIX, "", 1)
                rewritten += 1
        for bag in channelbags(action):
            for group in getattr(bag, "groups", []):
                if group.name.startswith(BONE_PREFIX):
                    group.name = group.name[len(BONE_PREFIX):]
    dropped = {}
    for action in bpy.data.actions:
        for fcurve in list(action_fcurves(action)):
            path = fcurve.data_path
            if path.startswith("pose.bones["):
                bone = path.split('"')[1]
                if bone not in bone_names:
                    fail("%s animates unknown bone %s" % (action.name, bone))
                continue
            # Object-level channels on the armature itself (the FBX importer
            # writes location/rotation/scale there). They are flat here; the
            # body's motion belongs to Player, so they go.
            peak = max((abs(k.co[1]) for k in fcurve.keyframe_points), default=0.0)
            if path in ("location",):
                peak_delta = max((abs(k.co[1] - fcurve.keyframe_points[0].co[1]) for k in fcurve.keyframe_points), default=0.0)
            else:
                peak_delta = peak
            dropped.setdefault(action.name, []).append((path, fcurve.array_index, round(peak_delta, 5)))
            remove_fcurve(action, fcurve)
    say("RENAMED", rig=RIG_NAME, mesh=MESH_NAME, bones_sample=sorted(bone_names)[:6],
        actions=sorted(a.name for a in bpy.data.actions), fcurve_paths_rewritten=rewritten,
        object_channels_removed=dropped)


# ------------------------------------------------------------------ hand slots

def add_handslots(rig):
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    edit = rig.data.edit_bones
    placed = {}
    for slot, (hand_name, index_name, middle_name, pinky_name, side) in HANDSLOTS.items():
        hand = edit[hand_name]
        index1 = edit[index_name]
        middle1 = edit[middle_name]
        pinky1 = edit[pinky_name]
        finger_dir = (middle1.head - hand.head).normalized()
        # The grip axis: across the palm from the pinky side to the index
        # (thumb) side, in the palm plane. A sword in a closed fist runs along
        # it with the blade out the thumb side, so that is the slot's +Y.
        across = index1.head - pinky1.head
        across -= across.dot(finger_dir) * finger_dir
        blade = across.normalized()
        # The slot's Z points out the back of the hand on both sides, so a
        # prop on handslot.l mirrors one on handslot.r.
        back_of_hand = finger_dir.cross(blade) * side
        centre = hand.head + (middle1.head - hand.head) * 0.55
        bone = edit.new(slot)
        bone.head = centre
        bone.tail = centre + blade * HANDSLOT_LENGTH
        bone.parent = hand
        bone.use_connect = False
        bone.use_deform = False
        bone.align_roll(back_of_hand)
        placed[slot] = {
            "parent": hand_name,
            "head": [round(v, 4) for v in centre],
            "blade_dir": [round(v, 3) for v in blade],
            "back_of_hand": [round(v, 3) for v in back_of_hand.normalized()],
        }
    bpy.ops.object.mode_set(mode="OBJECT")
    if len(rig.data.bones) != EXPECTED_BONES + len(HANDSLOTS):
        fail("hand slots did not land")
    say("HANDSLOTS", **placed)


# ------------------------------------------------------------------ derived clips

def derive_actions(rig):
    for name, (source_name, first, last, loop) in DERIVED_ACTIONS.items():
        source = bpy.data.actions[source_name]
        action = source.copy()
        action.name = name
        action.use_fake_user = True
        shift = 1 - first
        for fcurve in action_fcurves(action):
            start_value = fcurve.evaluate(first)
            end_value = fcurve.evaluate(last)
            for key in reversed(list(fcurve.keyframe_points)):
                frame = key.co[0]
                if frame < first - 1e-6 or frame > last + 1e-6:
                    fcurve.keyframe_points.remove(key, fast=True)
            for key in fcurve.keyframe_points:
                key.co[0] += shift
                key.handle_left[0] += shift
                key.handle_right[0] += shift
            fcurve.keyframe_points.insert(1, start_value, options={"REPLACE"})
            fcurve.keyframe_points.insert(last + shift, start_value if loop else end_value, options={"REPLACE"})
            fcurve.update()
        action.use_frame_range = True
        action.frame_start = 1
        action.frame_end = last + shift
        action["loop"] = loop
        action["derived_from"] = source_name
        action["source_frames"] = [first, last]
        say("DERIVED", name=name, source=source_name, source_frames=[first, last],
            frames=[1, last + shift], seconds=round((last - first) / FPS, 4), loop=loop)
    for name in ORIGINAL_ACTIONS:
        bpy.data.actions[name]["loop"] = name in LOOPING_ORIGINALS
        bpy.data.actions[name]["derived_from"] = ""


def pose_snapshot(rig, frame):
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    return {pb.name: pb.matrix_basis.copy() for pb in rig.pose.bones}


def pose_delta(a, b):
    return max(abs(x - y) for name in a for row_a, row_b in zip(a[name], b[name]) for x, y in zip(row_a, row_b))


def measure_actions(rig):
    scene = bpy.context.scene
    for action in sorted(bpy.data.actions, key=lambda a: a.name):
        set_action(rig, action)
        first, last = int(round(action.frame_range[0])), int(round(action.frame_range[1]))
        seam = pose_delta(pose_snapshot(rig, first), pose_snapshot(rig, last))
        hips0 = (rig.matrix_world @ rig.pose.bones["Hips"].head).copy()
        scene.frame_set(last)
        bpy.context.view_layer.update()
        hips1 = rig.matrix_world @ rig.pose.bones["Hips"].head
        stride = stride_speed(rig, first, last) if action.name in ("walk", "run", "run_looped") else None
        say("CLIP", name=action.name, frames=[first, last], seconds=round((last - first) / FPS, 4),
            loop=bool(action.get("loop")), seam_delta=round(seam, 4),
            hips_travel=[round(v, 4) for v in (hips1 - hips0)],
            stride_speed_model_units=None if stride is None else round(stride, 3))
    set_action(rig, None)
    scene.frame_set(1)


def stride_speed(rig, first, last):
    """Model-unit speed of the planted foot sliding back: the pace the clip
    was animated for. A foot is planted while it is within 1.5 cm of its
    lowest point in the clip; its -Y velocity then is the ground speed."""
    scene = bpy.context.scene
    samples = {foot: [] for foot in FEET}
    for frame in range(first, last + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        for foot in FEET:
            samples[foot].append((rig.matrix_world @ rig.pose.bones[foot].head).copy())
    speeds = []
    for foot in FEET:
        points = samples[foot]
        floor = min(p.z for p in points)
        for a, b in zip(points, points[1:]):
            if a.z - floor < 0.015 and b.z - floor < 0.015:
                speeds.append((b.y - a.y) * FPS)  # +Y is backwards: planted feet move +Y
    if not speeds:
        return 0.0
    speeds.sort()
    middle = speeds[len(speeds) // 4: max(len(speeds) * 3 // 4, len(speeds) // 4 + 1)]
    return sum(middle) / len(middle)


# ------------------------------------------------------------------ texture

def make_2k_texture(mesh):
    material = mesh.material_slots[0].material
    image = material_images(material)[0]
    source_path = Path(bpy.path.abspath(image.filepath))
    copy = image.copy()
    copy.scale(TEXTURE_2K_SIZE, TEXTURE_2K_SIZE)
    copy.file_format = "JPEG"
    copy.filepath_raw = str(TEXTURE_2K)
    TEXTURE_2K.parent.mkdir(parents=True, exist_ok=True)
    copy.save(filepath=str(TEXTURE_2K), quality=TEXTURE_JPEG_QUALITY)
    bpy.data.images.remove(copy)
    game = bpy.data.images.load(str(TEXTURE_2K), check_existing=False)
    game.name = "tripo_human_albedo_2k"
    for node in material.node_tree.nodes:
        if node.type == "TEX_IMAGE" and node.image == image:
            node.image = game
    bpy.data.images.remove(image)
    say("TEXTURE", source=source_path.name, source_size=[4096, 4096],
        game=str(TEXTURE_2K.relative_to(PROJECT)), game_size=list(game.size),
        game_bytes=TEXTURE_2K.stat().st_size, jpeg_quality=TEXTURE_JPEG_QUALITY)


# ------------------------------------------------------------------ export

def stash_all_actions(rig):
    set_action(rig, None)
    data = rig.animation_data
    for track in list(data.nla_tracks):
        data.nla_tracks.remove(track)
    for action in sorted(bpy.data.actions, key=lambda a: a.name):
        track = data.nla_tracks.new()
        track.name = action.name
        strip = track.strips.new(action.name, 1, action)
        if hasattr(strip, "action_slot") and len(action.slots):
            strip.action_slot = action.slots[0]
        track.mute = True
    bpy.context.scene.frame_set(1)


def select_only(objects):
    for obj in bpy.context.scene.objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


def export_mesh_glb(rig, mesh):
    select_only([rig, mesh])
    rig.data.pose_position = "REST"
    bpy.ops.export_scene.gltf(
        filepath=str(MESH_GLB), export_format="GLB", use_selection=True,
        export_yup=True, export_apply=False,
        export_texcoords=True, export_normals=True, export_materials="EXPORT",
        export_image_format="AUTO", export_skins=True, export_influence_nb=MAX_INFLUENCES,
        export_all_influences=False, export_def_bones=False,
        export_rest_position_armature=True, export_animations=False,
        export_extras=True,
    )
    rig.data.pose_position = "POSE"
    say("EXPORTED_MESH", path=str(MESH_GLB.relative_to(PROJECT)), bytes=MESH_GLB.stat().st_size)


def add_proxy_mesh(rig):
    """A 1 cm triangle at the hips, skinned to the rig, so the clip file has a
    skin and Godot gives it a Skeleton3D with the same 67 bones."""
    hips = rig.data.bones[PROXY_BONE].head_local
    data = bpy.data.meshes.new(PROXY_NAME)
    data.from_pydata([
        (hips.x, hips.y, hips.z),
        (hips.x + PROXY_SIZE, hips.y, hips.z),
        (hips.x, hips.y, hips.z + PROXY_SIZE),
    ], [], [(0, 1, 2)])
    proxy = bpy.data.objects.new(PROXY_NAME, data)
    bpy.context.scene.collection.objects.link(proxy)
    proxy.parent = rig
    group = proxy.vertex_groups.new(name=PROXY_BONE)
    group.add([0, 1, 2], 1.0, "REPLACE")
    modifier = proxy.modifiers.new("Armature", "ARMATURE")
    modifier.object = rig
    return proxy


def export_anims_glb(rig, proxy):
    select_only([rig, proxy])
    bpy.ops.export_scene.gltf(
        filepath=str(ANIMS_GLB), export_format="GLB", use_selection=True,
        export_yup=True, export_apply=False, export_materials="NONE",
        export_skins=True, export_def_bones=False,
        export_rest_position_armature=True,
        export_animations=True, export_animation_mode="ACTIONS",
        export_force_sampling=True, export_anim_slide_to_zero=True,
        # Channels that stay at rest for a whole clip are not written (with
        # or without this optimisation: measured 2026-11-06, 39..53 tracks
        # either way), so a bone another clip moved keeps that pose until a
        # clip with a track for it plays. Known; the game's clips all move
        # the same bones apart from the fingers.
        export_optimize_animation_size=True, export_frame_range=False,
        export_extras=True,
    )
    say("EXPORTED_ANIMS", path=str(ANIMS_GLB.relative_to(PROJECT)), bytes=ANIMS_GLB.stat().st_size)


def export_single_glb(rig, mesh, path: Path):
    """Comparison only: mesh + skin + every clip in one file, outside the project."""
    # Not in REST pose position: the exporter samples clips through the
    # armature's current pose mode, and REST would flatten every track.
    select_only([rig, mesh])
    bpy.ops.export_scene.gltf(
        filepath=str(path), export_format="GLB", use_selection=True,
        export_yup=True, export_apply=False, export_materials="EXPORT",
        export_image_format="AUTO", export_skins=True, export_influence_nb=MAX_INFLUENCES,
        export_def_bones=False, export_rest_position_armature=True,
        export_animations=True, export_animation_mode="ACTIONS",
        export_force_sampling=True, export_anim_slide_to_zero=True,
        export_optimize_animation_size=True, export_frame_range=False,
        export_extras=True,
    )
    say("EXPORTED_SINGLE_FOR_COMPARISON", path=str(path), bytes=path.stat().st_size)


# ------------------------------------------------------------------ re-verification

def verify_exports():
    expected_bones = EXPECTED_BONES + len(HANDSLOTS)
    # Mesh GLB.
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(MESH_GLB))
    scene = bpy.context.scene
    rigs = [o for o in scene.objects if o.type == "ARMATURE"]
    # The importer also links an "Icosphere" it uses as the bones' display
    # shape; it is not in the file (the JSON check below counts the real
    # meshes), so only meshes hanging off the rig are looked at here.
    meshes = [o for o in scene.objects if o.type == "MESH" and o.parent in rigs]
    if len(rigs) != 1 or len(meshes) != 1:
        fail("mesh glb has %d armatures and %d meshes (%s)" % (len(rigs), len(meshes), [m.name for m in meshes]))
    rig, mesh = rigs[0], meshes[0]
    if rig.name != RIG_NAME:
        fail("mesh glb armature is named %s" % rig.name)
    bone_names = sorted(b.name for b in rig.data.bones)
    if len(bone_names) != expected_bones:
        fail("mesh glb has %d bones, expected %d" % (len(bone_names), expected_bones))
    if any(BONE_PREFIX in n for n in bone_names):
        fail("mesh glb still carries the %s prefix" % BONE_PREFIX)
    for slot, (hand_name, *_rest) in HANDSLOTS.items():
        if slot not in rig.data.bones or rig.data.bones[slot].parent.name != hand_name:
            fail("%s missing or not under %s in the mesh glb" % (slot, hand_name))
    if len(mesh.data.vertices) == 0:
        fail("mesh glb mesh is empty")
    images = material_images(mesh.material_slots[0].material)
    if len(images) != 1 or tuple(images[0].size) != (TEXTURE_2K_SIZE, TEXTURE_2K_SIZE):
        fail("mesh glb texture is %s" % [tuple(i.size) for i in images])
    low, high = rest_bbox(rig, [mesh])
    if abs((high.z - low.z) - EXPECTED_HEIGHT) > HEIGHT_TOLERANCE:
        fail("mesh glb rest height %.4f" % (high.z - low.z))
    toe = rig.matrix_world @ rig.data.bones["LeftToe_End"].head_local
    heel = rig.matrix_world @ rig.data.bones["LeftFoot"].head_local
    if (toe - heel).y >= 0.0:
        fail("mesh glb does not face -Y in Blender")
    mesh_clips = len(bpy.data.actions)
    say("VERIFY_MESH", bones=len(bone_names), verts=len(mesh.data.vertices), faces=len(mesh.data.polygons),
        rest_height=round(high.z - low.z, 4), feet_z=round(low.z, 4), texture=list(images[0].size),
        clips_in_mesh_glb=mesh_clips, handslots={s: rig.data.bones[s].parent.name for s in HANDSLOTS})
    # Anims GLB.
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(ANIMS_GLB))
    scene = bpy.context.scene
    rigs = [o for o in scene.objects if o.type == "ARMATURE"]
    if len(rigs) != 1 or rigs[0].name != RIG_NAME:
        fail("anims glb armature: %s" % [r.name for r in rigs])
    proxies = [o for o in scene.objects if o.type == "MESH" and o.parent in rigs]
    if len(proxies) != 1 or proxies[0].name != PROXY_NAME or len(proxies[0].data.vertices) != 3:
        fail("anims glb should carry only the 3-vertex proxy, has %s" % [(m.name, len(m.data.vertices)) for m in proxies])
    if not any(m.type == "ARMATURE" and m.object == rigs[0] for m in proxies[0].modifiers):
        fail("the proxy is not skinned to the rig")
    anim_bones = sorted(b.name for b in rigs[0].data.bones)
    if anim_bones != bone_names:
        fail("anims glb bones differ from the mesh glb: %s" % sorted(set(anim_bones) ^ set(bone_names)))
    want = dict(ORIGINAL_ACTIONS)
    for name, (_src, first, last, _loop) in DERIVED_ACTIONS.items():
        want[name] = (1, last - first + 1)
    got = {}
    for action in bpy.data.actions:
        name = action.name.split("|")[-1] if "|" in action.name else action.name
        got[name] = round((action.frame_range[1] - action.frame_range[0]) / scene.render.fps, 3)
    missing = sorted(set(want) - set(got))
    extra = sorted(set(got) - set(want))
    if missing or extra:
        fail("anims glb clips missing %s extra %s (got %s)" % (missing, extra, sorted(got)))
    for name, (first, last) in want.items():
        expected = round((last - first) / FPS, 3)
        if abs(got[name] - expected) > 1.0 / FPS + 1e-3:
            fail("clip %s is %.3f s, expected %.3f s" % (name, got[name], expected))
    say("VERIFY_ANIMS", bones=len(anim_bones), proxy_verts=len(proxies[0].data.vertices),
        clips={k: got[k] for k in sorted(got)})
    verify_glb_json()


def read_glb_json(path: Path):
    import struct
    raw = path.read_bytes()
    magic, _version, _length = struct.unpack_from("<4sII", raw, 0)
    if magic != b"glTF":
        fail("%s is not a GLB" % path)
    chunk_length, _chunk_type = struct.unpack_from("<II", raw, 12)
    return json.loads(raw[20:20 + chunk_length])


def verify_glb_json():
    """Reads the two files' JSON directly: the skin both carry must list the
    same joints in the same order, so bone tracks in one resolve on the other."""
    mesh_doc = read_glb_json(MESH_GLB)
    anim_doc = read_glb_json(ANIMS_GLB)
    for label, doc in (("mesh", mesh_doc), ("anims", anim_doc)):
        if len(doc.get("skins", [])) != 1:
            fail("%s glb has %d skins" % (label, len(doc.get("skins", []))))
        if len(doc.get("meshes", [])) != 1:
            fail("%s glb has %d meshes" % (label, len(doc.get("meshes", []))))
    joints = lambda doc: [doc["nodes"][j]["name"] for j in doc["skins"][0]["joints"]]
    if joints(mesh_doc) != joints(anim_doc):
        fail("skin joint lists differ between the mesh and anims glb")
    root = lambda doc: doc["nodes"][doc["scenes"][0]["nodes"][0]]["name"]
    if root(mesh_doc) != RIG_NAME or root(anim_doc) != RIG_NAME:
        fail("scene roots are %s / %s" % (root(mesh_doc), root(anim_doc)))
    if mesh_doc.get("animations"):
        fail("mesh glb carries animations")
    say("VERIFY_JSON", joints=len(joints(mesh_doc)), same_joint_order=True, root=RIG_NAME,
        mesh_images=[(i.get("mimeType")) for i in mesh_doc.get("images", [])],
        anims=len(anim_doc.get("animations", [])),
        generator=mesh_doc["asset"].get("generator"))


# ------------------------------------------------------------------ main

def single_path():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--single" in argv:
        return Path(argv[argv.index("--single") + 1]).resolve()
    return None


def main():
    say("START", blender=bpy.app.version_string, python=sys.version.split()[0], project=str(PROJECT))
    check_source()
    workdir = Path(tempfile.mkdtemp(prefix="tripo_human_build_"))
    try:
        fbx = extract_source(workdir)
        rig, mesh = import_fbx(fbx)
        validate_import(rig, mesh)
        rename_everything(rig, mesh)
        add_handslots(rig)
        derive_actions(rig)
        measure_actions(rig)
        make_2k_texture(mesh)
        stash_all_actions(rig)
        ASSET.mkdir(parents=True, exist_ok=True)
        export_mesh_glb(rig, mesh)
        single = single_path()
        if single is not None:
            export_single_glb(rig, mesh, single)
        proxy = add_proxy_mesh(rig)
        export_anims_glb(rig, proxy)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    verify_exports()
    say("DONE", mesh_glb=str(MESH_GLB.relative_to(PROJECT)), anims_glb=str(ANIMS_GLB.relative_to(PROJECT)),
        texture_2k=str(TEXTURE_2K.relative_to(PROJECT)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - the whole run is the unit
        print("BUILD_FAILED %s" % error)
        import traceback
        traceback.print_exc()
        sys.exit(1)
