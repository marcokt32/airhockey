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

# --- Rosto do taco (emoções) ---
const WIN_SCORE := 7            # igual ao do main.gd
const FACE_BASE_DISC := false   # true = desenha um disco liso sob o rosto (se a sprite atrapalhar)
const FACE_BASE_COLOR := Color("f2d6b3")
const HELMET := true            # capacete de hóquei sobre o rosto
const HELMET_MINE := Color("2f6fdb")    # azul: o meu taco
const HELMET_RIVAL := Color("d94a3d")   # vermelho: o rival
const HELMET_STRAP := false      # jugular (tira fina sob o queixo)
var _main: Node
var _puck_node: Node2D
var _face: Face
var _last_scores: Array = []
var _cheer := 0.0      # >0: acabou de marcar (comemora)
var _hurt := 0.0       # >0: acabou de tomar gol (flash vermelho + tranco)
var _anger := 0.0      # raiva atual suavizada (-0.3 alegre ... 1 furioso)
var _blink := 0.0
var _blink_in := 2.0
var _match_point := false
var _lead := 0         # minha pontuação - pontuação do rival
var _nerf_left := 0.0  # segundos de enfraquecimento (X1 perdido) que ainda faltam

func _enter_tree() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())

func _ready() -> void:
	_main = get_node_or_null("../..")
	_puck_node = get_node_or_null("../../Puck")
	_face = Face.new()
	_face.p = self
	add_child(_face)   # por último = desenhado por cima da sprite
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

# ------------------------------------------------------------ rosto / emoções

# O humor sai só do placar que o main.gd já sincroniza: nenhuma RPC nova.
func _process(delta: float) -> void:
	_nerf_left = _puck_node.nerf_left(side) if _puck_node != null and _puck_node.has_method("nerf_left") else 0.0
	var sc: Variant = _main.get("scores") if _main != null else null
	if sc is Array and sc.size() == 2:
		var mine: int = sc[side]
		var rival: int = sc[1 - side]
		if _last_scores.size() == 2:
			if mine > _last_scores[side]:
				_cheer = 1.0
			if rival > _last_scores[1 - side]:
				_hurt = 1.0
			if mine == 0 and rival == 0:   # partida nova
				_cheer = 0.0
				_hurt = 0.0
		_last_scores = [sc[0], sc[1]]
		_lead = mine - rival
		_match_point = rival >= WIN_SCORE - 1 and _lead >= 1
	var target := 0.0
	if _lead < 0:
		target = clampf(-_lead / 3.0 + 0.2, 0.0, 1.0)   # perdendo por 1 = 0.53, por 2 = 0.87, por 3+ = 1
	elif _lead >= 2:
		target = -0.15                                 # folgado: sobrancelha tranquila/sorriso
	if _cheer > 0.0:
		target = -0.3
	_anger = lerpf(_anger, target, 1.0 - exp(-6.0 * delta))
	_cheer = maxf(0.0, _cheer - delta / 1.2)
	_hurt = maxf(0.0, _hurt - delta / 0.6)
	# piscar
	_blink_in -= delta
	if _blink_in <= 0.0:
		_blink = 0.12
		_blink_in = randf_range(1.5, 4.0)
	_blink = maxf(0.0, _blink - delta)
	_face.queue_redraw()

