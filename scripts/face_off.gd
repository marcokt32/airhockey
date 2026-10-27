class_name FaceOff
extends CanvasLayer
## X1: a disputa de poder que decide quem fica com o disco no começo da partida.
##
## Fluxo (igual nos dois aparelhos):
##   1) painel "X1" com tacos cruzados e fogo  ->  2) os avatares entram colados, um empurrando o outro
##   3) disputa: toque o mais rápido que puder (qualquer lugar da tela). A barra enche para o lado de quem
##      está ganhando. Encheu = venceu, ou vence quem estiver na frente quando o tempo acabar.
##   4) o vencedor fica com a posse: o disco sai para o lado dele.
##
## Rede: o HOST manda. O cliente envia só o total de toques (acumulado, tolera perda de pacote) e recebe a
## barra de volta. Todas as RPCs ficam AQUI, não no main.gd: a lista de RPCs do main não muda.
## Contra a CPU tudo roda local (um "bot" toca no ritmo da dificuldade).
##
## Uso no main.gd: criar com FaceOff.new() (name = "FaceOff", mesmo nome nos dois aparelhos), chamar start()
## só no host/CPU e ouvir `finished`. Veja as instruções que acompanham este arquivo.

signal finished(winner_side: int, caller_side: int)   # em todos os aparelhos. caller_side = quem chamou o X1 (-1 = X1 de início de partida)
signal state_changed               # começou ou terminou (o main atualiza o bloqueio de toques)

const BANNER_S := 1.8              # tempo do painel "X1"
const SLIDE_S := 0.8               # entrada dos avatares
const FIGHT_MAX_S := 7.0           # duração máxima da disputa
const RESULT_S := 1.6              # tempo mostrando quem ficou com o disco
const STEP := 0.045                # quanto a barra anda por toque (1.0 = encheu)
const MAX_TPS := 14.0              # limite de toques/s aceito do cliente (anti-trapaça)
const SEND_S := 0.06               # de quanto em quanto tempo o cliente envia seus toques
const BAR_SEND_S := 0.05           # de quanto em quanto tempo o host envia a barra
const PUSH_RANGE := 60.0           # quanto o ponto de contato dos avatares anda (px)
const CPU_TPS := [3.0, 5.0, 7.5]   # toques por segundo da CPU (fácil, normal, difícil)
const MINE_COLOR := Color("2f6fdb")
const RIVAL_COLOR := Color("d94a3d")
const BANNER_SIZE := Vector2(300, 230)

enum Phase { IDLE, BANNER, SLIDE, FIGHT, RESULT }

var phase: Phase = Phase.IDLE

var _main: Node
var _is_host := false
var _cpu := false
var _mobile := false

var _t := 0.0
var _fight_t := 0.0
var _time_left := FIGHT_MAX_S
var _host_pos := 0.0       # só no host: positivo = o host está ganhando (-1..1)
var _target := 0.0         # visão DESTE aparelho: positivo = EU estou ganhando
var _display := 0.0        # _target suavizado (o que a barra mostra)
var _energy := 0.0         # sobe a cada toque e decai: treme e "estufa" os avatares
var _riv_phase := 0.0      # ciclo do soco do rival (0..1): estica rápido, volta devagar
var _slide := 0.0          # 0 = avatares fora da tela, 1 = no lugar
var _result_k := 0.0       # 0..1 na animação do resultado
var _my_taps := 0
var _sent_taps := 0
var _client_taps := 0      # host: total de toques do cliente já aplicado
var _send_clock := 0.0
var _bar_clock := 0.0
var _cpu_acc := 0.0
var _decided := false
var _i_won := false
var _winner_side := 0
var _caller := -1          # lado que apertou o botão X1 (-1 = disputa do começo da partida)
var _tweens: Array[Tween] = []

var _root: Control
var _banner: Control
var _fires: Array[CPUParticles2D] = []
var _av_me: UIStyle.Avatar
var _av_riv: UIStyle.Avatar
var _arm_me: FistArm
var _arm_riv: FistArm
var _lbl_me_name: Label
var _lbl_riv_name: Label
var _bar: PushBar
var _lbl_bar_me: Label
var _lbl_bar_riv: Label
var _lbl_time: Label
var _btn: Button
var _lbl_hint: Label
var _lbl_result: Label
var _lbl_caller: Label
var _sparks: CPUParticles2D


func _ready() -> void:
	layer = 5   # acima do cabeçalho e dos menus (layer 1), abaixo do pop-up de avaliação (20)
	_main = get_parent()
	_mobile = OS.has_feature("mobile")
	_build()
	_root.visible = false
	_root.resized.connect(_layout)


