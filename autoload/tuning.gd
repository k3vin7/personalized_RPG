extends Node

# Two tables, one per owner.
#
# `server` is PhysicsTuning: every number a ruling, a trajectory or a cost is
# built from. It is the server's. The server reads and writes its own copy; a
# client holds a replica that ServerAuthority.push_server_tuning overwrites,
# and the replica refuses any other write (PhysicsTuning's setters ask
# may_write). So the gravity a client's jump is launched with and the gravity
# the server checks that jump against are one number, and a client that edits
# its own copy edits nothing.
#
# `values` is LocalTuning: how a press is read and what is drawn. Per peer, by
# design -- two people can set these apart and nothing they do to each other
# changes.
#
# Plus the single strength-to-weight formula the work order requires every
# calculation to go through. Nothing else may reimplement it.

const SERVER_TUNING_PATH := "res://data/physics_tuning.tres"

signal tuning_changed()
signal debug_boundaries_changed()

# Presentation preference, never imported from anywhere.
var debug_boundaries_visible := true:
	set(value):
		debug_boundaries_visible = value
		debug_boundaries_changed.emit()

var values: LocalTuning
var server: PhysicsTuning
# The shipped defaults, kept for the clamp: a slider's range is built from what
# the number was, not from what it has been pushed to.
var _defaults: PhysicsTuning
var _importing := false


func _ready() -> void:
	values = LocalTuning.new()
	var loaded := load(SERVER_TUNING_PATH) as PhysicsTuning
	_defaults = loaded if loaded != null else PhysicsTuning.new()
	# Duplicated so the file is never the live table. The duplicate is made
	# before it becomes `server`, so its setters let the copy through.
	server = _defaults.duplicate(true)


# True on the peer that rules: the server, or a single process with no peer.
func is_judge() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


# Asked by every PhysicsTuning setter. The live server table may be written by
# the server, and on a client only by the import that carries the server's
# values. Any other PhysicsTuning (a copy being made, the defaults) is free.
func may_write(resource: Resource) -> bool:
	return resource != server or _importing or is_judge()


# ratio_mult(ratio, k) = clamp(1 + k * ln(ratio / ratio_ref), min, max)
# Log so that a bigger ratio keeps helping but with falling returns, and
# divided by the reference so that the body the _base values were measured on
# -- v4's human at training 0, bare, at 0.75 -- lands exactly on 1.0.
# mult_max below 0 means the shared server.ratio_mult_max; a caller with its
# own cap (the straight throw) passes it here. The formula is the same.
func ratio_mult(ratio: float, k: float, mult_max: float = -1.0) -> float:
	var reference: float = maxf(server.ratio_ref, 0.0001)
	var top: float = server.ratio_mult_max if mult_max < 0.0 else mult_max
	return clampf(1.0 + k * log(maxf(ratio, 0.0001) / reference),
		server.ratio_mult_min, top)


func notify_changed() -> void:
	tuning_changed.emit()


# The exported fields of a tuning resource, by name. Same filter the debug
# panel uses, so the two never disagree about what a "field" is.
static func field_names(resource: Resource) -> PackedStringArray:
	var out := PackedStringArray()
	for property in resource.get_property_list():
		if not (int(property["usage"]) & PROPERTY_USAGE_EDITOR):
			continue
		var name_text := String(property["name"])
		if name_text.begins_with("resource_") or name_text == "script":
			continue
		out.append(name_text)
	return out


func is_server_field(field: String) -> bool:
	return field in field_names(server)


func server_default(field: String) -> Variant:
	return _defaults.get(field)


# The range a server number may be pushed to, from its shipped default: four
# times it, with the sign kept. The same range the panel's slider shows, so
# what the slider can ask for is exactly what the server will accept.
func limits_for(field: String) -> Vector2:
	var value := float(server_default(field))
	if field == "kill_plane_y" or value < 0.0:
		return Vector2(minf(value * 4.0, -1.0), 0.0)
	# C-1a: armour ships at 0 (no gear) and the formula is read out to 400.
	if field.begins_with("armor_") and field != "armor_flat_pct":
		return Vector2(0.0, 500.0)
	return Vector2(1.0 if field == "grabbed_escape_presses" else 0.0, maxf(value * 4.0, 1.0))


# The whole server table as a dictionary: what travels in push_server_tuning.
func export_server() -> Dictionary:
	var out := {}
	for field in field_names(server):
		out[field] = server.get(field)
	return out


# The server's values arriving on a replica. Only known fields, only matching
# types; the import flag is what lets the setters through.
func import_server(incoming: Dictionary) -> void:
	_importing = true
	for key in incoming.keys():
		var field := String(key)
		if not is_server_field(field):
			continue
		var current: Variant = server.get(field)
		var value: Variant = incoming[key]
		if typeof(current) == TYPE_BOOL:
			if value is bool:
				server.set(field, value)
		elif typeof(current) == TYPE_INT:
			if (value is int or value is float) and is_finite(float(value)):
				server.set(field, roundi(float(value)))
		elif typeof(current) == TYPE_FLOAT:
			if (value is int or value is float) and is_finite(float(value)):
				server.set(field, float(value))
	_importing = false
	tuning_changed.emit()
