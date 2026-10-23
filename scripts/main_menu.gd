extends Control

# Host or join. Nothing else lives here: the session itself belongs to Net.


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Net.status_changed.connect(_set_status)
	Net.session_left.connect(_on_session_left)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-200.0, -160.0)
	panel.custom_minimum_size = Vector2(400.0, 320.0)
	add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	var title := Label.new()
	title.text = "물리 놀이터"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)

	var note := Label.new()
	note.text = "한 창은 Host, 다른 창은 127.0.0.1로 Join"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(note)

	var host_button := Button.new()
	host_button.text = "Host"
	host_button.pressed.connect(_on_host)
	column.add_child(host_button)

	var address_row := HBoxContainer.new()
	column.add_child(address_row)
	var address_label := Label.new()
	address_label.text = "IP"
	address_label.custom_minimum_size.x = 40.0
	address_row.add_child(address_label)
	_address = LineEdit.new()
	_address.text = "127.0.0.1"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address_row.add_child(_address)

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

	var join_button := Button.new()
	join_button.text = "Join"
	join_button.pressed.connect(_on_join)
	column.add_child(join_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.custom_minimum_size.y = 50.0
	column.add_child(_status)

	var quit_button := Button.new()
	quit_button.text = "종료"
	quit_button.pressed.connect(get_tree().quit)
	column.add_child(quit_button)


var _address: LineEdit
var _port: SpinBox
var _status: Label


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


func _on_session_left(message: String) -> void:
	_set_status(message)