# ---------------------------------------------------------------- API

func is_active() -> bool:
	return phase != Phase.IDLE

## Só no host / contra a CPU. Começa o X1 do início da partida (decide a posse do primeiro saque).
func start() -> void:
	_launch(-1)

## Só no host / contra a CPU: o jogador do lado `side` apertou o botão X1 (barra de raiva cheia).
## Para o disco no centro e começa a disputa nos dois aparelhos.
func call_x1(side: int) -> void:
	if phase != Phase.IDLE or not multiplayer.is_server():
		return
	if not bool(_main.call("can_call_x1", side)):
		return
	var pk: Node = _main.get("puck")
	pk.call("stop")   # disco parado no centro enquanto a disputa rola
	_launch(side)

## Botão X1 do jogador deste aparelho (host chama direto; cliente pede ao host).
func request_x1() -> void:
	if phase != Phase.IDLE:
		return
	if multiplayer.is_server():
		call_x1(int(_main.get("my_side")))
	else:
		_rpc_request_x1.rpc_id(1)

func _launch(caller: int) -> void:
	if phase != Phase.IDLE:
		return
	if Net.vs_cpu:
		_begin(caller)
	else:
		_rpc_begin.rpc(caller)

## Aborta sem declarar vencedor (rival saiu, partida terminou por rede...).
func cancel() -> void:
	if phase == Phase.IDLE and not _root.visible:
		return
	_kill_tweens()
	phase = Phase.IDLE
	_root.visible = false
	state_changed.emit()


# ---------------------------------------------------------------- rede

@rpc("authority", "call_local", "reliable")
func _rpc_begin(caller: int) -> void:
	_begin(caller)

# cliente -> host: "apertei o X1". Só existem 2 jogadores: quem pediu é o lado oposto ao do host.
@rpc("any_peer", "reliable")
func _rpc_request_x1() -> void:
	if multiplayer.is_server():
		call_x1(1 - int(_main.get("my_side")))

# cliente -> host: total ACUMULADO de toques (se um pacote se perder, o próximo cobre)
@rpc("any_peer", "unreliable_ordered")
func _rpc_taps(total: int) -> void:
	if not multiplayer.is_server() or phase != Phase.FIGHT:
		return
	total = mini(total, int(_fight_t * MAX_TPS) + 3)   # ninguém passa do limite humano
	var d := total - _client_taps
	if d > 0:
		_client_taps = total
		_apply_taps(false, d)

# host -> cliente: onde está a barra (na visão do host) e quanto tempo falta
@rpc("authority", "unreliable_ordered")
func _rpc_bar(host_pos: float, left: float) -> void:
	_target = -host_pos   # para o cliente, o que é bom para o host é ruim para ele
	_time_left = left

@rpc("authority", "call_local", "reliable")
func _rpc_finish(winner_side: int) -> void:
	_finish(winner_side)


# ---------------------------------------------------------------- fluxo

