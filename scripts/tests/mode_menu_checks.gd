extends Node

# The first screen (2026-11-07): the host picks a world, a joiner only an
# address. Instances the menu scene, presses its buttons the way a person
# would and reads what shows. No session is opened. Run as a scene (an
# autoload, Net, is read, and --script does not load autoloads):
#   godot --headless --path . res://scenes/tests/mode_menu_test.tscn

var _checks := 0
var _failures := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("MENU_CHECK %s %s" % ["PASS" if condition else "FAIL", label])


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var menu := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Control
	add_child(menu)
	await get_tree().process_frame
	var pick := menu.find_child("Pick", true, false) as Control
	var session := menu.find_child("Session", true, false) as Control
	var host := menu.find_child("Host", true, false) as Control
	var join := menu.find_child("Join", true, false) as Control
	var address := menu.find_child("AddressRow", true, false) as Control
	var mode := menu.find_child("Mode", true, false) as Label
	expect(pick != null and session != null and host != null and join != null and mode != null, "the_menu_has_its_panels_and_buttons")
	expect(pick.visible and not session.visible, "the_first_screen_is_the_pick_not_host_join")
	var picks := {}
	for world in ["playground", "village"]:
		var button := menu.find_child("Pick_" + world, true, false) as Button
		expect(button != null and button.text.begins_with(Net.WORLD_LABELS[world]), "pick_button_%s_shows_its_label" % world)
		picks[world] = button
	var join_pick := menu.find_child("JoinPick", true, false) as Button
	expect(join_pick != null, "the_first_screen_offers_join")
	# Host the village: the port and Host show, the address and Join do not.
	picks["village"].pressed.emit()
	await get_tree().process_frame
	expect(Net.world == "village" and session.visible and not pick.visible, "hosting_the_play_test_opens_the_session_panel_for_the_village")
	expect(host.visible and not join.visible and not address.visible, "a_host_sees_start_and_no_address")
	expect(mode.text.begins_with(Net.WORLD_LABELS["village"]), "the_session_panel_names_the_pick")
	(menu.find_child("Back", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	expect(pick.visible and not session.visible, "back_returns_to_the_pick")
	# Join: the address and Join show, Host does not; the world is the host's.
	join_pick.pressed.emit()
	await get_tree().process_frame
	expect(session.visible and join.visible and address.visible and not host.visible, "a_joiner_sees_address_and_join_and_no_start")
	(menu.find_child("Back", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	picks["playground"].pressed.emit()
	await get_tree().process_frame
	expect(Net.world == "playground" and host.visible, "hosting_the_physics_test_picks_the_playground")
	expect(Net.WORLD_SCENES["playground"] == Net.PLAYGROUND_SCENE
		and ResourceLoader.exists(Net.WORLD_SCENES["village"]), "both_worlds_point_at_a_scene_that_exists")
	print("MENU_RESULT checks=%d failures=%d" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)
