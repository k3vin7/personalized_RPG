extends Control

# The first screen (2026-11-07): what to host, or join. The host picks the
# world -- the physics test (the playground, every harness stage) or the play
# test (the Finimes village) -- then a port; a joiner only gives an address
# and a port, and lands in whatever the host picked (Net.assign_world).
# Nothing else lives here: the session itself belongs to Net.

var _pick: VBoxContainer
var _session: VBoxContainer
var _mode_label: Label
var _host_row: Control
var _join_rows: Array[Control] = []
var _address: LineEdit
var _port: SpinBox
var _status: Label
var _pick_status: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Net.status_changed.connect(_set_status)
	Net.session_left.connect(_on_session_left)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-220.0, -200.0)
	panel.custom_minimum_size = Vector2(440.0, 400.0)
	add_child(panel)

	_pick = _build_pick()
	panel.add_child(_pick)
	_session = _build_session()
	_session.visible = false
	panel.add_child(_session)
	_set_status(Net.leave_message)


# ------------------------------------------------------------ 1: the pick

func _build_pick() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.name = "Pick"
	column.add_theme_constant_override("separation", 12)

	var title := Label.new()
	title.text = "물리 놀이터"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)

	var note := Label.new()
	note.text = "호스트는 무엇을 열지 고릅니다. 접속하는 쪽은 호스트가 연 곳으로 들어갑니다."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)

	for world in ["playground", "village"]:
		var button := Button.new()
		button.name = "Pick_" + world
		button.text = "%s — 호스트" % Net.WORLD_LABELS[world]
		button.custom_minimum_size.y = 44.0
		button.pressed.connect(_on_pick.bind(world))
		column.add_child(button)

	var join_button := Button.new()
	join_button.name = "JoinPick"
	join_button.text = "접속 (IP · 포트)"
	join_button.custom_minimum_size.y = 44.0
	join_button.pressed.connect(_on_join_pick)
	column.add_child(join_button)

	_pick_status = Label.new()
	_pick_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pick_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pick_status.custom_minimum_size.y = 40.0
	column.add_child(_pick_status)

	var quit_button := Button.new()
	quit_button.text = "종료"
	quit_button.pressed.connect(get_tree().quit)
	column.add_child(quit_button)
	return column


func _on_pick(world: String) -> void:
	Net.world = world
	_mode_label.text = "%s — 호스트" % Net.WORLD_LABELS[world]
	_host_row.visible = true
	for row in _join_rows:
		row.visible = false
	_pick.visible = false
	_session.visible = true
	_set_status("")


func _on_join_pick() -> void:
	_mode_label.text = "접속 — 월드는 호스트가 정합니다"
	_host_row.visible = false
	for row in _join_rows:
		row.visible = true
	_pick.visible = false
	_session.visible = true
	_set_status("")


# ------------------------------------------------------------ 2: the session

func _build_session() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.name = "Session"
	column.add_theme_constant_override("separation", 12)

	_mode_label = Label.new()
	_mode_label.name = "Mode"
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.add_theme_font_size_override("font_size", 20)
	column.add_child(_mode_label)

	var address_row := HBoxContainer.new()
	address_row.name = "AddressRow"
	column.add_child(address_row)
	var address_label := Label.new()
	address_label.text = "IP"
	address_label.custom_minimum_size.x = 40.0
	address_row.add_child(address_label)
	_address = LineEdit.new()
	_address.text = "127.0.0.1"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address_row.add_child(_address)
	_join_rows.append(address_row)

	var port_row := HBoxContainer.new()
	column.add_child(port_row)
	var port_label := Label.new()
	port_label.text = "포트"
	port_label.custom_minimum_size.x = 40.0
	port_row.add_child(port_label)
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = Net.DEFAULT_PORT
	_port.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	port_row.add_child(_port)

	var host_button := Button.new()
	host_button.name = "Host"
	host_button.text = "시작 (Host)"
	host_button.pressed.connect(_on_host)
	column.add_child(host_button)
	_host_row = host_button

	var join_button := Button.new()
	join_button.name = "Join"
	join_button.text = "접속 (Join)"
	join_button.pressed.connect(_on_join)
	column.add_child(join_button)
	_join_rows.append(join_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.custom_minimum_size.y = 50.0
	column.add_child(_status)

	var back_button := Button.new()
	back_button.name = "Back"
	back_button.text = "← 처음으로"
	back_button.pressed.connect(_on_back)
	column.add_child(back_button)
	return column


func _on_back() -> void:
	_session.visible = false
	_pick.visible = true


func _on_host() -> void:
	Net.host(int(_port.value))


func _on_join() -> void:
	var address := _address.text.strip_edges()
	if address.is_empty():
		_set_status("IP 주소를 입력하세요.")
		return
	Net.join(address, int(_port.value))


func _set_status(message: String) -> void:
	if is_instance_valid(_status):
		_status.text = message
	if is_instance_valid(_pick_status):
		_pick_status.text = message


func _on_session_left(message: String) -> void:
	_set_status(message)