func _begin(caller: int) -> void:
	_kill_tweens()
	_caller = caller
	_is_host = multiplayer.is_server()
	_cpu = Net.vs_cpu
	phase = Phase.BANNER
	_t = 0.0
	_fight_t = 0.0
	_time_left = FIGHT_MAX_S
	_host_pos = 0.0
	_target = 0.0
	_display = 0.0
	_energy = 0.0
	_riv_phase = 0.0
	_slide = 0.0
	_result_k = 0.0
	_my_taps = 0
	_sent_taps = 0
	_client_taps = 0
	_send_clock = 0.0
	_bar_clock = 0.0
	_cpu_acc = 0.0
	_decided = false
	_root.theme = UIStyle.make_theme()   # fonte do jogo (já definida pelo menu a esta altura)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.modulate.a = 1.0
	_root.visible = true
	_layout()
	_set_play_ui(false)
	_lbl_result.visible = false
	_lbl_caller.visible = caller >= 0
	if caller >= 0:
		var who := "VOCÊ" if caller == int(_main.get("my_side")) else str(_main.get("rival_name")).to_upper()
		_lbl_caller.text = "%s CHAMOU O X1!" % who
	_banner.visible = true
	_banner.modulate.a = 1.0
	_banner.scale = Vector2(0.2, 0.2)
	for f in _fires:
		f.restart()
	var tw := _new_tween()
	tw.tween_property(_banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	GameAudio.vibrate(70, 0.6)
	state_changed.emit()

func _process(delta: float) -> void:
	if phase == Phase.IDLE:
		return
	_t += delta
	match phase:
		Phase.BANNER:
			if _t >= BANNER_S:
				_enter_slide()
		Phase.SLIDE:
			if _t >= SLIDE_S:
				_enter_fight()
		Phase.FIGHT:
			_fight_step(delta)
		Phase.RESULT:
			if _t >= RESULT_S:
				_close()
	_update_visuals(delta)

func _enter_slide() -> void:
	phase = Phase.SLIDE
	_t = 0.0
	_lbl_caller.visible = false
	_set_play_ui(true)
	_btn.text = "PREPARE-SE..."
	_lbl_hint.text = "Toque várias vezes, bem rápido!"
	var tb := _new_tween()
	tb.set_parallel(true)
	tb.tween_property(_banner, "scale", Vector2(1.4, 1.4), 0.25)
	tb.tween_property(_banner, "modulate:a", 0.0, 0.25)
	tb.chain().tween_callback(func(): _banner.visible = false)
	_slide = 0.0
	var ts := _new_tween()
	ts.tween_property(self, "_slide", 1.0, SLIDE_S).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _enter_fight() -> void:
	phase = Phase.FIGHT
	_t = 0.0
	_fight_t = 0.0
	_host_pos = 0.0
	_client_taps = 0
	_decided = false
	_btn.text = "APERTE!"
	GameAudio.punch(0.9)   # os dois se chocam
	GameAudio.vibrate(50, 0.6)

func _fight_step(delta: float) -> void:
	_fight_t += delta
	if _is_host:
		_time_left = maxf(FIGHT_MAX_S - _fight_t, 0.0)
		if _cpu:
			_cpu_step(delta)
		else:
			_bar_clock += delta
			if _bar_clock >= BAR_SEND_S:
				_bar_clock = 0.0
				_rpc_bar.rpc(_host_pos, _time_left)
		_target = _host_pos
		if absf(_host_pos) >= 1.0 or _fight_t >= FIGHT_MAX_S:
			_decide()
	else:
		_send_clock += delta
		if _send_clock >= SEND_S and _my_taps != _sent_taps:
			_send_clock = 0.0
			_sent_taps = _my_taps
			_rpc_taps.rpc_id(1, _my_taps)
		if _fight_t > FIGHT_MAX_S + 6.0:   # o host sumiu? não prende o jogador aqui
			cancel()

func _cpu_step(delta: float) -> void:
	var tps: float = CPU_TPS[clampi(Net.cpu_level, 0, 2)]
	_cpu_acc += delta * tps * randf_range(0.6, 1.4)
	while _cpu_acc >= 1.0:
		_cpu_acc -= 1.0
		_apply_taps(false, 1)

# Só no host: aplica toques na barra (host_side = o toque foi do host/jogador local da CPU)
func _apply_taps(host_side: bool, n: int) -> void:
	var dir := 1.0 if host_side else -1.0
	_host_pos = clampf(_host_pos + dir * STEP * float(n), -1.0, 1.0)

func _decide() -> void:
	if _decided:
		return
	_decided = true
	var host_wins := randf() < 0.5 if absf(_host_pos) < 0.001 else _host_pos > 0.0
	var host_side := int(_main.get("my_side"))
	var winner := host_side if host_wins else 1 - host_side
	if _cpu:
		_finish(winner)
	else:
		_rpc_finish.rpc(winner)

func _finish(winner_side: int) -> void:
	if phase == Phase.IDLE or phase == Phase.RESULT:
		return
	phase = Phase.RESULT
	_t = 0.0
	_banner.visible = false   # (se este aparelho ainda estava no painel: pula direto para o resultado)
	_set_play_ui(true)
	_slide = 1.0
	_winner_side = winner_side
	_i_won = winner_side == int(_main.get("my_side"))
	_target = 1.0 if _i_won else -1.0
	var rival := str(_main.get("rival_name"))
	if _caller >= 0:   # X1 no meio do jogo: o perdedor fica enfraquecido
		_lbl_result.text = "VOCÊ VENCEU O X1!\nRIVAL ENFRAQUECIDO!" if _i_won else "%s VENCEU O X1!\nVOCÊ FOI ENFRAQUECIDO!" % rival.to_upper()
	else:
		_lbl_result.text = "VOCÊ FICOU\nCOM O DISCO!" if _i_won else "%s FICOU\nCOM O DISCO!" % rival.to_upper()
	_lbl_result.add_theme_color_override("font_color", Color("5be37d") if _i_won else Color("ff6a5e"))
	_lbl_result.visible = true
	_lbl_result.scale = Vector2(0.4, 0.4)
	_btn.text = "VENCEU!" if _i_won else "PERDEU"
	_lbl_time.text = ""
	_result_k = 0.0
	var tr := _new_tween()
	tr.set_parallel(true)
	tr.tween_property(self, "_result_k", 1.0, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tr.tween_property(_lbl_result, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	GameAudio.punch(1.0)   # a pancada que decide
	get_tree().create_timer(0.14).timeout.connect(func(): GameAudio.punch(0.8))
	if _i_won:
		GameAudio.goal()   # torcida + vibração forte
	else:
		GameAudio.vibrate(90, 0.4)

func _close() -> void:
	phase = Phase.IDLE
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE   # libera os toques já; o fade é só visual
	var tw := _new_tween()
	tw.tween_property(_root, "modulate:a", 0.0, 0.25)
	tw.tween_callback(func(): _root.visible = false)
	state_changed.emit()
	finished.emit(_winner_side, _caller)


# ---------------------------------------------------------------- toques

func _input(event: InputEvent) -> void:
	if phase != Phase.FIGHT:
		return
	var hit := false
	if event is InputEventScreenTouch:
		hit = event.pressed          # vários dedos valem: dá para alternar os polegares
	elif event is InputEventMouseButton:
		# no celular o toque também vira "mouse" (emulado): não contar duas vezes
		hit = event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not _mobile
	elif event is InputEventKey:
		hit = event.pressed and not event.echo and (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER)
	if hit:
		_tap()
		get_viewport().set_input_as_handled()

func _tap() -> void:
	_my_taps += 1
	_energy = 1.0
	_btn.scale = Vector2(0.9, 0.9)
	GameAudio.punch(randf_range(0.5, 1.0), true)   # soco sorteado + vibração curtinha a cada toque
	if _is_host:
		_apply_taps(true, 1)


# ---------------------------------------------------------------- visual

# Curva do soco (p = 0..1): estica em 18% do ciclo, recolhe até 55%, descansa o resto
func _jab(p: float) -> float:
	if p < 0.18:
		return p / 0.18
	if p < 0.55:
		return 1.0 - (p - 0.18) / 0.37
	return 0.0

func _av_size() -> float:
	return minf(_root.size.x * 0.36, 132.0)

func _set_play_ui(on: bool) -> void:
	for n in [_av_me, _av_riv, _arm_me, _arm_riv, _lbl_me_name, _lbl_riv_name, _bar, _lbl_bar_me, _lbl_bar_riv, _lbl_time, _btn, _lbl_hint]:
		n.visible = on
	_sparks.emitting = false

# Posições que só mudam com o tamanho da tela
func _layout() -> void:
	var vp := _root.size
	var cx := vp.x * 0.5
	var cy := vp.y * 0.36
	var av := _av_size()
	_banner.position = Vector2(cx - BANNER_SIZE.x * 0.5, vp.y * 0.5 - BANNER_SIZE.y * 0.5)
	_banner.pivot_offset = BANNER_SIZE * 0.5
	for a in [_av_me, _av_riv, _arm_me, _arm_riv]:
		a.size = Vector2(av, av)
		a.pivot_offset = a.size * 0.5
	var bar_w := minf(vp.x - 40.0, 320.0)
	var bar_y := cy + av * 0.5 + 84.0
	_bar.size = Vector2(bar_w, 30.0)
	_bar.position = Vector2(cx - bar_w * 0.5, bar_y)
	_lbl_bar_me.size = Vector2(bar_w * 0.4, 24.0)
	_lbl_bar_me.position = Vector2(cx - bar_w * 0.5, bar_y - 28.0)
	_lbl_bar_riv.size = Vector2(bar_w * 0.4, 24.0)
	_lbl_bar_riv.position = Vector2(cx + bar_w * 0.5 - bar_w * 0.4, bar_y - 28.0)
	_lbl_time.size = Vector2(80.0, 24.0)
	_lbl_time.position = Vector2(cx - 40.0, bar_y - 28.0)
	_btn.size = Vector2(bar_w, 120.0)
	_btn.position = Vector2(cx - bar_w * 0.5, bar_y + 44.0)
	_btn.pivot_offset = _btn.size * 0.5
	_lbl_hint.size = Vector2(vp.x, 24.0)
	_lbl_hint.position = Vector2(0.0, _btn.position.y + 128.0)
	_lbl_result.size = Vector2(vp.x, 90.0)
	_lbl_result.pivot_offset = _lbl_result.size * 0.5
	_lbl_caller.size = Vector2(vp.x, 30.0)
	_lbl_caller.position = Vector2(0.0, _banner.position.y + BANNER_SIZE.y + 14.0)
	_lbl_result.position = Vector2(0.0, cy - av * 0.5 - 100.0)

func _update_visuals(delta: float) -> void:
	var vp := _root.size
	var cx := vp.x * 0.5
	var cy := vp.y * 0.36
	var av := _av_size()
	_energy = maxf(0.0, _energy - delta * 7.0)
	_display = lerpf(_display, _target, 1.0 - exp(-14.0 * delta))
	# foto e nome do rival podem chegar depois do começo do X1
	if _av_me.texture != UIStyle.my_avatar:
		_av_me.texture = UIStyle.my_avatar
	if _av_riv.texture != UIStyle.rival_avatar:
		_av_riv.texture = UIStyle.rival_avatar
	_lbl_me_name.text = Net.player_name if Net.player_name != "" else "Você"
	_lbl_riv_name.text = str(_main.get("rival_name"))
	if phase == Phase.BANNER:
		return

	# soco do rival: estica rápido e volta devagar; mais rápido quando ele está ganhando
	var mpunch := _energy
	var rpunch := 0.0
	if phase == Phase.FIGHT:
		var prev := _riv_phase
		_riv_phase = fposmod(_riv_phase + delta * (4.5 + 4.0 * clampf(-_display, 0.0, 1.0)), 1.0)
		if prev < 0.18 and _riv_phase >= 0.18:
			GameAudio.punch(0.55)   # o soco dele "acerta": som
		rpunch = _jab(_riv_phase)

	# o vencedor empurra: o ponto de contato anda para o lado de quem perde
	var contact := cx + _display * PUSH_RANGE
	var off := (1.0 - _slide) * vp.x * 0.7
	var amp := _energy * 3.0 + (1.2 if phase == Phase.FIGHT else 0.0)
	var me_c := Vector2(contact - av * 0.46 - off, cy) + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amp
	var rv_c := Vector2(contact + av * 0.46 + off, cy) + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amp
	# quem soca avança e empurra o outro um pouquinho
	me_c.x += 10.0 * mpunch - 4.0 * rpunch
	rv_c.x += 4.0 * mpunch - 10.0 * rpunch
	var me_scale := 1.0 + 0.10 * _energy
	var rv_scale := 1.0
	if _result_k > 0.0:   # resultado: o perdedor é arremessado, o vencedor cresce
		var fling := _result_k * vp.x * 0.6
		if _i_won:
			rv_c.x += fling
			rv_scale = 1.0 - 0.3 * _result_k
			me_scale = 1.0 + 0.25 * _result_k
		else:
			me_c.x -= fling
			me_scale = 1.0 - 0.3 * _result_k
			rv_scale = 1.0 + 0.25 * _result_k
	_av_me.position = me_c - _av_me.size * 0.5
	_av_me.rotation = 0.14 + 0.12 * _display          # inclina para o rival; mais ainda se está ganhando
	_av_me.scale = Vector2(me_scale, me_scale)
	_av_riv.position = rv_c - _av_riv.size * 0.5
	_av_riv.rotation = -(0.14 - 0.12 * _display)
	_av_riv.scale = Vector2(rv_scale, rv_scale)
	for pair in [[_arm_me, _av_me], [_arm_riv, _av_riv]]:
		var arm: Control = pair[0]
		var av_node: Control = pair[1]
		arm.position = av_node.position
		arm.rotation = av_node.rotation
		arm.scale = av_node.scale
	_arm_me.punch = mpunch   # meu soco sai a cada toque
	_arm_riv.punch = rpunch
	_arm_me.queue_redraw()
	_arm_riv.queue_redraw()
	_lbl_me_name.size = Vector2(120.0, 22.0)
	_lbl_me_name.position = Vector2(me_c.x - 60.0, cy + av * 0.5 + av * 0.30)
	_lbl_riv_name.size = Vector2(120.0, 22.0)
	_lbl_riv_name.position = Vector2(rv_c.x - 60.0, cy + av * 0.5 + av * 0.30)

	# faíscas no ponto de contato
	_sparks.position = Vector2(contact, cy)
	_sparks.speed_scale = 0.8 + 1.6 * _energy
	var show_sparks := _slide > 0.9 and (phase == Phase.SLIDE or phase == Phase.FIGHT)
	if _sparks.emitting != show_sparks:
		_sparks.emitting = show_sparks

	_bar.value = _display
	_bar.queue_redraw()
	_lbl_time.text = "%.1f" % maxf(_time_left, 0.0) if phase == Phase.FIGHT else ""
	# botão: pulsa no ritmo e "afunda" a cada toque
	var pulse := 1.0 + 0.04 * sin(Time.get_ticks_msec() / 1000.0 * 9.0) if phase == Phase.FIGHT else 1.0
	_btn.scale = _btn.scale.lerp(Vector2(pulse, pulse), 1.0 - exp(-18.0 * delta))
	_btn.modulate.a = 1.0 if phase != Phase.SLIDE else 0.6


# ---------------------------------------------------------------- construção da interface

func _new_tween() -> Tween:
	var t := create_tween()
	_tweens.append(t)
	return t

func _kill_tweens() -> void:
	for t in _tweens:
		if t != null and t.is_valid():
			t.kill()
	_tweens.clear()

func _label(text: String, size_px: int, col: Color, align: int = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align as HorizontalAlignment
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_stylebox_override("normal", StyleBoxEmpty.new())   # sem a caixa clara dos outros labels
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", maxi(3, size_px / 6))
	return l

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.05, 0.84)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# --- painel "X1": moldura, tacos cruzados, fogo e o texto ---
	_banner = Control.new()
	_banner.size = BANNER_SIZE
	_banner.custom_minimum_size = BANNER_SIZE
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_banner)

	var panel := Panel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("0a0f2e")
	sb.border_color = UIStyle.ACCENT
	sb.set_border_width_all(5)
	sb.set_corner_radius_all(26)
	sb.shadow_color = Color(1.0, 0.4, 0.0, 0.55)
	sb.shadow_size = 20
	panel.add_theme_stylebox_override("panel", sb)
	_banner.add_child(panel)

	var sticks := StickArt.new()
	sticks.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.add_child(sticks)

	var tex := _soft_texture()
	for fx in [55.0, 150.0, 245.0]:
		var fire := _make_fire(tex, 62.0)
		fire.position = Vector2(fx, BANNER_SIZE.y - 16.0)
		_banner.add_child(fire)
		_fires.append(fire)

	var x1 := _label("X1", 118, Color("ffcf5c"))
	x1.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	x1.add_theme_color_override("font_outline_color", Color("7a1a00"))
	x1.add_theme_constant_override("outline_size", 16)
	_banner.add_child(x1)

	# --- avatares empurrando um ao outro ---
	_av_me = UIStyle.Avatar.new(120.0)
	_av_me.ring_color = MINE_COLOR
	_av_me.ring_width = 5.0
	_root.add_child(_av_me)
	_av_riv = UIStyle.Avatar.new(120.0)
	_av_riv.ring_color = RIVAL_COLOR
	_av_riv.ring_width = 5.0
	_root.add_child(_av_riv)
	# bracinhos socando: meu braço por baixo (esquerda), o do rival por cima (direita).
	# Ficam em controles próprios, acima dos dois avatares, para o punho aparecer sobre o rosto do outro.
	_arm_me = FistArm.new()
	_arm_me.top = false
	_arm_me.sleeve = MINE_COLOR
	_root.add_child(_arm_me)
	_arm_riv = FistArm.new()
	_arm_riv.top = true
	_arm_riv.sleeve = RIVAL_COLOR
	_root.add_child(_arm_riv)
	_lbl_me_name = _label("", 16, Color.WHITE)
	_root.add_child(_lbl_me_name)
	_lbl_riv_name = _label("", 16, Color.WHITE)
	_root.add_child(_lbl_riv_name)

	_sparks = _make_sparks(tex)
	_root.add_child(_sparks)

	# --- barra de força, tempo, botão e dicas ---
	_bar = PushBar.new()
	_bar.mine_color = MINE_COLOR
	_bar.rival_color = RIVAL_COLOR
	_root.add_child(_bar)
	_lbl_bar_me = _label("VOCÊ", 14, Color("9fc2ff"), HORIZONTAL_ALIGNMENT_LEFT)
	_root.add_child(_lbl_bar_me)
	_lbl_bar_riv = _label("RIVAL", 14, Color("ffaaa3"), HORIZONTAL_ALIGNMENT_RIGHT)
	_root.add_child(_lbl_bar_riv)
	_lbl_time = _label("", 18, UIStyle.TEXT_LIGHT)
	_root.add_child(_lbl_time)

	_btn = Button.new()
	_btn.text = "APERTE!"
	_btn.focus_mode = Control.FOCUS_NONE
	_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE   # quem conta os toques é o _input (vale a tela toda, e vários dedos)
	UIStyle.style_button(_btn, UIStyle.Kind.PRIMARY)
	_btn.add_theme_font_size_override("font_size", 38)
	_root.add_child(_btn)
	_lbl_hint = _label("", 13, UIStyle.TEXT_LIGHT)
	_root.add_child(_lbl_hint)

	_lbl_caller = _label("", 20, Color("ffcf5c"))
	_root.add_child(_lbl_caller)
	_lbl_result = _label("", 30, Color.WHITE)
	_lbl_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(_lbl_result)

# Bolinha macia (radial) usada pelas partículas de fogo e de faísca
func _soft_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 48
	gt.height = 48
	return gt

func _additive() -> CanvasItemMaterial:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return m

func _make_fire(tex: Texture2D, half_w: float) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.texture = tex
	p.material = _additive()
	p.amount = 46
	p.lifetime = 1.0
	p.preprocess = 1.0                      # já nasce "pegando fogo"
	p.local_coords = true                   # acompanha o painel quando ele cresce/encolhe
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(half_w, 4.0)
	p.direction = Vector2(0.0, -1.0)
	p.spread = 16.0
	p.gravity = Vector2(0.0, -110.0)
	p.initial_velocity_min = 30.0
	p.initial_velocity_max = 90.0
	p.scale_amount_min = 0.9
	p.scale_amount_max = 2.0
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = shrink
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.95, 0.45, 1.0))
	ramp.set_color(1, Color(0.25, 0.0, 0.0, 0.0))
	ramp.add_point(0.35, Color(1.0, 0.55, 0.10, 0.9))
	ramp.add_point(0.70, Color(0.85, 0.12, 0.05, 0.55))
	p.color_ramp = ramp
	return p