# Desenha o rosto numa camada própria, por cima da sprite. Contra-gira a câmera,
# para o rosto ficar sempre de pé na tela (o jogador de cima vê o mundo girado).
class Face extends Node2D:
	var p   # o taco dono deste rosto

	func _draw() -> void:
		if p == null:
			return
		var r: float = p.radius
		var cam := get_viewport().get_camera_2d()
		var rot := cam.rotation if cam != null else 0.0
		var t := Time.get_ticks_msec() / 1000.0
		# tremor: forte ao tomar gol, leve em match point contra
		var shake: float = p._hurt * 4.0 + (1.2 if p._match_point else 0.0)
		var off := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake
		draw_set_transform(off, -rot, Vector2.ONE)

		if p.FACE_BASE_DISC:
			draw_circle(Vector2.ZERO, r, p.FACE_BASE_COLOR)
			draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(0, 0, 0, 0.6), 2.0, true)

		if p.HELMET:
			_draw_helmet(r, p.is_rival)

		var a: float = p._anger
		var ang := maxf(a, 0.0)

		# para onde os olhos olham (rumo ao disco, no espaço da tela)
		var look := Vector2.ZERO
		if p._puck_node != null:
			var d: Vector2 = (p._puck_node.position - p.position).rotated(rot)
			look = d.normalized() * minf(d.length() / 200.0, 1.0)

		# olhos
		var eye_r := r * (0.22 - 0.04 * ang)
		var eye_col := Color.WHITE.lerp(Color("ff6b5e"), ang * ang)   # raiva forte = olho injetado
		for s in [-1.0, 1.0]:
			var c := Vector2(s * r * 0.34, -r * 0.1)
			if p._blink > 0.0:
				draw_line(c + Vector2(-eye_r, 0), c + Vector2(eye_r, 0), Color.BLACK, r * 0.07, true)
				continue
			draw_circle(c, eye_r, eye_col)
			draw_arc(c, eye_r, 0.0, TAU, 20, Color.BLACK, r * 0.05, true)
			draw_circle(c + look * eye_r * 0.45, eye_r * 0.5, Color.BLACK)

		# sobrancelhas: raiva = pontas internas descem. Folgado = uma levantada.
		var bw := r * (0.08 + 0.05 * ang)
		for s in [-1.0, 1.0]:
			var outer_y := -r * 0.42 - r * 0.06 * ang
			var inner_y := -r * 0.40 + r * 0.30 * a
			if a < 0.0 and s > 0.0:
				outer_y -= r * 0.10   # sobrancelha levantada de quem está ganhando
			var o := Vector2(s * r * 0.64, outer_y)
			var i := Vector2(s * r * 0.08, inner_y)
			draw_line(o, i, Color.BLACK, bw, true)

		if p.HELMET:
			_draw_visor(r)

		# boca
		var my := r * 0.50
		if p._cheer > 0.0:
			# gritando de alegria: boca aberta
			var pts := PackedVector2Array()
			for k in 13:
				var th := PI * float(k) / 12.0
				pts.append(Vector2(cos(th) * r * 0.3, my - r * 0.12 + sin(th) * r * 0.26))
			draw_colored_polygon(pts, Color("7a1020"))
			draw_polyline(pts, Color.BLACK, r * 0.05, true)
			draw_rect(Rect2(-r * 0.26, my - r * 0.14, r * 0.52, r * 0.07), Color.WHITE)
		elif a >= 0.75:
			# dentes cerrados
			var rect := Rect2(-r * 0.38, my - r * 0.16, r * 0.76, r * 0.3)
			draw_rect(rect, Color.WHITE)
			for k in [-1, 0, 1]:
				draw_line(Vector2(k * r * 0.19, rect.position.y), Vector2(k * r * 0.19, rect.end.y), Color.BLACK, r * 0.035)
			draw_line(Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5), Vector2(rect.end.x, rect.position.y + rect.size.y * 0.5), Color.BLACK, r * 0.035)
			draw_rect(rect, Color.BLACK, false, r * 0.06)
		elif a >= 0.25:
			# boca apertada, caída
			var pts := PackedVector2Array()
			for k in 9:
				var x := lerpf(-0.3, 0.3, float(k) / 8.0)
				pts.append(Vector2(x * r, my + (1.0 - x * x / 0.09) * -r * 0.07 * 1.0))
			draw_polyline(pts, Color.BLACK, r * 0.08, true)
		elif a < -0.05:
			# sorrisinho de lado
			var pts := PackedVector2Array()
			for k in 9:
				var u := float(k) / 8.0
				var x := lerpf(-0.3, 0.3, u)
				pts.append(Vector2(x * r, my - r * 0.04 + (1.0 - x * x / 0.09) * r * 0.12 - u * r * 0.07))
			draw_polyline(pts, Color.BLACK, r * 0.07, true)
		else:
			draw_line(Vector2(-r * 0.24, my), Vector2(r * 0.24, my), Color.BLACK, r * 0.08, true)

		# vapor saindo das "orelhas" em match point contra
		if p._match_point:
			for s in [-1.0, 1.0]:
				for k in 2:
					var ph := fmod(t * 1.4 + k * 0.5 + (0.25 if s > 0.0 else 0.0), 1.0)
					var pos := Vector2(s * r * (0.85 + 0.15 * ph), -r * 0.45 - ph * r * 0.9)
					draw_circle(pos, r * (0.10 + 0.14 * ph), Color(1, 1, 1, 0.75 * (1.0 - ph)))

		# enfraquecido (perdeu o X1): tom gelado e estrelinhas girando sobre a cabeça
		if p._nerf_left > 0.0:
			draw_circle(Vector2.ZERO, r, Color(0.35, 0.65, 1.0, 0.30))
			for k in 3:
				var sa: float = t * 4.0 + TAU * float(k) / 3.0
				var sc := Vector2(cos(sa) * r * 0.75, -r * 1.12 + sin(sa) * r * 0.2)
				var sp := PackedVector2Array()
				for q in 10:
					var qa := -PI / 2.0 + float(q) * PI / 5.0
					var qr := r * 0.17 if q % 2 == 0 else r * 0.07
					sp.append(sc + Vector2(cos(qa), sin(qa)) * qr)
				draw_colored_polygon(sp, Color("ffe066"))

		# flash vermelho ao tomar gol
		if p._hurt > 0.0:
			draw_circle(Vector2.ZERO, r, Color(1.0, 0.1, 0.05, 0.45 * p._hurt))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Capacete grande: casca que contorna o topo e as laterais do rosto, com uma "janela" aberta
	# onde ficam olhos, sobrancelhas e boca (nada de expressão fica coberto). Azul = meu, vermelho = rival.
	func _draw_helmet(r: float, rival: bool) -> void:
		var base: Color = p.HELMET_RIVAL if rival else p.HELMET_MINE
		var line_w := r * 0.05
		var big := r * 1.1        # raio externo da casca (passa um pouco do taco)
		var cy := -r * 0.02
		var win := r * 0.74       # meia-largura da janela do rosto
		var low := r * 0.30       # até onde a casca desce nas laterais (altura da orelha)
		var brim_y := -r * 0.60   # aba: borda de cima da janela
		# casca: arco externo (esquerda -> topo -> direita) e depois a janela voltando
		var poly := PackedVector2Array()
		var n := 32
		var a0 := PI - 0.30
		var a1 := TAU + 0.30
		for k in n + 1:
			var a := lerpf(a0, a1, float(k) / float(n))
			poly.append(Vector2(cos(a) * big, cy + sin(a) * big))
		poly.append(Vector2(win, low))
		for k in 9:
			var x := lerpf(win, -win, float(k) / 8.0)
			poly.append(Vector2(x, brim_y + 0.10 * x * x / r))
		poly.append(Vector2(-win, low))
		draw_colored_polygon(poly, base)
		# respiros no topo (riscos escuros curvos, como no capacete de referência)
		var vent: Color = base.darkened(0.5)
		for s in [-1.0, 1.0]:
			for j in 2:
				var x0: float = s * r * (0.22 + 0.20 * j)
				var y0: float = -r * (1.0 - 0.10 * j)
				var vp := PackedVector2Array()
				for k in 6:
					var t := float(k) / 5.0
					vp.append(Vector2(x0 + s * r * 0.20 * t, y0 + r * 0.14 * t * t))
				draw_polyline(vp, vent, r * 0.05, true)
		# brilho
		draw_arc(Vector2.ZERO, r * 0.95, PI * 1.30, PI * 1.42, 8, Color(1, 1, 1, 0.5), r * 0.06, true)
		# contorno
		var outline := PackedVector2Array(poly)
		outline.append(poly[0])
		draw_polyline(outline, Color.BLACK, line_w, true)
		# jugular: curva fina de um lado ao outro, por baixo da boca
		if p.HELMET_STRAP:
			var strap := PackedVector2Array()
			var c0 := Vector2(-win, low)
			var c1 := Vector2(0.0, r * 1.5)
			var c2 := Vector2(win, low)
			for k in 13:
				var t := float(k) / 12.0
				strap.append(c0.lerp(c1, t).lerp(c1.lerp(c2, t), t))
			draw_polyline(strap, base.darkened(0.45), r * 0.06, true)

	# Viseira translúcida sobre os olhos (olhos e sobrancelhas continuam visíveis através dela).
	func _draw_visor(r: float) -> void:
		var half_w := r * 0.80
		var top := -r * 0.60
		var bot := r * 0.14
		var cr := r * 0.22
		var centers := [
			Vector2(half_w - cr, top + cr), Vector2(half_w - cr, bot - cr),
			Vector2(-half_w + cr, bot - cr), Vector2(-half_w + cr, top + cr)]
		var starts := [-PI / 2.0, 0.0, PI / 2.0, PI]
		var pts := PackedVector2Array()
		for q in 4:
			var c: Vector2 = centers[q]
			for k in 5:
				var a: float = float(starts[q]) + (PI / 2.0) * float(k) / 4.0
				pts.append(c + Vector2(cos(a), sin(a)) * cr)
		draw_colored_polygon(pts, Color(0.80, 0.92, 1.0, 0.30))
		# reflexo curto na ponta esquerda (longe dos olhos)
		draw_line(Vector2(-r * 0.70, 0.0), Vector2(-r * 0.62, -r * 0.42), Color(1, 1, 1, 0.55), r * 0.07, true)
		# moldura: contorno preto + aro claro
		var closed := PackedVector2Array(pts)
		closed.append(pts[0])
		draw_polyline(closed, Color.BLACK, r * 0.12, true)
		draw_polyline(closed, Color(0.88, 0.95, 1.0), r * 0.06, true)
