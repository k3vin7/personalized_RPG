extends Node

# One bounded, two-peer B-a run, including a real host disconnect at the end.
# Test placement is queued into the same physics dispatcher as input/RPC work.
var _world: Node3D
var _local: Player
var _client_ready := false
var _client_finished := false
var _failures := 0
var _checks := 0
var _peer_id := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("BA_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func tick_request(action: Callable) -> void:
	Net.queue_physics(action)
	for _frame in range(3):
		await get_tree().physics_frame


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	Net.session_left.connect(_verify_leave)
	await _local_checks()
	if not multiplayer.is_server():
		client_ready.rpc_id(1)
		return
	for _wait in range(150):
		if _client_ready:
			break
		await get_tree().create_timer(0.1).timeout
	expect(_client_ready, "both_peers_completed_local_checks")
	await _rock_checks()
	var peers := multiplayer.get_peers()
	if peers.size() == 1:
		var rock := _world.get_node("Rock_2") as Rock
		await tick_request(func() -> void:
			_local.respawn()
			_local.global_position = Vector3(-14.0, 0.9, 8.0))
		exercise_requests.rpc_id(peers[0], _local.get_path(), rock.get_path())
		await get_tree().create_timer(0.5).timeout
		expect(_local.hp == _local.stats.max_hp and _local.state != Player.State.GRABBED, "forged_force_and_grab_rejected")
		expect(rock.holder_peer == 0, "remote_far_grab_rejected")
		for _wait in range(120):
			if _client_finished:
				break
			await get_tree().create_timer(0.1).timeout
		expect(_client_finished, "client_legitimate_requests_completed")
		expect(is_equal_approx(_local.hp, _local.stats.max_hp - 1.0), "authenticated_client_force_preserved")
	else:
		expect(false, "exactly_two_peers")
	# Both persistent check nodes verify the menu and absence of world bodies.
	Net.leave("B-a 호스트 종료 확인")


func _local_checks() -> void:
	var panel := _world.get_node("DebugPanel") as DebugPanel
	_local.movement.set_aim_override(_local.global_position + Vector3(8.0, 0.0, 0.0))
	var preview := panel._preview_launch_velocity()
	expect(preview.is_equal_approx(_local.movement.jump_launch_velocity()) and preview.x > 0.0, "cursor_preview_matches_launch")
	_local.movement.set_aim_override(_local.global_position)
	expect(is_zero_approx(panel._preview_launch_velocity().x), "self_aim_preview_vertical")
	_local.movement.set_aim_override(Vector3.INF)
	var escape_slider := panel.find_child("grabbed_escape_presses", true, false) as HSlider
	expect(escape_slider != null and escape_slider.step == 1.0 and escape_slider.value == 5.0, "integer_tuning_slider")
	if escape_slider != null:
		escape_slider.value = 6
		expect(Tuning.values.grabbed_escape_presses == 6, "integer_slider_updates_resource")
		escape_slider.value = 5
	var kill_slider := panel.find_child("kill_plane_y", true, false) as HSlider
	expect(kill_slider != null and kill_slider.min_value <= -20.0 and kill_slider.value == -20.0, "negative_kill_plane_range")
	if kill_slider != null:
		kill_slider.value = -24.0
		expect(is_equal_approx(Tuning.values.kill_plane_y, -24.0), "negative_slider_updates_resource")
		kill_slider.value = -20.0
	await tick_request(func() -> void:
		_local.hp = 1.0
		_local.apply_force_event(ForceSystem.make_event(ForceSystem.Kind.DEBUG, Vector3.RIGHT, 1.0, 0.0, 1, false, 2.0, 1.0))
		_local.change_state(Player.State.STUNNED)
		expect(_local.state == Player.State.DEAD and _local.hp == 0.0, "lethal_force_stays_dead")
		_local.apply_force_event(ForceSystem.make_event(ForceSystem.Kind.DEBUG, Vector3.UP, 10.0, 0.0, 1, false))
		expect(_local.state == Player.State.DEAD and _local.velocity == Vector3.ZERO, "dead_body_ignores_force")
		_local.respawn()
		expect(_local.state == Player.State.IDLE and _local.hp == _local.stats.max_hp, "explicit_respawn_still_works"))
	var terrain := _world.get_node("TimeBoundary") as TimeBoundary
	var overlay := _world.get_node("BoundaryOverlay") as Node3D
	expect(terrain.get_node_or_null("SeamPane") == null and terrain.get_node_or_null("SeamDust") == null, "old_boundary_effects_removed")
	var entries: Array = preload("res://data/world_boundaries.tres").get("boundaries")
	expect(overlay.visible and overlay.get_child_count() == entries.size(), "debug_boundary_data_and_default")
	var render_only := true
	for child in overlay.get_children():
		var mesh := child as MeshInstance3D
		render_only = render_only and mesh != null and mesh.get_child_count() == 0 and mesh.layers == (1 << 19) and mesh.get_groups().is_empty()
	expect(render_only, "boundary_render_only_separate_layer")
	var nav := _world.get_node("NavigationRegion3D") as NavigationRegion3D
	var polygons := nav.navigation_mesh.get_polygon_count()
	var toggle := panel.find_child("DebugBoundaries", true, false) as CheckButton
	toggle.button_pressed = false
	expect(not overlay.visible, "boundary_ui_toggle_off")
	toggle.button_pressed = true
	expect(overlay.visible and nav.navigation_mesh.get_polygon_count() == polygons, "boundary_toggle_preserves_navmesh")
	await tick_request(func() -> void:
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(TimeBoundary.SEAM.x, 1.5, terrain.face_z() + 3.0),
			Vector3(TimeBoundary.SEAM.x, 1.5, terrain.face_z() - 1.0), Layers.TERRAIN)
		var hit := _local.get_world_3d().direct_space_state.intersect_ray(query)
		expect(hit.get("collider") == terrain.face, "aura_does_not_intercept_click_ray")
		_local.global_position = Vector3(TimeBoundary.SEAM.x + (3.0 if _peer_id != 1 else 0.0), 0.9, terrain.face_z() + 5.0))
	await get_tree().create_timer(0.6).timeout
	if _peer_id == 1 and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--ba-image="):
				get_viewport().get_texture().get_image().save_png(argument.trim_prefix("--ba-image="))
	await tick_request(func() -> void:
		var contact := Vector3(_local.global_position.x, 1.2, terrain.face_z())
		expect(_local.climb.attach(terrain.face, contact, Vector3.BACK), "retained_ledge_climb_attach")
		_local.climb.set_wall_target(Vector3(contact.x, TimeBoundary.TOP_Y + 0.6, contact.z)))
	await get_tree().create_timer(5.0).timeout
	expect(_local.global_position.y > TimeBoundary.TOP_Y + 0.7 and _local.state == Player.State.IDLE, "retained_ledge_mantle")
	await tick_request(_local.respawn)