func _make_sparks(tex: Texture2D) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.texture = tex
	p.material = _additive()
	p.amount = 30
	p.lifetime = 0.45
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 8.0
	p.direction = Vector2(0.0, -1.0)
	p.spread = 180.0
	p.gravity = Vector2(0.0, 320.0)
	p.initial_velocity_min = 90.0
	p.initial_velocity_max = 220.0
	p.scale_amount_min = 0.15
	p.scale_amount_max = 0.35
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.95, 0.6, 1.0))
	ramp.set_color(1, Color(1.0, 0.4, 0.1, 0.0))
	p.color_ramp = ramp
	p.emitting = false
	return p


# ---------------------------------------------------------------- desenhos próprios

# Dois tacos de hóquei cruzados: cabo de madeira com fita, lâmina preta com fita branca.
class StickArt extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5 + Vector2(0.0, -6.0)
		_stick(c, -0.62, 1.0)
		_stick(c, 0.62, -1.0)   # o segundo é o espelho do primeiro

	func _stick(c: Vector2, rot: float, flip: float) -> void:
		draw_set_transform(c, rot, Vector2(flip * 0.95, 0.95))
		var wood := Color("e0a85a")
		var shaft := PackedVector2Array([Vector2(-5, -105), Vector2(5, -105), Vector2(5, 60), Vector2(-5, 60)])
		draw_colored_polygon(shaft, wood)
		draw_line(Vector2(2.0, -105.0), Vector2(2.0, 60.0), wood.darkened(0.25), 3.0)
		# lâmina
		var blade := PackedVector2Array([Vector2(-5, 56), Vector2(5, 56), Vector2(8, 92), Vector2(52, 96), Vector2(54, 114), Vector2(-9, 114)])
		draw_colored_polygon(blade, Color("22262e"))
		draw_rect(Rect2(18.0, 97.0, 6.0, 16.0), Color("f2f2f2"))
		draw_rect(Rect2(34.0, 98.0, 6.0, 15.0), Color("f2f2f2"))
		# fita do cabo
		draw_rect(Rect2(-5.5, -105.0, 11.0, 36.0), Color("15171c"))
		for y in [-100.0, -90.0, -80.0]:
			draw_line(Vector2(-5.5, y), Vector2(5.5, y - 3.0), Color("f2f2f2"), 2.0)
		# contornos
		var shaft_o := PackedVector2Array(shaft)
		shaft_o.append(shaft[0])
		draw_polyline(shaft_o, Color.BLACK, 2.5, true)
		var blade_o := PackedVector2Array(blade)
		blade_o.append(blade[0])
		draw_polyline(blade_o, Color.BLACK, 2.5, true)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# Barra do cabo de guerra: começa vazia, centro marcado. Enche para o lado de quem está ganhando.
