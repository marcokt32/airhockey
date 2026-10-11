extends CharacterBody2D

const FIELD := Vector2(320, 640)

@export var radius: float = 28.0
@export var follow_speed: float = 2000.0  # velocidade máxima ao seguir o dedo (px/s)
@export var key_speed: float = 450.0      # velocidade com as setas (testes no PC)
@export var remote_smoothing: float = 25.0

# --- CPU (modo contra o computador) ---
@export var ai := false        # true = este taco é controlado pela CPU
@export var ai_level := 1      # 0 fácil, 1 normal, 2 difícil

# speed = velocidade máx. do taco | react = reação (s) | aim = erro de mira (rad)
# err = erro ao interceptar (px) | aggr = chance de atacar quando pode (0..1)
# atk = velocidade máx. do disco que ela ainda enfrenta de frente (px/s)
# home_y = onde espera: quanto maior, mais avançada (mais perto do meio)
const AI_LEVELS := [
	{"speed": 500.0,  "react": 0.16, "aim": 0.35, "err": 45.0, "aggr": 0.25, "atk": 180.0, "home_y": 70.0},
	{"speed": 1000.0,  "react": 0.8, "aim": 0.15, "err": 16.0, "aggr": 0.60, "atk": 350.0, "home_y": 95.0},
	{"speed": 2000.0, "react": 0.04, "aim": 0.04, "err": 4.0,  "aggr": 0.90, "atk": 700.0, "home_y": 125.0},
]

var side := 0 # 0 = metade de baixo, 1 = metade de cima
var is_rival := false   # definido pelo main.gd antes de entrar na árvore
var color := Color.WHITE
const RIVAL_HUE_SHIFT := -0.35
@onready var _sprite: Sprite2D = $Sprite2D   # ajuste se o nó tiver outro nome
@export var sync_pos := Vector2.ZERO  # sincronizado pelo MultiplayerSynchronizer

var _target := Vector2.ZERO
var _pressing := false
var _ai_timer := 0.0
var _ai_speed := 950.0
var _ai_vel := Vector2.ZERO   # velocidade atual (o taco acelera e freia, não é instantâneo)
var _ai_attacking := false   # decidiu atacar (mantém por um tempo, sem ficar trocando)
var _ai_commit := 0.0
var _ai_gain := 7.0           # quão cedo começa a frear ao chegar no alvo

func _enter_tree() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())

func _ready() -> void:
	sync_pos = position
	_target = position
	if is_rival and _sprite.material is ShaderMaterial:
		_sprite.material = _sprite.material.duplicate()
		(_sprite.material as ShaderMaterial).set_shader_parameter("hue_shift", RIVAL_HUE_SHIFT)

func _is_local() -> bool:
	if multiplayer.multiplayer_peer == null:
		return true
	return is_multiplayer_authority()

func _input(event: InputEvent) -> void:
	if ai or not _is_local():
		return
	if UIStyle.ui_blocking:   # menu / confirmação aberto: o taco ignora toques
		_pressing = false
		return
	if event is InputEventMouseButton and event.pressed and event.position.y < UIStyle.hud_top:
		return                # toque no cabeçalho (avatar/menu) não move o taco
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
		if ai:
			_ai_step(delta)   # decide o alvo de vez em quando e já move o taco
		else:
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

# ------------------------------------------------------------ CPU

# A cada `react` segundos (com variação) decide o alvo; a cada tick move o taco
# com aceleração e frenagem, como uma mão e não como um robô.
func _ai_step(delta: float) -> void:
	_ai_timer -= delta
	_ai_commit -= delta
	if _ai_timer <= 0.0:
		_ai_think()
	_ai_move(delta)

func _ai_move(delta: float) -> void:
	var to := _target - position
	var dist := to.length()
	# velocidade desejada: rumo ao alvo, diminuindo ao se aproximar (sem parada seca)
	var want := Vector2.ZERO
	if dist > 0.5:
		want = to / dist * minf(_ai_speed, dist * _ai_gain)
	# aceleração limitada: leva uns 0,1 s para chegar à velocidade máxima
	_ai_vel = _ai_vel.move_toward(want, _ai_speed * 9.0 * delta)
	position += _ai_vel * delta
	# parede/linha do meio: zera a velocidade no eixo em que bateu
	var c := _clamp_to_half(position)
	if not is_equal_approx(c.x, position.x):
		_ai_vel.x = 0.0
	if not is_equal_approx(c.y, position.y):
		_ai_vel.y = 0.0
	position = c

