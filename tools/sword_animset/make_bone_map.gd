extends SceneTree
## Writes the bone map that renames the Unreal-mannequin skeleton of the
## one-handed sword pack onto Godot's SkeletonProfileHumanoid. The import
## settings of every FBX in the pack point at this file (setup_import.gd).
##
##   godot --headless --path . --script tools/sword_animset/make_bone_map.gd

const OUT := "res://assets/retarget/ue_mannequin_bone_map.tres"

# profile bone -> Unreal mannequin bone. Eyes and jaw: the mannequin has none.
const MAP := {
	"Root": "root", "Hips": "pelvis",
	"Spine": "spine_01", "Chest": "spine_02", "UpperChest": "spine_03",
	"Neck": "neck_01", "Head": "head",
	"LeftShoulder": "clavicle_l", "LeftUpperArm": "upperarm_l", "LeftLowerArm": "lowerarm_l", "LeftHand": "hand_l",
	"RightShoulder": "clavicle_r", "RightUpperArm": "upperarm_r", "RightLowerArm": "lowerarm_r", "RightHand": "hand_r",
	"LeftUpperLeg": "thigh_l", "LeftLowerLeg": "calf_l", "LeftFoot": "foot_l", "LeftToes": "ball_l",
	"RightUpperLeg": "thigh_r", "RightLowerLeg": "calf_r", "RightFoot": "foot_r", "RightToes": "ball_r",
}

# profile finger name -> mannequin finger name, joints 01..03.
const FINGERS := {"Thumb": "thumb", "Index": "index", "Middle": "middle", "Ring": "ring", "Little": "pinky"}
const THUMB_JOINTS := ["Metacarpal", "Proximal", "Distal"]
const FINGER_JOINTS := ["Proximal", "Intermediate", "Distal"]


func _init() -> void:
	var map := BoneMap.new()
	map.profile = SkeletonProfileHumanoid.new()
	for key in MAP:
		map.set_skeleton_bone_name(StringName(key), StringName(MAP[key]))
	for side in [["Left", "l"], ["Right", "r"]]:
		for finger in FINGERS:
			var joints: Array = THUMB_JOINTS if finger == "Thumb" else FINGER_JOINTS
			for i in 3:
				map.set_skeleton_bone_name(StringName("%s%s%s" % [side[0], finger, joints[i]]),
					StringName("%s_%02d_%s" % [FINGERS[finger], i + 1, side[1]]))
	DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
	var err := ResourceSaver.save(map, OUT)
	print("make_bone_map: ", OUT, " err=", err)
	quit(0 if err == OK else 1)