class PushBar extends Control:
	var value := 0.0   # positivo = eu ganhando (enche para a ESQUERDA, o meu lado); negativo = rival (direita)
	var mine_color := Color("2f6fdb")
	var rival_color := Color("d94a3d")

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var mid := w * 0.5
		draw_rect(Rect2(0.0, 0.0, w, h), Color(0.02, 0.02, 0.08))
		var f := clampf(absf(value), 0.0, 1.0) * mid
		if value > 0.001:
			_fill(Rect2(mid - f, 3.0, f, h - 6.0), mine_color)
		elif value < -0.001:
			_fill(Rect2(mid, 3.0, f, h - 6.0), rival_color)
		draw_line(Vector2(mid, 0.0), Vector2(mid, h), Color.WHITE, 3.0)
		draw_rect(Rect2(0.0, 0.0, w, h), Color.BLACK, false, 4.0)

	func _fill(r: Rect2, col: Color) -> void:
		draw_rect(r, col)
		draw_rect(Rect2(r.position.x, r.position.y, r.size.x, r.size.y * 0.4), col.lightened(0.3))

# Bracinho flexionado socando o rival. Coordenadas em fração do tamanho do avatar (0..1 = o avatar inteiro).
# top = false: sai por baixo e vai para a direita (avatar da esquerda). top = true: o espelho, por cima
# e para a esquerda (avatar da direita). O cotovelo dobrado forma um "V"; o punho avança com `punch` (0..1).
class FistArm extends Control:
	var top := false
	var sleeve := Color("2f6fdb")
	var punch := 0.0   # 0 = braço recolhido; 1 = soco totalmente esticado

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var u := size.x
		var s := Vector2(0.60, 0.93)   # ombro: no canto de baixo do avatar
		var e := Vector2(0.72, 1.22)   # cotovelo (recolhido): bem dobrado, para trás e para baixo
		var f := Vector2(0.97, 1.03)   # punho (recolhido): encostado no rosto do rival
		if top:
			s = Vector2(1.0 - s.x, 1.0 - s.y)
			e = Vector2(1.0 - e.x, 1.0 - e.y)
			f = Vector2(1.0 - f.x, 1.0 - f.y)
		var fd := (f - e).normalized()
		var k := clampf(punch, 0.0, 1.0)
		# soco: o punho dispara ao longo do antebraço e o cotovelo quase estica
		var fx := f + fd * 0.30 * k
		var ex := e.lerp((s + fx) * 0.5, 0.8 * k)
		var w := 0.13 * u
		var ow := w + 0.045 * u
		var ps := s * u
		var pe := ex * u
		var pf := fx * u
		var dir := (pf - pe).normalized()
		# rastro de velocidade atrás do punho
		if k > 0.35:
			var perp0 := Vector2(-dir.y, dir.x)
			for j in [-1.0, 0.0, 1.0]:
				var jj: float = j
				var a0: Vector2 = pf - dir * 0.22 * u + perp0 * 0.10 * u * jj
				draw_line(a0, a0 - dir * 0.22 * u * k, Color(1, 1, 1, 0.75 * k), maxf(2.0, 0.02 * u))
		# contorno preto (segmentos + pontas redondas), depois a manga por cima
		draw_line(ps, pe, Color.BLACK, ow)
		draw_line(pe, pf, Color.BLACK, ow)
		for p in [ps, pe, pf]:
			draw_circle(p, ow * 0.5, Color.BLACK)
		draw_line(ps, pe, sleeve, w)
		draw_line(pe, pf, sleeve, w)
		for p in [ps, pe]:
			draw_circle(p, w * 0.5, sleeve)
		# brilho na manga e punho da camisa (listra branca perto do pulso)
		draw_line(ps + Vector2(0.0, -w * 0.18), pe + Vector2(0.0, -w * 0.18), sleeve.lightened(0.35), w * 0.18)
		var wrist := pf - dir * 0.13 * u
		draw_line(wrist, wrist - dir * 0.045 * u, Color("f2f2f2"), w * 1.02)
		# luva: cresce no soco; círculo claro com contorno e marcas dos dedos
		var gr := 0.115 * u * (1.0 + 0.30 * k)
		draw_circle(pf, gr + 0.03 * u, Color.BLACK)
		draw_circle(pf, gr, Color("f2f2f2"))
		var perp := Vector2(-dir.y, dir.x)
		for q in [-1.0, 0.0, 1.0]:
			var qq: float = q
			var c: Vector2 = pf + dir * gr * 0.35 + perp * gr * 0.42 * qq
			draw_line(c, c + dir * gr * 0.5, Color(0.1, 0.1, 0.15), maxf(1.5, 0.018 * u))
		# explosão de impacto quando o soco chega no máximo
		if k > 0.8:
			var burst_c := pf + dir * gr * 1.15
			var rr := 0.22 * u * k
			var pts := PackedVector2Array()
			for z in 12:
				var ang := TAU * float(z) / 12.0
				var rad := rr if z % 2 == 0 else rr * 0.45
				pts.append(burst_c + Vector2(cos(ang), sin(ang)) * rad)
			draw_colored_polygon(pts, Color("ff9a1f"))
			var pts2 := PackedVector2Array()
			for z in 12:
				var ang2 := TAU * float(z) / 12.0
				var rad2 := rr * 0.55 if z % 2 == 0 else rr * 0.25
				pts2.append(burst_c + Vector2(cos(ang2), sin(ang2)) * rad2)
			draw_colored_polygon(pts2, Color("fff2a8"))
