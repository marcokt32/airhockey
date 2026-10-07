extends CanvasLayer

var _ip: LineEdit
var _status: Label

func _ready() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(32, 32)
	box.custom_minimum_size = Vector2(250, 0)
	box.add_theme_constant_override("separation", 16)

	var theme := Theme.new()
	theme.default_font_size = 16
	box.theme = theme
	add_child(box)

	_ip = LineEdit.new()
	_ip.text = "127.0.0.1"
	_ip.placeholder_text = "IP do servidor"
	box.add_child(_ip)

	var host_btn := Button.new()
	host_btn.text = "Hospedar"
	host_btn.pressed.connect(Net.host)
	box.add_child(host_btn)

	var join_btn := Button.new()
	join_btn.text = "Entrar"
	join_btn.pressed.connect(func(): Net.join(_ip.text.strip_edges()))
	box.add_child(join_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	Net.status_changed.connect(func(t: String):
		_status.text = t
		if t.begins_with("Hospedando") or t.begins_with("Conectado"):
			box.visible = false
	)
