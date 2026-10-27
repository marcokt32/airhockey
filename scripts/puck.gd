extends Node2D

signal goal(scorer_side: int, info: int)  # 0 = jogador de baixo marcou, 1 = jogador de cima; info = flags do gol (ver Achievements)
signal wall_hit(impact: float)  # disco bateu na parede (impact = velocidade contra ela, px/s)
signal paddle_hit(impact: float, mine: bool)  # taco bateu no disco (velocidade de aproximação, px/s; mine = foi o MEU taco)

const FIELD := Vector2(320, 640)
const GOAL_W := 110.0      # igual ao do main.gd
const WALL_MIN_IMPACT := 60.0   # batidas mais fracas que isso (px/s) não geram som
const HIT_MIN_IMPACT := 40.0    # toques no disco mais fracos que isso (px/s) não geram som
const PADDLE_LEAD_MAX := 0.06   # host: quanto (s) adianta o taco do cliente na colisão
const DEADZONE := 5.0           # cliente: erro de posição menor que isso (px) é ignorado
# --- Física do disco (ajustáveis no Inspector para testes) ---
@export_group("Disco")
##Tamanho do disco.
@export_range(8.0, 40.0, 0.5) var radius := 16.0:
	set(v):
		radius = v
		queue_redraw()
##Velocidade máxima do disco (px/s).
@export_range(100.0, 1500.0, 10.0) var max_speed := 650.0
##Atrito do disco (0 = desliza para sempre).
@export_range(0.0, 2.0, 0.05) var friction := 0.4
##Quanto de energia devolve o rebote na parede (1 = rebote perfeito). 
@export_range(0.5, 3.0, 0.01) var wall_bounce := 0.95
## velocidade do saque.
@export_range(100.0, 800.0, 10.0) var serve_speed := 260.0

@export_group("Golpe do taco")
## transferencia de energia do taco (>1 = mais energia)
@export_range(0.5, 1.5, 0.05) var hit_restitution := 1.0
## quanto da velocidade do taco passa ao disco (1 = normal)       
@export_range(0.5, 2.5, 0.05) var hit_boost := 1.0
## todo golpe lança o disco com este mínimo de velocidade.
@export_range(0.0, 500.0, 10.0) var min_hit_speed := 0.0

@export_group("Rede (predição no cliente)")
## velocidade com que a correção do servidor é absorvida (maior = mais rápido)
@export_range(5.0, 60.0, 1.0) var client_smooth := 12.0 
## erro maior que isso: aceita o servidor
@export_range(30.0, 400.0, 5.0) var resync_dist := 150.0
## limite da compensação de atraso (ms)
@export_range(0.0, 500.0, 10.0) var max_comp_ms := 300.0
## voo livre: quanto do erro do servidor corrige por pacote (1 = tudo, como antes)
@export_range(0.05, 1.0, 0.05) var client_blend := 0.12
## erro de posição acima disso = divergência real: adota o servidor
@export_range(10.0, 150.0, 5.0) var snap_dist := 45.0
## erro de velocidade acima disso = golpe/rebote do rival: adota o servidor
@export_range(20.0, 400.0, 10.0) var snap_vel := 120.0
@export_group("")

var velocity := Vector2.ZERO
var active := false
var _freeze := 0.0
var _serve_to := 0         # lado que recebe o próximo saque
var _target := Vector2.ZERO
var _vel := Vector2.ZERO   # velocidade estimada no cliente (servidor + predição)
var _frozen := true        # servidor avisa quando o disco está parado (saque/gol)
var _err := Vector2.ZERO   # correção visual pendente (servidor x previsão), decai sozinha
var _hold_until := 0       # até quando ignorar o servidor após um golpe previsto (ms)
var _prev_local := Vector2.ZERO
var _has_prev := false
var _prev_pos := {}
var _paddle_vel := {}
var _paddle_from := {}   # posição do rebatedor no tick anterior (para a colisão contínua)
var _mute_impacts := false   # true enquanto estima posição futura (sem som/vibração)
var _nerf_until := [0, 0]      # (ms) até quando o taco de cada lado está enfraquecido
var _nerf_power := [1.0, 1.0]  # força devolvida ao disco enquanto enfraquecido (1 = normal)
var _dbg_snaps := 0          # diagnóstico: quantas vezes o cliente adotou o servidor
var _dbg_t := 0.0
var _last_touch := -1        # lado do último taco que tocou o disco (-1 = ninguém desde o saque)
var _bounces := 0            # batidas na parede desde o último toque de taco (só conta no servidor)
var _since_launch := 0.0     # segundos de jogo desde o saque (só no servidor)