func _rock_checks() -> void:
	var rock := _world.get_node("Rock_2") as Rock
	await tick_request(func() -> void:
		_local.global_position = rock.global_position + Vector3(20.0, 0.0, 0.0)
		expect(not rock.host_grab(1), "rock_rejects_far_holder")
		_local.global_position = rock.global_position + Vector3(1.0, 0.3, 0.0)
		_local.stats.strength = 1.0
		expect(not rock.host_grab(1), "rock_rejects_insufficient_strength")
		_local.stats.strength = 10.0
		_local.change_state(Player.State.AIRBORNE)
		expect(not rock.host_grab(1), "rock_rejects_airborne_holder")
		_local.change_state(Player.State.IDLE)
		expect(rock.host_grab(1), "rock_accepts_near_20kg_at_strength_10")
		expect(not rock.host_grab(1), "rock_rejects_duplicate_hold")
		rock.host_release(1)
		_local.respawn())


@rpc("any_peer", "call_remote", "reliable")
func client_ready() -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_client_ready = true


@rpc("authority", "call_remote", "reliable")
func exercise_requests(host_path: NodePath, rock_path: NodePath) -> void:
	var host_player := get_node(host_path) as Player
	var rock := get_node(rock_path) as Rock
	ForceSystem.receive_force.rpc_id(1, host_path, ForceSystem.make_event(
		ForceSystem.Kind.DEBUG, Vector3.UP, 50.0, 0.0, 1, false, 1000.0, 1.0))
	host_player.request_grab.rpc_id(1, 1)
	host_player.grab_answer.rpc_id(1, host_path, true)
	rock.request_grab.rpc_id(1)
	await get_tree().create_timer(1.0).timeout
	await tick_request(func() -> void:
		_local.respawn()
		_local.global_position = rock.global_position + Vector3(1.0, 0.3, 0.0))
	await get_tree().create_timer(0.4).timeout
	await tick_request(func() -> void: _local.grab._ask_rock(rock))
	await get_tree().create_timer(0.8).timeout
	expect(_local.grab.is_holding() and rock.holder_peer == _peer_id, "client_valid_rock_grab")
	await tick_request(func() -> void:
		_local.movement.set_aim_override(_local.global_position + Vector3.RIGHT * 10.0)
		expect(_local.grab.throw(), "client_valid_rock_throw")
		_local.movement.set_aim_override(Vector3.INF)
		ForceSystem.send(host_player, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE, Vector3.RIGHT, 1.0, _local.stats.strength, _peer_id, false, 1.0, 0.0)))
	await get_tree().create_timer(0.4).timeout
	await tick_request(func() -> void:
		_local.global_position = host_player.global_position + Vector3(1.2, 0.0, 0.0))
	await get_tree().create_timer(0.4).timeout
	await tick_request(func() -> void: _local.grab._ask_player(host_player))
	await get_tree().create_timer(0.8).timeout
	expect(_local.grab.is_holding() and host_player.state == Player.State.GRABBED, "authenticated_player_grab_reply")
	await tick_request(func() -> void:
		_local.grab.drop()
		_local.change_state(Player.State.IDLE))
	await get_tree().create_timer(0.8).timeout
	client_finished.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func client_finished() -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_client_finished = true


func _verify_leave(_message: String) -> void:
	for _frame in range(4):
		await get_tree().process_frame
	expect(get_tree().current_scene != null and get_tree().current_scene.scene_file_path == "res://scenes/main.tscn", "disconnect_returns_to_menu")
	expect(not is_instance_valid(_world) and get_tree().get_nodes_in_group(Rock.GROUP).is_empty(), "disconnect_frees_world_bodies")
	expect(Net.spawn_root == null and Net.spawner == null and not multiplayer.has_multiplayer_peer(), "disconnect_clears_session")
	# Allow several physics ticks to expose callbacks accidentally left alive.
	await get_tree().create_timer(0.5).timeout
	print("BA_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)
