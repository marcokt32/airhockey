extends Node2D

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const FIELD := Vector2(320, 640)
const GOAL_W := 110.0  # igual ao do puck.gd
const START_POS := [Vector2(160, 560), Vector2(160, 80)]

var my_side := 0
var scores := [0, 0]
var camera: Camera2D
var score_label: Label

@onready var players: Node2D = $Players
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var puck: Node2D = $Puck

func _ready() -> void:
	camera = Camera2D.new()
	camera.position = FIELD / 2.0
	camera.ignore_rotation = false  # por padrão a câmera ignora rotação
	add_child(camera)

	var layer := CanvasLayer.new()
	add_child(layer)
	score_label = Label.new()
	score_label.size = Vector2(320, 30)
	score_label.position = Vector2(0, 6)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(score_label)
	_refresh_score()

	spawner.spawn_function = _spawn_player
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Net.hosted.connect(_on_hosted)
	puck.goal.connect(_on_goal)

# Roda em todos os aparelhos, com os mesmos dados
func _spawn_player(data: Dictionary) -> Node:
	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	var mine: bool = data.id == multiplayer.get_unique_id()
	p.name = str(data.id)
	p.side = data.side
	p.position = START_POS[data.side]
	p.color = Color.DEEP_SKY_BLUE if mine else Color.TOMATO  # eu sempre azul
	if mine:
		my_side = data.side
		camera.rotation = PI if my_side == 1 else 0.0  # espelha para o jogador de cima
		_refresh_score()
	return p

func _on_hosted() -> void:
	if DisplayServer.get_name() != "headless":
		_add_player(1)

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_add_player(id)
		_try_start()

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	if players.has_node(str(id)):
		players.get_node(str(id)).queue_free()
	puck.stop()

func _add_player(id: int) -> void:
	if players.get_child_count() >= 2:
		return  # só 2 jogadores por enquanto
	spawner.spawn({"id": id, "side": _free_side()})

func _free_side() -> int:
	for p in players.get_children():
		if p.side == 0:
			return 1
	return 0

func _try_start() -> void:
	if players.get_child_count() >= 2:
		scores = [0, 0]
		_set_score.rpc(0, 0)
		puck.serve()

func _on_goal(scorer_side: int) -> void:
	scores[scorer_side] += 1
	_set_score.rpc(scores[0], scores[1])

@rpc("authority", "call_local", "reliable")
func _set_score(a: int, b: int) -> void:
	scores = [a, b]
	_refresh_score()

func _refresh_score() -> void:
	score_label.text = "Você %d  x  %d Rival" % [scores[my_side], scores[1 - my_side]]

func _draw() -> void:
	var w := FIELD.x
	var h := FIELD.y
	var gl := w / 2.0 - GOAL_W / 2.0
	var gr := w / 2.0 + GOAL_W / 2.0
	var soft := Color(1, 1, 1, 0.5)
	draw_rect(Rect2(0, 0, w, h), Color("0b1d33"))
	# paredes, com abertura nos gols
	draw_line(Vector2(0, 0), Vector2(gl, 0), Color.WHITE, 4)
	draw_line(Vector2(gr, 0), Vector2(w, 0), Color.WHITE, 4)
	draw_line(Vector2(0, h), Vector2(gl, h), Color.WHITE, 4)
	draw_line(Vector2(gr, h), Vector2(w, h), Color.WHITE, 4)
	draw_line(Vector2(0, 0), Vector2(0, h), Color.WHITE, 4)
	draw_line(Vector2(w, 0), Vector2(w, h), Color.WHITE, 4)
	# meio de campo
	draw_line(Vector2(0, h / 2.0), Vector2(w, h / 2.0), soft, 2)
	draw_arc(Vector2(w / 2.0, h / 2.0), 50.0, 0.0, TAU, 48, soft, 2)
	# gols
	draw_rect(Rect2(gl, -24, GOAL_W, 24), Color(1, 1, 1, 0.15))
	draw_rect(Rect2(gl, h, GOAL_W, 24), Color(1, 1, 1, 0.15))