@onready var players: Node2D = get_node("../Players")

# --- Rastro (cauda de cometa) ---
const TRAIL_TIME := 0.35                       # quanto tempo cada ponto do rastro dura (s)
const TRAIL_COLOR := Color(1.0, 0.85, 0.1)     # amarelo
const TRAIL_JUMP := 80.0                       # salto maior que isso (gol/saque) apaga o rastro

var _trail: Line2D
var _trail_pts: Array[Vector2] = []
var _trail_t: Array[float] = []

func _ready() -> void:
	position = FIELD / 2.0
	_target = position
	process_physics_priority = 10   # roda DEPOIS dos tacos (padrão é 0)
	_make_trail()

func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return  # ainda sem rede (menu): nada a fazer
	if not multiplayer.is_server():
		_client_step(delta)
		return
	if not active:
		return
	_update_paddle_velocities(delta)
	if _freeze > 0.0:
		_freeze -= delta
		if _freeze <= 0.0:
			_launch()
	else:
		_since_launch += delta
		velocity *= maxf(0.0, 1.0 - friction * delta)
		var step_start := position
		position += velocity * delta
		_paddle_hits(step_start, delta)
		_wall_bounce()   # <- novo: o rebatedor não pode empurrar a bola para fora da parede
		_check_goal()
	if not multiplayer.get_peers().is_empty():
		_net_sync.rpc(position, velocity, _freeze > 0.0)

@rpc("authority", "unreliable_ordered")
func _net_sync(pos: Vector2, vel: Vector2, frozen: bool) -> void:
	_frozen = frozen
	# O dado chegou com atraso: avança o disco pela metade do ping, respeitando
	# as paredes (senão a estimativa atravessa a parede e a velocidade vem "antes
	# do rebote", gerando um snap falso).
	var est := pos
	var evel := vel
	if not frozen:
		_mute_impacts = true
		var w: Array = _walls(pos + vel * _oneway_s(), vel)
		_mute_impacts = false
		est = w[0]
		evel = w[1]
	# Acabei de bater no disco: o servidor ainda não viu meu golpe. Se eu
	# aceitasse esse estado antigo, o disco "voltaria". Espero a confirmação.
	if not frozen and Time.get_ticks_msec() < _hold_until \
			and (est - _target).length() < resync_dist:
		return
	_hold_until = 0
	var pos_err := est - _target
	var vel_err := (evel - _vel).length()
	if frozen or pos_err.length() > snap_dist or vel_err > snap_vel:
		# Divergência real (golpe do rival, gol, saque): adota o servidor.
		# O que está na tela vira "erro" que decai aos poucos, sem pulo.
		if not frozen:
			_dbg_snaps += 1
		var seen := position - est
		_err = seen if seen.length() < resync_dist else Vector2.ZERO
		_target = est
		_vel = evel
	else:
		# Voo livre: minha simulação já está certa. Só corrijo a deriva aos
		# poucos, assim o ruído de tempo dos pacotes não vira oscilação.
		if pos_err.length() < DEADZONE:
			pos_err = Vector2.ZERO
		var d := pos_err * client_blend
		_target += d
		_err -= d            # a tela não se mexe: a correção é absorvida devagar
		_vel = _vel.lerp(evel, client_blend)

# --- cliente: simula localmente e prevê o golpe do próprio taco ---
func _client_step(delta: float) -> void:
	_dbg_t += delta
	if _dbg_t >= 1.0:
		if _dbg_snaps > 0:
			print("[puck] snaps/s=", _dbg_snaps, " rtt=", int(Net.rtt_ms), " jitter=", int(Net.jitter_ms))
		_dbg_snaps = 0
		_dbg_t = 0.0
	var paddle := _local_paddle()
	var q0 := Vector2.ZERO
	var pv := Vector2.ZERO
	if paddle != null:
		q0 = _prev_local if _has_prev else paddle.position
		pv = (paddle.position - q0) / delta
		_prev_local = paddle.position
		_has_prev = true
	else:
		_has_prev = false

	if not _frozen:
		var t0 := _target
		_vel *= maxf(0.0, 1.0 - friction * delta)
		_target += _vel * delta
		var r: Array = _walls(_target, _vel)
		_target = r[0]
		_vel = r[1]
		if paddle != null:
			_predict_own_hit(paddle, q0, pv, t0, delta)
			r = _walls(_target, _vel)
			_target = r[0]
			_vel = r[1]
	# Golpes previstos movem _target e a tela JUNTOS (sem atraso, o disco nunca
	# aparece "dentro" do taco). Só a correção do servidor é suavizada.
	_err *= exp(-client_smooth * delta)
	position = _target + _err
	
