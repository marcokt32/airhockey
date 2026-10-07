extends Node2D

signal goal(scorer_side: int)  # 0 = jogador de baixo marcou, 1 = jogador de cima

const FIELD := Vector2(320, 640)
const GOAL_W := 110.0      # igual ao do main.gd
const RADIUS := 16.0
const MAX_SPEED := 900.0
const FRICTION := 0.4      # 0 = desliza para sempre
const WALL_BOUNCE := 0.95
const SERVE_SPEED := 300.0

var velocity := Vector2.ZERO
var active := false
var _freeze := 0.0
var _serve_to := 0         # lado que recebe o próximo saque
var _target := Vector2.ZERO
var _prev_pos := {}
var _paddle_vel := {}

@onready var players: Node2D = get_node("../Players")

func _ready() -> void:
	position = FIELD / 2.0
	_target = position

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return  # ainda sem rede (menu): nada a fazer
	if not multiplayer.is_server():
		position = position.lerp(_target, 0.4)
		return
	if not active:
		return
	_update_paddle_velocities(delta)
	if _freeze > 0.0:
		_freeze -= delta
		if _freeze <= 0.0:
			_launch()
	else:
		velocity *= maxf(0.0, 1.0 - FRICTION * delta)
		position += velocity * delta
		_wall_bounce()
		_paddle_hits()
		_check_goal()
	_net_sync.rpc(position)

@rpc("authority", "unreliable")
func _net_sync(pos: Vector2) -> void:
	_target = pos

# --- controle (chamado pelo Main, só no servidor) ---
func serve() -> void:
	active = true
	_serve_to = randi() % 2
	_reset_center()

func stop() -> void:
	active = false
	_reset_center()
	_freeze = 0.0
	if multiplayer.multiplayer_peer != null:
		_net_sync.rpc(position)

func _reset_center() -> void:
	position = FIELD / 2.0
	velocity = Vector2.ZERO
	_freeze = 1.5

func _launch() -> void:
	var dir_y := 1.0 if _serve_to == 0 else -1.0
	velocity = Vector2(randf_range(-0.4, 0.4), dir_y).normalized() * SERVE_SPEED

# --- física ---
func _update_paddle_velocities(delta: float) -> void:
	for p in players.get_children():
		var prev: Vector2 = _prev_pos.get(p.name, p.position)
		_paddle_vel[p.name] = (p.position - prev) / delta
		_prev_pos[p.name] = p.position

func _wall_bounce() -> void:
	if position.x < RADIUS:
		position.x = RADIUS
		velocity.x = absf(velocity.x) * WALL_BOUNCE
	elif position.x > FIELD.x - RADIUS:
		position.x = FIELD.x - RADIUS
		velocity.x = -absf(velocity.x) * WALL_BOUNCE

	var in_goal := absf(position.x - FIELD.x / 2.0) < GOAL_W / 2.0
	if in_goal:
		return  # abertura do gol: o disco passa
	if position.y < RADIUS:
		position.y = RADIUS
		velocity.y = absf(velocity.y) * WALL_BOUNCE
	elif position.y > FIELD.y - RADIUS:
		position.y = FIELD.y - RADIUS
		velocity.y = -absf(velocity.y) * WALL_BOUNCE

func _paddle_hits() -> void:
	for p in players.get_children():
		var d: Vector2 = position - p.position
		var min_d: float = RADIUS + p.radius
		var dist := d.length()
		if dist >= min_d or dist < 0.001:
			continue
		var n := d / dist
		position = p.position + n * min_d  # empurra o disco para fora do rebatedor
		var pv: Vector2 = _paddle_vel.get(p.name, Vector2.ZERO)
		var rel := velocity - pv
		if rel.dot(n) < 0.0:
			rel = rel - 2.0 * rel.dot(n) * n
			velocity = (pv + rel).limit_length(MAX_SPEED)

func _check_goal() -> void:
	var scorer := -1
	if position.y < 0.0:
		scorer = 0     # entrou no gol de cima
	elif position.y > FIELD.y:
		scorer = 1     # entrou no gol de baixo
	if scorer == -1:
		return
	goal.emit(scorer)
	_serve_to = 1 - scorer  # quem sofreu o gol recebe o saque
	_reset_center()

func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS, Color.DARK_SLATE_GRAY)
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 32, Color(0, 0, 0, 0.5), 2.0)