func _ai_think() -> void:
	var puck := get_node_or_null("../../Puck")
	if puck == null:
		return
	var lv: Dictionary = AI_LEVELS[clampi(ai_level, 0, AI_LEVELS.size() - 1)]
	# reação nunca igual: às vezes demora mais, às vezes "hesita"
	_ai_timer = lv.react * randf_range(0.7, 1.4)
	if randf() < 0.06:
		_ai_timer += 0.12
	# nem sempre no máximo
	_ai_speed = lv.speed * randf_range(0.85, 1.0)
	_ai_gain = 7.0

	var pp: Vector2 = puck.position
	var pv: Vector2 = puck.velocity
	var pr: float = puck.radius
	var half := FIELD.y / 2.0
	var home := Vector2(FIELD.x / 2.0, lv.home_y)
	var t := home
	var speed := pv.length()

	# Só enfrenta disco que dá para alcançar: lento, em QUALQUER direção.
	# (antes, disco rápido indo de lado ou se afastando também liberava o ataque)
	var can_attack: bool = pp.y < half + 25.0 and speed < lv.atk
	if can_attack:
		if _ai_commit <= 0.0:   # re-sorteia de tempos em tempos (nível alto ataca mais vezes)
			_ai_attacking = randf() < lv.aggr
			_ai_commit = randf_range(0.6, 1.4)
	else:
		_ai_attacking = false
		_ai_commit = 0.0

	if can_attack and _ai_attacking:
		# --- ATAQUE: mira onde o disco ESTARÁ daqui a pouco, não onde ele está ---
		var ap := pp + pv * 0.12
		ap.x = clampf(ap.x, pr, FIELD.x - pr)
		var dir := (Vector2(FIELD.x / 2.0, FIELD.y) - ap).normalized()
		dir = dir.rotated(randf_range(-lv.aim, lv.aim))
		var behind := ap - dir * (pr + radius + 28.0)
		if position.y > ap.y - 4.0:
			# o disco passou de mim
			if speed < lv.atk * 0.4:
				# quase parado: contorna pelo lado, sem empurrá-lo para o meu gol
				var around_x := pp.x + (70.0 if pp.x < FIELD.x / 2.0 else -70.0)
				t = Vector2(around_x, pp.y - 60.0)
			else:
				# ainda se move: não dá para contornar, só proteger o gol
				t = _ai_guard(pp, home)
				_ai_gain = 14.0
		elif position.distance_to(behind) > 34.0:
			t = behind                      # prepara a tacada
		else:
			t = ap + dir * 120.0            # tacada: mira bem além do disco, em velocidade cheia
			_ai_gain = 14.0
	elif pv.y < -20.0:
		# --- DEFESA: disco vindo para o meu gol; vai ao ponto previsto ---
		var x := _ai_predict_x(puck, pp, pv, home.y)
		t = Vector2(x + randf_range(-lv.err, lv.err), home.y + 20.0)
		_ai_gain = 14.0                     # defesa é rápida
	else:
		# --- GUARDA: disco rápido na minha metade, ou longe/se afastando ---
		t = _ai_guard(pp, home)
		if pp.y < half and speed > lv.atk:
			_ai_gain = 14.0                 # disco rápido por perto: reage rápido
		else:
			# balanço lento de quem está "esperando", e um pouco de imprecisão
			t.x += sin(Time.get_ticks_msec() / 1000.0 * 1.3) * 18.0
			t += Vector2(randf_range(-6.0, 6.0), randf_range(-6.0, 6.0))

	_target = _clamp_to_half(t)

# Posição de guarda na frente do gol: acompanha o disco em x, sem sair da área do gol.
# Com o disco na minha metade acompanha de perto; longe, só de leve.
func _ai_guard(pp: Vector2, home: Vector2) -> Vector2:
	var follow := 0.75 if pp.y < FIELD.y / 2.0 else 0.3
	var x := home.x + (pp.x - home.x) * follow
	return Vector2(clampf(x, home.x - 65.0, home.x + 65.0), home.y)
	
# Em que x o disco cruza a linha y (com rebotes nas paredes laterais)
# Em que x o disco cruza a linha y, simulando a MESMA física do puck.gd:
# atrito a cada tick e rebote nas paredes laterais com ganho (wall_bounce).
# Lê os valores do próprio disco, então acompanha o que você mudar no Inspector.
func _ai_predict_x(puck: Node, pp: Vector2, pv: Vector2, y: float) -> float:
	if pv.y >= -1.0:
		return pp.x
	var pr: float = puck.radius
	var fr: float = puck.friction
	var wb: float = puck.wall_bounce
	var dt := 1.0 / Engine.physics_ticks_per_second
	var p := pp
	var v := pv
	for _i in 300:   # até ~5 s de trajetória
		v *= maxf(0.0, 1.0 - fr * dt)
		p += v * dt
		if p.x < pr:
			p.x = pr
			v.x = absf(v.x) * wb
		elif p.x > FIELD.x - pr:
			p.x = FIELD.x - pr
			v.x = -absf(v.x) * wb
		if p.y <= y:
			return p.x        # chegou na linha de defesa
		if v.length() < 8.0:
			return p.x        # parou antes de chegar
	return p.x

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, color)
	draw_circle(Vector2.ZERO, radius * 0.45, color.darkened(0.3))