# Só visual: a física do cliente continua usando _target
func _push_out_of_paddles(p: Vector2) -> Vector2:
	for pad in players.get_children():
		var rr: float = radius + pad.radius
		var d: Vector2 = p - pad.position
		var dist := d.length()
		if dist < rr:
			p = pad.position + (d / dist if dist > 0.001 else Vector2.UP) * rr
	return p

func _predict_own_hit(p: Node2D, q0: Vector2, pv: Vector2, t0: Vector2, delta: float) -> void:
	var r: Array = _resolve_paddle(t0, _target, _vel, q0, p.position, pv, p.radius, delta, power_of(int(p.side)))
	_target = r[0]
	_vel = r[1]
	if r[2]:
		if float(r[3]) >= HIT_MIN_IMPACT:
			paddle_hit.emit(r[3], true)   # predição do meu golpe: som/vibração na hora, sem esperar a rede
		# até o servidor confirmar (1 ping + folga), não aceita estado antigo
		_hold_until = Time.get_ticks_msec() + int(clampf(Net.rtt_ms, 40.0, max_comp_ms) + 40.0)

func _local_paddle() -> Node2D:
	for p in players.get_children():
		if p.is_multiplayer_authority():
			return p
	return null

func _oneway_s() -> float:
	return clampf(Net.rtt_ms, 0.0, max_comp_ms) / 2000.0


# --- controle (chamado pelo Main, só no servidor) ---
## Enfraquece o taco de um lado por `seconds`: o golpe devolve só `power` (0..1) da energia ao disco.
## Chamado nos DOIS aparelhos (o servidor simula, o cliente prevê o próprio golpe).
func nerf(side: int, seconds: float, power: float) -> void:
	side = clampi(side, 0, 1)
	_nerf_until[side] = Time.get_ticks_msec() + int(seconds * 1000.0)
	_nerf_power[side] = clampf(power, 0.0, 1.0)

## Segundos que faltam de enfraquecimento (0 = normal).
func nerf_left(side: int) -> float:
	return maxf(0.0, float(int(_nerf_until[clampi(side, 0, 1)]) - Time.get_ticks_msec()) / 1000.0)

func power_of(side: int) -> float:
	return float(_nerf_power[clampi(side, 0, 1)]) if nerf_left(side) > 0.0 else 1.0

## to_side: lado que recebe o saque (0 = baixo, 1 = cima). -1 = sorteia. O X1 passa o lado de quem ganhou a posse.
func serve(to_side: int = -1) -> void:
	active = true
	_serve_to = randi() % 2 if to_side < 0 else clampi(to_side, 0, 1)
	_reset_center()

func stop() -> void:
	active = false
	_reset_center()
	_freeze = 0.0
	if not multiplayer.get_peers().is_empty():
		_net_sync.rpc(position, velocity, true)

func _reset_center() -> void:
	_last_touch = -1
	_bounces = 0
	position = FIELD / 2.0
	velocity = Vector2.ZERO
	_freeze = 1.5

func _launch() -> void:
	var dir_y := 1.0 if _serve_to == 0 else -1.0
	velocity = Vector2(randf_range(-0.4, 0.4), dir_y).normalized() * serve_speed
	_since_launch = 0.0

# --- física ---
func _update_paddle_velocities(delta: float) -> void:
	for p in players.get_children():
		var cur := _paddle_pos(p)
		var prev: Vector2 = _prev_pos.get(p.name, cur)
		_paddle_from[p.name] = prev
		var raw_v := (cur - prev) / delta
		if p.is_multiplayer_authority():
			_paddle_vel[p.name] = raw_v
		else:
			# a posição de rede chega em "degraus": suaviza só a velocidade
			var old: Vector2 = _paddle_vel.get(p.name, raw_v)
			_paddle_vel[p.name] = old.lerp(raw_v, 0.8)
		_prev_pos[p.name] = cur

# Posição usada na FÍSICA. Rebatedor remoto: a posição recebida da rede, não a
# desenhada (que é suavizada e fica ~40 ms atrás de onde o cliente realmente
# está; o cliente prevê o golpe na posição real e as duas versões divergiam).
func _paddle_pos(p: Node2D) -> Vector2:
	return p.position if p.is_multiplayer_authority() else p.sync_pos

