extends CharacterBody2D

const FIELD := Vector2(320, 640)

@export var radius: float = 28.0
@export var follow_speed: float = 2000.0  # velocidade máxima ao seguir o dedo (px/s)
@export var key_speed: float = 450.0      # velocidade com as setas (testes no PC)
@export var remote_smoothing: float = 25.0

var side := 0                 # 0 = metade de baixo, 1 = metade de cima
var color := Color.WHITE
@export var sync_pos := Vector2.ZERO  # sincronizado pelo MultiplayerSynchronizer

var _target := Vector2.ZERO
var _pressing := false

func _enter_tree() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())

func _ready() -> void:
	sync_pos = position
	_target = position

func _is_local() -> bool:
	if multiplayer.multiplayer_peer == null:
		return true
	return is_multiplayer_authority()

func _input(event: InputEvent) -> void:
	if not _is_local():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_pressing = event.pressed
		if _pressing:
			_target = _clamp_to_half(get_global_mouse_position())
	elif event is InputEventMouseMotion and _pressing:
		_target = _clamp_to_half(get_global_mouse_position())

func _clamp_to_half(p: Vector2) -> Vector2:
	var min_y := FIELD.y / 2.0 + radius if side == 0 else radius
	var max_y := FIELD.y - radius if side == 0 else FIELD.y / 2.0 - radius
	return Vector2(clampf(p.x, radius, FIELD.x - radius), clampf(p.y, min_y, max_y))

func _physics_process(delta: float) -> void:
	if _is_local():
		# Setas (para testar no PC): movem o alvo
		var keys := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
		if keys != Vector2.ZERO:
			if side == 1:
				keys = -keys  # câmera girada
			_target = _clamp_to_half(position + keys * key_speed * delta)

		position = position.move_toward(_target, follow_speed * delta)
		sync_pos = position
	else:
		position = position.lerp(sync_pos, 1.0 - exp(-remote_smoothing * delta))
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, color)
	draw_circle(Vector2.ZERO, radius * 0.45, color.darkened(0.3))