func _wall_bounce() -> void:
	var r: Array = _walls(position, velocity)
	position = r[0]
	velocity = r[1]

# Mesma regra de paredes para servidor e cliente (predição)
func _walls(p: Vector2, v: Vector2) -> Array:
	if p.x < radius:
		p.x = radius
		_wall_impact(-v.x)
		v.x = absf(v.x) * wall_bounce
	elif p.x > FIELD.x - radius:
		p.x = FIELD.x - radius
		_wall_impact(v.x)
		v.x = -absf(v.x) * wall_bounce

	var in_goal := absf(p.x - FIELD.x / 2.0) < GOAL_W / 2.0
	if in_goal:
		return [p, v]  # abertura do gol: o disco passa
	if p.y < radius:
		p.y = radius
		_wall_impact(-v.y)
		v.y = absf(v.y) * wall_bounce
	elif p.y > FIELD.y - radius:
		p.y = FIELD.y - radius
		_wall_impact(v.y)
		v.y = -absf(v.y) * wall_bounce
	return [p, v]

# Só avisa quando o disco VAI contra a parede (valor positivo) e com força mínima.
# Servidor e cliente (predição) passam por aqui, então os dois aparelhos ouvem/sentem.
func _wall_impact(into_wall: float) -> void:
	if _mute_impacts:
		return
	if into_wall > WALL_MIN_IMPACT:
		if multiplayer.is_server():
			_bounces += 1   # para a conquista Ricochet (o cliente só prevê, quem conta é o servidor)
		wall_hit.emit(into_wall)

# Host: o taco do cliente chega com atraso de rede. Adianta-o um pouco (pela
# própria velocidade) para a colisão bater onde o cliente previu o golpe.
func _paddle_lead(p: Node2D) -> Vector2:
	if p.is_multiplayer_authority():
		return Vector2.ZERO
	var v: Vector2 = _paddle_vel.get(p.name, Vector2.ZERO)
	return v * minf(_oneway_s(), PADDLE_LEAD_MAX)

func _paddle_hits(step_start: Vector2, delta: float) -> void:
	for p in players.get_children():
		var lead := _paddle_lead(p)
		var q1 := _paddle_pos(p) + lead
		var q0: Vector2 = _paddle_from.get(p.name, _paddle_pos(p)) + lead
		var pv: Vector2 = _paddle_vel.get(p.name, Vector2.ZERO)
		var r: Array = _resolve_paddle(step_start, position, velocity, q0, q1, pv, p.radius, delta, power_of(int(p.side)))
		position = r[0]
		velocity = r[1]
		if r[2]:
			_last_touch = int(p.side)   # quem tocou por último (gol contra) e zera as batidas na parede
			_bounces = 0
		if r[2] and float(r[3]) >= HIT_MIN_IMPACT:
			# "meu" = taco de uma pessoa deste aparelho (o da CPU também tem autoridade no host, mas não vibra)
			paddle_hit.emit(r[3], p.is_multiplayer_authority() and not bool(p.get("ai")))

# Colisão CONTÍNUA disco x rebatedor (os dois se movem durante o passo).
# p0->p1: trajeto do disco; q0->q1: trajeto do rebatedor; pv: velocidade do rebatedor.
# Em vez de olhar só a posição final (o rebatedor "atravessava" o disco quando
# andava mais que o diâmetro num tick), acha o PRIMEIRO instante de contato.
# Retorna [posição final, velocidade final, bateu?, força da batida (px/s)]
func _resolve_paddle(p0: Vector2, p1: Vector2, vel: Vector2, q0: Vector2, q1: Vector2,
		pv: Vector2, pr: float, delta: float, power: float = 1.0) -> Array:
	var rr := radius + pr
	var hit := false
	var impact := 0.0
	var t := _sweep_circles(p0, p1, q0, q1, rr)
	if t >= 0.0:
		var cp := p0.lerp(p1, t)    # disco no instante do contato
		var cq := q0.lerp(q1, t)    # rebatedor no instante do contato
		var n := cp - cq
		if n.length() < 0.001:
			n = p1 - q1
		n = n.normalized() if n.length() > 0.001 else Vector2.UP
		var rel := vel - pv
		var rn := rel.dot(n)
		if rn < 0.0:
			var vel_in := vel                                # velocidade antes do golpe
			rel = rel - (1.0 + hit_restitution) * rn * n    # rebote só na componente normal
			vel = pv + rel + pv * (hit_boost - 1.0)         # + a velocidade do taco (com ganho)
			var out_n := vel.dot(n)
			if out_n < min_hit_speed:                       # toque leve ainda "dá vida" ao disco
				vel += n * (min_hit_speed - out_n)
			vel = vel.limit_length(max_speed)
			vel = vel_in + (vel - vel_in) * power            # taco enfraquecido: só parte do impulso passa ao disco
			hit = true
			impact = -rn
		# o resto do passo o disco já anda com a velocidade nova, a partir do contato
		p1 = cp + vel * delta * (1.0 - t)
	# garantia final: nunca terminar o passo dentro do rebatedor
	var d := p1 - q1
	var dist := d.length()
	if dist < rr:
		p1 = q1 + (d / dist if dist > 0.001 else Vector2.UP) * rr
	return [p1, vel, hit, impact]

# Primeiro instante t (0..1) em que dois círculos em movimento se tocam
# (a = disco, b = rebatedor; r = soma dos raios). -1 se não se tocam no passo.
func _sweep_circles(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2, r: float) -> float:
	var d0 := a0 - b0
	var dv := (a1 - a0) - (b1 - b0)   # deslocamento relativo no passo
	var c := d0.length_squared() - r * r
	if c <= 0.0:
		return 0.0                    # já começou sobreposto
	var a := dv.length_squared()
	if a < 0.000001:
		return -1.0
	var b := d0.dot(dv)
	if b >= 0.0:
		return -1.0                   # se afastando
	var disc := b * b - a * c
	if disc < 0.0:
		return -1.0
	var t := (-b - sqrt(disc)) / a
	return t if t <= 1.0 else -1.0

func _check_goal() -> void:
	if absf(position.x - FIELD.x / 2.0) >= GOAL_W / 2.0:
		return   # fora da abertura: nunca é gol
	var scorer := -1
	if position.y < 0.0:
		scorer = 0     # entrou no gol de cima
	elif position.y > FIELD.y:
		scorer = 1     # entrou no gol de baixo
	if scorer == -1:
		return
	var info := 0
	if _since_launch <= Achievements.FAST_GOAL_SECONDS:
		info |= Achievements.GOAL_FAST
	if velocity.length() >= Achievements.ROCKET_SPEED:
		info |= Achievements.GOAL_ROCKET
	if _last_touch == 1 - scorer:   # o último toque foi de quem sofreu o gol
		info |= Achievements.GOAL_OWN
	info |= mini(_bounces, Achievements.BOUNCE_CAP) << Achievements.GOAL_BOUNCE_SHIFT
	goal.emit(scorer, info)
	_serve_to = 1 - scorer  # quem sofreu o gol recebe o saque
	_reset_center()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color.DARK_SLATE_GRAY)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, Color(0, 0, 0, 0.5), 2.0)

func _make_trail() -> void:
	_trail = Line2D.new()
	_trail.show_behind_parent = true          # desenha atrás do disco
	_trail.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_trail.joint_mode = Line2D.LINE_JOINT_ROUND
	_trail.antialiased = true
	# afina na ponta: o 1º ponto (mais antigo) tem largura 0, o último (disco) tem 1
	var w := Curve.new()
	w.add_point(Vector2(0.0, 0.0))
	w.add_point(Vector2(1.0, 1.0))
	_trail.width_curve = w
	# some na ponta: transparente -> amarelo
	var g := Gradient.new()
	g.set_color(0, Color(TRAIL_COLOR, 0.0))
	g.set_color(1, Color(TRAIL_COLOR, 0.9))
	_trail.gradient = g
	add_child(_trail)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var gp := global_position
	# gol/saque/ajuste do servidor: o disco "teleportou", então recomeça o rastro
	if not _trail_pts.is_empty() and _trail_pts[-1].distance_to(gp) > TRAIL_JUMP:
		_trail_pts.clear()
		_trail_t.clear()
	if _trail_pts.is_empty() or _trail_pts[-1].distance_to(gp) > 1.0:
		_trail_pts.append(gp)
		_trail_t.append(now)
	# pontos velhos somem: com o disco parado, o rastro se apaga sozinho
	while not _trail_t.is_empty() and now - _trail_t[0] > TRAIL_TIME:
		_trail_pts.pop_front()
		_trail_t.pop_front()
	var pts := PackedVector2Array()
	for p in _trail_pts:
		pts.append(p - gp)          # o Line2D é filho do disco: pontos em coordenadas locais
	pts.append(Vector2.ZERO)        # a cabeça do rastro cola no centro do disco
	_trail.points = pts
	_trail.width = radius * 1.6
