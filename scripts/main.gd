extends Node2D

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const FIELD := Vector2(320, 640)
const GOAL_W := 110.0     # igual ao do puck.gd
const GOAL_DEPTH := 24.0  # profundidade desenhada dos gols (fica fora do campo)
const HEADER_H := 56.0    # altura do cabeçalho com o placar (agora com a barra de raiva embaixo de cada nome)
# --- Barra de raiva e X1 no meio do jogo ---
const RAGE_GAIN := 0.34       # tomar gol enche a barra: ~3 gols seguidos deixam cheia
const RAGE_DROP := 0.34       # fazer gol esvazia
const NERF_SECONDS := 8.0     # quanto tempo o perdedor do X1 fica enfraquecido
const NERF_POWER := 0.6       # fração da força que o taco devolve ao disco enquanto enfraquecido (1 = normal)
const CPU_X1_DELAY := 1.8     # a CPU (Normal/Difícil) espera isso para apertar o X1 quando a barra dela enche
const START_POS := [Vector2(160, 560), Vector2(160, 80)]
const WIN_SCORE := 7
const AVATAR_SIZE := 32.0
const PING_FONT_SIZE := 11            # tamanho da fonte do ping
const PING_ALPHA := 0.75              # transparência (1.0 = opaco)
const PING_NEUTRAL := Color("fff3e3")  # cor sem medição
const GOAL_PANEL_SECONDS := 1.6       # tempo do painel "GOL!" na tela
const MAX_AVATAR_BYTES := 20000   # limite da foto do rival recebida pela rede
const HINT_SECONDS := 4.0   # quanto tempo o aviso "toque na foto" fica na tela

var my_side := 0
var scores := [0, 0]
var camera: Camera2D
var header: Panel
var header_row: HBoxContainer
var me_btn: Button        # avatar + meu nome: abre o menu
var avatar_mine: UIStyle.Avatar
var avatar_rival: UIStyle.Avatar
var name_mine: Label      # meu nome         (fonte padrão)
var score_mine: Label     # meus pontos      (fonte dos números)
var score_sep: Label      # "x"              (fonte dos números)
var score_rival: Label    # pontos do rival  (fonte dos números)
var name_rival: Label     # nome do rival    (fonte padrão)
var info_label: Label
var _ending := false
var exit_btn: Button
var rival_name := "Rival"
var ping_btn: Button
var debug_label: Label
var _debug_open := false
var hint_label: Label
var goal_panel: Label          # painel "GOL!" no meio da tela
var _goal_tween: Tween
var menu_catcher: Control      # tela cheia invisível: toque fora fecha o dropdown
var menu_panel: VBoxContainer  # dropdown à esquerda, abaixo do cabeçalho
var wait_bar: HBoxContainer    # Placar/Conquistas na espera (ao lado do "Sair")
var end_social: HBoxContainer  # Placar/Conquistas no menu de fim de partida
var confirm_root: Control      # confirmação de saída
var confirm_msg: Label
var rival_btn: Button            # toque no rival (nome/foto no cabeçalho) abre o perfil dele
var rival_root: Control          # cartão com o perfil do rival
var rival_card_avatar: UIStyle.Avatar
var rival_card_name: Label
var rival_card_level: Label
var rival_card_rate: Label
var rival_card_record: Label
var rival_card_note: Label
var rival_stats := {}            # {level, wins, losses} do rival online; vazio = sem dados
var _in_room := false          # hospedou/entrou numa sala
var _in_match := false         # partida em andamento (placar valendo)
var _hint_tween: Tween
var end_root: Control          # menu de fim de partida (Revanche / Sair)
var end_title: Label
var end_sub: Label
var rematch_btn: Button
var _match_done := false       # partida terminou e o menu de fim está valendo
var _rematch_votes: Array = [] # ids de quem pediu revanche (decidido no servidor)
var _session_play := 0.0       # segundos de partida jogados desde a última gravação
var _rate: RatePrompt          # pop-up "avalie com 5 estrelas"
var _faceoff: FaceOff          # X1: disputa de poder (começo da partida e botão de raiva)
var rage := [0.0, 0.0]         # barra de raiva por LADO (0 = baixo, 1 = cima), de 0 a 1
var meter_mine: RageMeter
var meter_rival: RageMeter
var x1_btn: Button             # meu botão X1 (aparece com a barra cheia)
var tag_mine: Label            # "FRACO 5s" embaixo da minha barra
var tag_rival: Label           # "X1!" (rival pode chamar) ou "FRACO 5s", embaixo da barra dele
var _cpu_x1_wait := 0.0

@onready var players: Node2D = $Players
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var puck: Node2D = $Puck

func _apply_font(layer: CanvasLayer) -> void:
	for c in layer.get_children():
		if c is Control:
			c.theme = UIStyle.make_theme()

# Label do header: sem fundo próprio (quem desenha é a faixa), texto centralizado na vertical.
# Nomes ocupam o espaço que sobrar (e viram "..." se não couberem); números têm tamanho fixo.
func _header_label(is_number: bool) -> Label:
	var l := Label.new()
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE   # o clique vai para o botão do avatar
	l.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	l.add_theme_font_size_override("font_size", 16)
	if not is_number:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l

func _flat_box(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(8)
	return sb

# Números do placar usam a fonte própria (export header_number_font no menu)
func _apply_number_font() -> void:
	var f: Font = UIStyle.number_font if UIStyle.number_font else UIStyle.game_font
	for l in [score_mine, score_sep, score_rival]:
		if f:
			l.add_theme_font_override("font", f)
		l.add_theme_font_size_override("font_size", UIStyle.number_size)

# Aviso "toque na sua foto" e dados de rede usam a fonte própria (export info_font no menu)
func _apply_info_font() -> void:
	var f: Font = UIStyle.info_font
	if f == null:
		return   # sem fonte escolhida: ficam com a padrão do jogo
	for c in [hint_label, ping_btn, debug_label]:
		c.add_theme_font_override("font", f)

func _ready() -> void:
	GameAudio.ensure(get_tree())
	GameAudio.set_in_match(false)   # voltou ao menu: música no volume do menu
	camera = Camera2D.new()
	camera.ignore_rotation = false  # por padrão a câmera ignora rotação
	add_child(camera)               # posição e zoom são definidos em _layout()

	var layer := CanvasLayer.new()
	add_child(layer)

	# --- Cabeçalho com o placar ---
	header = Panel.new()
	header.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header.offset_bottom = HEADER_H
	header.visible = false   # <- novo: só aparece durante a partida
	header.custom_minimum_size = Vector2(0, HEADER_H)
	header.add_theme_stylebox_override("panel", UIStyle.header_box())
	layer.add_child(header)
	header.offset_bottom = HEADER_H

	header_row = HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	header.add_child(header_row)
	header_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	header_row.offset_left = 8
	header_row.offset_right = -8

	# Esquerda: avatar + nome = botão que abre o menu
	me_btn = Button.new()
	me_btn.focus_mode = Control.FOCUS_NONE
	me_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	me_btn.custom_minimum_size = Vector2(96, 0)
	me_btn.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	me_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	me_btn.add_theme_stylebox_override("hover", _flat_box(Color(1, 1, 1, 0.25)))
	me_btn.add_theme_stylebox_override("pressed", _flat_box(Color(0, 0, 0, 0.15)))
	me_btn.pressed.connect(_toggle_menu)
	header_row.add_child(me_btn)
	var me_inner := HBoxContainer.new()
	me_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	me_inner.add_theme_constant_override("separation", 6)
	me_btn.add_child(me_inner)
	me_inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	me_inner.offset_left = 4
	me_inner.offset_right = -4
	me_inner.offset_top = 2
	me_inner.offset_bottom = -4
	avatar_mine = UIStyle.Avatar.new(AVATAR_SIZE)
	name_mine = _header_label(false)
	name_mine.size_flags_vertical = Control.SIZE_EXPAND_FILL
	meter_mine = RageMeter.new()
	meter_mine.mine = true
	meter_mine.custom_minimum_size = Vector2(0, 14)
	var me_col := VBoxContainer.new()
	me_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	me_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	me_col.add_theme_constant_override("separation", 1)
	me_col.add_child(name_mine)
	me_col.add_child(meter_mine)
	me_inner.add_child(avatar_mine)
	me_inner.add_child(me_col)

	# Centro: placar
	var score_box := HBoxContainer.new()
	score_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_box.add_theme_constant_override("separation", 6)
	header_row.add_child(score_box)
	score_mine = _header_label(true)
	score_sep = _header_label(true)
	score_sep.text = "-"
	score_rival = _header_label(true)
	for l in [score_mine, score_sep, score_rival]:
		score_box.add_child(l)

	# Direita: nome + avatar do rival (mesma largura da esquerda => placar centralizado).
	# É um botão: tocar abre o perfil do rival (nível, taxa de vitórias).
	rival_btn = Button.new()
	rival_btn.focus_mode = Control.FOCUS_NONE
	rival_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rival_btn.custom_minimum_size = Vector2(96, 0)
	rival_btn.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	rival_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	rival_btn.add_theme_stylebox_override("hover", _flat_box(Color(1, 1, 1, 0.25)))
	rival_btn.add_theme_stylebox_override("pressed", _flat_box(Color(0, 0, 0, 0.15)))
	rival_btn.pressed.connect(_open_rival_card)
	header_row.add_child(rival_btn)
	var rival_inner := HBoxContainer.new()
	rival_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rival_inner.add_theme_constant_override("separation", 6)
	rival_btn.add_child(rival_inner)
	rival_inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rival_inner.offset_left = 4
	rival_inner.offset_right = -4
	rival_inner.offset_top = 2
	rival_inner.offset_bottom = -4
	name_rival = _header_label(false)
	name_rival.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	avatar_rival = UIStyle.Avatar.new(AVATAR_SIZE)
	name_rival.size_flags_vertical = Control.SIZE_EXPAND_FILL
	meter_rival = RageMeter.new()
	meter_rival.mine = false
	meter_rival.custom_minimum_size = Vector2(0, 14)
	var rival_col := VBoxContainer.new()
	rival_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rival_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rival_col.add_theme_constant_override("separation", 1)
	rival_col.add_child(name_rival)
	rival_col.add_child(meter_rival)
	rival_inner.add_child(rival_col)
	rival_inner.add_child(avatar_rival)

	# --- Botão sair da ESPERA (sem placar não há avatar/menu; durante a partida o menu é o avatar) ---
	exit_btn = Button.new()
	exit_btn.text = "Sair"
	exit_btn.focus_mode = Control.FOCUS_NONE
	exit_btn.custom_minimum_size = Vector2(64, 32)
	exit_btn.position = Vector2(6, 6)
	exit_btn.add_theme_font_size_override("font_size", 14)
	exit_btn.add_theme_constant_override("outline_size", UIStyle.OUTLINE_SIZE_TEXT)
	exit_btn.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	exit_btn.add_theme_color_override("font_hover_color", UIStyle.TEXT_DARK)
	exit_btn.add_theme_color_override("font_pressed_color", UIStyle.TEXT_DARK)
	for state in ["normal", "hover", "pressed"]:
		exit_btn.add_theme_stylebox_override(state, UIStyle.label_box(8.0))
	exit_btn.visible = false   # só aparece depois de hospedar/entrar e enquanto o header está escondido
	exit_btn.pressed.connect(_open_confirm)
	layer.add_child(exit_btn)

	# Na espera também: Placar e Conquistas ao lado do "Sair"
	wait_bar = HBoxContainer.new()
	wait_bar.position = Vector2(76, 6)
	wait_bar.add_theme_constant_override("separation", 6)
	wait_bar.visible = false
	wait_bar.add_child(_wait_button("Placar", _on_leaderboard_pressed))
	wait_bar.add_child(_wait_button("Conquistas", _on_achievements_pressed))
	layer.add_child(wait_bar)

	# --- X1 da raiva: botão (meu) e etiquetas, logo abaixo da barra de cada nome ---
	x1_btn = Button.new()
	x1_btn.text = "X1"
	x1_btn.focus_mode = Control.FOCUS_NONE
	x1_btn.custom_minimum_size = Vector2(84, 30)
	UIStyle.style_button(x1_btn, UIStyle.Kind.PRIMARY)
	x1_btn.add_theme_font_size_override("font_size", 18)
	x1_btn.visible = false
	x1_btn.pressed.connect(_on_x1_pressed)
	layer.add_child(x1_btn)
	tag_mine = _tag_label(HORIZONTAL_ALIGNMENT_LEFT)
	layer.add_child(tag_mine)
	tag_rival = _tag_label(HORIZONTAL_ALIGNMENT_RIGHT)
	layer.add_child(tag_rival)

	# --- Ping (canto direito do cabeçalho). Tocar abre os detalhes ---
	ping_btn = Button.new()
	ping_btn.text = "-- ms"
	ping_btn.focus_mode = Control.FOCUS_NONE
	ping_btn.anchor_left = 1.0
	ping_btn.anchor_right = 1.0
	ping_btn.offset_left = -56
	ping_btn.offset_right = -8
	ping_btn.offset_top = HEADER_H + 38     # abaixo da etiqueta do X1 do rival
	ping_btn.offset_bottom = HEADER_H + 56
	ping_btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ping_btn.add_theme_font_size_override("font_size", PING_FONT_SIZE)   # <- tamanho da fonte do ping
	ping_btn.add_theme_constant_override("outline_size", 2)
	for state in ["normal", "hover", "pressed", "focus"]:
		ping_btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())   # sem fundo: só o número
	ping_btn.modulate.a = PING_ALPHA
	_set_ping_color(PING_NEUTRAL)
	ping_btn.visible = false
	ping_btn.pressed.connect(_on_ping_pressed)
	layer.add_child(ping_btn)

	debug_label = Label.new()
	debug_label.anchor_right = 1.0
	debug_label.offset_left = 6
	debug_label.offset_right = -6
	debug_label.offset_top = HEADER_H + 62
	debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debug_label.add_theme_font_size_override("font_size", 12)
	debug_label.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	debug_label.add_theme_stylebox_override("normal", UIStyle.label_box())
	debug_label.visible = false
	layer.add_child(debug_label)

	# --- Aviso central (aguardando jogador, rival saiu...) ---
	info_label = Label.new()
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.add_theme_font_size_override("font_size", 16)
	info_label.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	info_label.add_theme_stylebox_override("normal", UIStyle.label_box())
	layer.add_child(info_label)

	# --- Painel de GOL! (meio da tela; posição/tamanho em _layout) ---
	goal_panel = Label.new()
	goal_panel.text = "GOL!"
	goal_panel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	goal_panel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	goal_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	goal_panel.add_theme_font_size_override("font_size", 56)
	goal_panel.add_theme_color_override("font_color", UIStyle.ACCENT)
	goal_panel.add_theme_constant_override("outline_size", 6)
	goal_panel.add_theme_stylebox_override("normal", UIStyle.label_box(22.0))
	goal_panel.visible = false
	layer.add_child(goal_panel)

	# --- Dica: aparece ao iniciar a partida e some sozinha ---
	hint_label = Label.new()
	hint_label.text = "Toque na sua foto para abrir o menu"
	hint_label.position = Vector2(6, HEADER_H + 40)
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_label.add_theme_font_size_override("font_size", 12)
	hint_label.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	hint_label.add_theme_stylebox_override("normal", UIStyle.label_box(8.0))
	hint_label.visible = false
	layer.add_child(hint_label)

	# --- Dropdown do menu (por enquanto só "Sair") ---
	menu_catcher = Control.new()
	menu_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	menu_catcher.visible = false
	menu_catcher.gui_input.connect(_on_menu_catcher_input)
	layer.add_child(menu_catcher)
	menu_panel = VBoxContainer.new()
	menu_panel.position = Vector2(6, HEADER_H + 6)
	menu_panel.custom_minimum_size = Vector2(150, 0)
	menu_panel.add_theme_constant_override("separation", 8)
	menu_catcher.add_child(menu_panel)
	menu_panel.add_child(_menu_button("Sair", _open_confirm, UIStyle.Kind.SECONDARY, 44))

	# --- Confirmação de saída ---
	confirm_root = Control.new()
	confirm_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	confirm_root.visible = false
	layer.add_child(confirm_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	confirm_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	confirm_root.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	confirm_msg = Label.new()
	confirm_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	confirm_msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	confirm_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	confirm_msg.custom_minimum_size = Vector2(280, 72)
	confirm_msg.add_theme_font_size_override("font_size", 16)
	confirm_msg.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	confirm_msg.add_theme_stylebox_override("normal", UIStyle.label_box())
	box.add_child(confirm_msg)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var cancel_btn := _menu_button("Cancelar", _close_confirm, UIStyle.Kind.GHOST, 52)
	var ok_btn := _menu_button("Sair", _confirm_exit, UIStyle.Kind.PRIMARY, 52)
	for b in [cancel_btn, ok_btn]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)

	# --- Perfil do rival ---
	rival_root = Control.new()
	rival_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rival_root.visible = false
	layer.add_child(rival_root)
	var rdim := ColorRect.new()
	rdim.color = Color(0, 0, 0, 0.6)
	rdim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rdim.mouse_filter = Control.MOUSE_FILTER_STOP
	rdim.gui_input.connect(_on_rival_dim_input)
	rival_root.add_child(rdim)
	var rcenter := CenterContainer.new()
	rcenter.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rcenter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rival_root.add_child(rcenter)
	var rbox := VBoxContainer.new()
	rbox.custom_minimum_size = Vector2(280, 0)
	rbox.add_theme_constant_override("separation", 10)
	rcenter.add_child(rbox)
	var avatar_row := CenterContainer.new()
	rbox.add_child(avatar_row)
	rival_card_avatar = UIStyle.Avatar.new(72.0)
	avatar_row.add_child(rival_card_avatar)
	rival_card_name = _card_label(20, 44)
	rival_card_level = _card_label(16, 40)
	rival_card_rate = _card_label(16, 40)
	rival_card_record = _card_label(14, 40)
	rival_card_note = _card_label(12, 0)
	for l in [rival_card_name, rival_card_level, rival_card_rate, rival_card_record, rival_card_note]:
		rbox.add_child(l)
	rbox.add_child(_menu_button("Fechar", _close_rival_card, UIStyle.Kind.PRIMARY, 48))

	# --- Fim de partida: resultado + Revanche / Sair ---
	end_root = Control.new()
	end_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_root.visible = false
	layer.add_child(end_root)
	var end_dim := ColorRect.new()
	end_dim.color = Color(0, 0, 0, 0.6)
	end_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	end_root.add_child(end_dim)
	var end_center := CenterContainer.new()
	end_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	end_root.add_child(end_center)
	var end_box := VBoxContainer.new()
	end_box.custom_minimum_size = Vector2(280, 0)
	end_box.add_theme_constant_override("separation", 12)
	end_center.add_child(end_box)
	end_title = Label.new()
	end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	end_title.custom_minimum_size = Vector2(280, 64)
	end_title.add_theme_font_size_override("font_size", 28)
	end_title.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	end_title.add_theme_stylebox_override("normal", UIStyle.label_box())
	end_box.add_child(end_title)
	end_sub = Label.new()
	end_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	end_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_sub.custom_minimum_size = Vector2(280, 56)
	end_sub.add_theme_font_size_override("font_size", 16)
	end_sub.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	end_sub.add_theme_stylebox_override("normal", UIStyle.label_box())
	end_box.add_child(end_sub)
	rematch_btn = _menu_button("Revanche", _on_rematch_pressed, UIStyle.Kind.PRIMARY, 52)
	end_box.add_child(rematch_btn)
	end_social = HBoxContainer.new()
	end_social.add_theme_constant_override("separation", 12)
	var end_lb := _menu_button("Placar", _on_leaderboard_pressed, UIStyle.Kind.SECONDARY, 44)
	var end_ach := _menu_button("Conquistas", _on_achievements_pressed, UIStyle.Kind.SECONDARY, 44)
	for sb in [end_lb, end_ach]:
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		end_social.add_child(sb)
	end_box.add_child(end_social)
	end_box.add_child(_menu_button("Sair", _on_exit_pressed, UIStyle.Kind.GHOST, 52))

	# --- Pop-up de avaliação (aparece no fim de uma partida, depois de alguns minutos jogados) ---
	_rate = RatePrompt.new()
	add_child(_rate)
	_rate.closed.connect(_update_blocking)

	# --- X1 (disputa de posse). O nome precisa ser igual nos dois aparelhos: as RPCs dele moram nesse nó ---
	_faceoff = FaceOff.new()
	_faceoff.name = "FaceOff"
	add_child(_faceoff)
	_faceoff.finished.connect(_on_faceoff_finished)
	_faceoff.state_changed.connect(_update_blocking)

	UIStyle.hud_top = HEADER_H
	UIStyle.ui_blocking = false   # o static sobrevive ao reload da cena

	# fonte do jogo (o menu define UIStyle.game_font; adiado p/ não depender da ordem)
	_apply_font.call_deferred(layer)
	_apply_number_font.call_deferred()
	_apply_info_font.call_deferred()

	_refresh_score()
	_layout()
	get_viewport().size_changed.connect(_layout)

	spawner.spawn_function = _spawn_player
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Net.hosted.connect(_on_hosted)
	Net.ended.connect(_on_net_ended)
	Net.room_status.connect(_on_room_status)
	Net.joined.connect(_on_joined)
	Net.stats_updated.connect(_on_stats)
	UIStyle.rival_avatar = null   # o static sobrevive ao reload: começa sem foto de rival
	PlayGames.avatar_changed.connect(_refresh_score)   # minha foto chegou depois do cabeçalho existir
	puck.goal.connect(_on_goal)
	puck.wall_hit.connect(_on_wall_hit)
	puck.paddle_hit.connect(_on_paddle_hit)

# ---------------------------------------------------------------- menu da partida

func _menu_button(text: String, callback: Callable, kind: UIStyle.Kind, h: float) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, h)
	b.pressed.connect(callback)
	UIStyle.style_button(b, kind)
	return b

# Botão pequeno da espera (mesmo visual do "Sair" daquela tela)
func _wait_button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 32)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_constant_override("outline_size", UIStyle.OUTLINE_SIZE_TEXT)
	b.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	b.add_theme_color_override("font_hover_color", UIStyle.TEXT_DARK)
	b.add_theme_color_override("font_pressed_color", UIStyle.TEXT_DARK)
	for state in ["normal", "hover", "pressed"]:
		b.add_theme_stylebox_override(state, UIStyle.label_box(8.0))
	b.pressed.connect(callback)
	return b

# Sem login, o toque tenta entrar no Play Games (ver PlayGames.show_*)
func _on_leaderboard_pressed() -> void:
	_close_menu()
	PlayGames.show_leaderboard()

func _on_achievements_pressed() -> void:
	_close_menu()
	PlayGames.show_achievements()

# Linha de texto do cartão do rival (mesmo visual do aviso de confirmação)
func _card_label(font_size: int, min_h: float) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(280, min_h)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	l.add_theme_stylebox_override("normal", UIStyle.label_box())
	return l

func _pct_text(v: float) -> String:
	return ("%.1f" % v).replace(".", ",") + "%"

func _open_rival_card() -> void:
	if confirm_root.visible or _ending or menu_catcher.visible:
		return
	rival_card_avatar.texture = UIStyle.rival_avatar
	rival_card_name.text = rival_name
	rival_card_note.visible = false
	if Net.vs_cpu:
		var diffs := ["Fácil", "Normal", "Difícil"]
		rival_card_level.text = "Computador"
		rival_card_rate.text = "Dificuldade: %s" % diffs[clampi(Net.cpu_level, 0, 2)]
		rival_card_record.visible = false
	elif rival_stats.is_empty():
		rival_card_level.text = "Nível: --"
		rival_card_rate.text = "Taxa de vitórias: --"
		rival_card_record.visible = false
		rival_card_note.text = "Este jogador usa uma versão antiga do jogo, sem perfil."
		rival_card_note.visible = true
	else:
		var w: int = rival_stats.wins
		var d: int = rival_stats.losses
		var n := w + d
		rival_card_level.text = "Nível %d" % rival_stats.level
		rival_card_record.visible = true
		if n > 0:
			rival_card_rate.text = "Taxa de vitórias: %s" % _pct_text(100.0 * float(w) / float(n))
			rival_card_record.text = "%d vitórias • %d derrotas (online)" % [w, d]
		else:
			rival_card_rate.text = "Taxa de vitórias: --"
			rival_card_record.text = "Ainda sem partidas online"
		if n < PlayGames.MIN_RATED_MATCHES:
			rival_card_note.text = "Poucas partidas: a taxa ainda pode variar bastante."
			rival_card_note.visible = true
	rival_root.visible = true
	_hide_hint()
	_update_blocking()

func _on_rival_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_rival_card()

func _close_rival_card() -> void:
	rival_root.visible = false
	_update_blocking()

# Texto enviado ao rival no lugar do nome puro: "nome|nível|vitórias|derrotas".
# Vai dentro do _set_name (RPC que já existe): criar uma RPC nova mudaria a lista de RPCs
# do script e as versões antigas e novas do jogo deixariam de se entender.
func _my_name_payload() -> String:
	var n := Net.player_name.replace("|", "").replace("\n", " ").strip_edges()
	return "%s|%d|%d|%d" % [n, PlayGames.level(), PlayGames.rated_wins, PlayGames.rated_losses]

func _update_blocking() -> void:
	UIStyle.ui_blocking = menu_catcher.visible or confirm_root.visible or rival_root.visible \
			or end_root.visible or (_rate != null and _rate.is_open()) \
			or (_faceoff != null and _faceoff.is_active())
	# banner do rodapé só enquanto o menu do avatar está aberto (nunca com a partida rolando sem menu)
	Monetization.set_banner_wanted("pause", menu_catcher.visible)

func _exit_tree() -> void:
	Monetization.set_banner_wanted("pause", false)

func _toggle_menu() -> void:
	if confirm_root.visible or rival_root.visible or _ending:
		return
	menu_catcher.visible = not menu_catcher.visible
	_hide_hint()   # quem abriu o menu já descobriu
	_update_blocking()

func _close_menu() -> void:
	menu_catcher.visible = false
	_update_blocking()

func _on_menu_catcher_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_menu()

func _open_confirm() -> void:
	if _ending:
		return
	menu_catcher.visible = false
	if _in_match and not Net.vs_cpu:
		confirm_msg.text = "Sair agora conta como DERROTA nesta partida online.\nDeseja sair?"
	else:
		confirm_msg.text = "Deseja sair da partida?"
	confirm_root.visible = true
	_update_blocking()

func _close_confirm() -> void:
	confirm_root.visible = false
	_update_blocking()

func _confirm_exit() -> void:
	if _ending:
		return
	var forfeit := _in_match and not Net.vs_cpu   # online com partida valendo = derrota
	_in_match = false
	menu_catcher.visible = false
	confirm_root.visible = false
	UIStyle.ui_blocking = false
	if forfeit:
		PlayGames.record_match(false, scores[my_side], false, Net.cpu_level, false)
	_on_exit_pressed()
	

func _show_hint() -> void:
	if _hint_tween:
		_hint_tween.kill()
	hint_label.modulate.a = 1.0
	hint_label.visible = true
	_hint_tween = create_tween()
	_hint_tween.tween_interval(HINT_SECONDS)
	_hint_tween.tween_property(hint_label, "modulate:a", 0.0, 0.6)
	_hint_tween.tween_callback(func(): hint_label.visible = false)

func _hide_hint() -> void:
	if _hint_tween:
		_hint_tween.kill()
	hint_label.visible = false

# Encaixa a quadra (com a profundidade dos gols) na área abaixo do cabeçalho
# e posiciona o aviso no centro dessa área.
func _layout() -> void:
	var vp := get_viewport_rect().size
	var avail_h := vp.y - HEADER_H
	var z := minf(vp.x / FIELD.x, avail_h / (FIELD.y + GOAL_DEPTH * 2.0))
	camera.zoom = Vector2(z, z)
	# Desloca a câmera para a quadra ficar centrada abaixo do cabeçalho.
	# "Para baixo na tela" vira outra direção no mundo quando a câmera gira.
	var down_in_world := Vector2.DOWN.rotated(camera.rotation)
	camera.position = FIELD / 2.0 - down_in_world * (HEADER_H / 2.0) / z
	info_label.size = Vector2(vp.x, 60)
	info_label.position = Vector2(0, (vp.y + HEADER_H) / 2.0 - 30.0)
	var gw := minf(260.0, vp.x - 32.0)
	goal_panel.size = Vector2(gw, 100)
	goal_panel.pivot_offset = goal_panel.size / 2.0   # a animação cresce a partir do centro
	goal_panel.position = Vector2((vp.x - gw) / 2.0, (vp.y + HEADER_H) / 2.0 - 50.0)
	x1_btn.size = Vector2(84, 30)
	x1_btn.pivot_offset = Vector2(42, 15)
	x1_btn.position = Vector2(8, HEADER_H + 4)
	tag_mine.size = Vector2(120, 22)
	tag_mine.position = Vector2(8, HEADER_H + 6)
	tag_rival.size = Vector2(120, 22)
	tag_rival.position = Vector2(vp.x - 8 - 120, HEADER_H + 6)

# O aviso central só aparece quando tem texto (senão sobraria uma faixa vazia)
func _process(delta: float) -> void:
	_update_rage_hud(delta)
	if _in_match:
		_session_play += delta   # tempo de jogo para o pop-up de avaliação
	info_label.visible = info_label.text != ""
	exit_btn.visible = _in_room and not header.visible and not _ending   # só na espera
	wait_bar.visible = exit_btn.visible and PlayGames.can_show_social()
	ping_btn.visible = header.visible and not Net.vs_cpu   # só online
	debug_label.visible = _debug_open and header.visible and not Net.vs_cpu

func _on_ping_pressed() -> void:
	_debug_open = not _debug_open
	debug_label.text = Net.stats_text()

func _set_ping_color(col: Color) -> void:
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		ping_btn.add_theme_color_override(st, col)

func _on_stats() -> void:
	var r: float = Net.rtt_ms
	ping_btn.text = "-- ms" if r < 0.0 else "%d ms" % int(round(r))
	var col: Color = PING_NEUTRAL
	if r >= 0.0:
		col = Color("5be37d") if r < 60.0 else (Color("ffb340") if r < 120.0 else Color("ff5a52"))
	_set_ping_color(col)
	if _debug_open:
		debug_label.text = Net.stats_text()

# Roda em todos os aparelhos, com os mesmos dados
func _spawn_player(data: Dictionary) -> Node:
	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	var is_ai: bool = data.get("ai", false)
	var mine: bool = not is_ai and data.id == multiplayer.get_unique_id()
	p.name = str(data.id)
	p.side = data.side
	p.ai = is_ai
	p.ai_level = data.get("level", 1)
	p.position = START_POS[data.side]
	p.is_rival = not mine   # eu = visual padrão da sprite; rival = hue_shift alterado
	if mine:
		my_side = data.side
		camera.rotation = PI if my_side == 1 else 0.0  # espelha para o jogador de cima
		_layout()  # a direção do deslocamento depende da rotação
		_refresh_score()
	return p

func _on_hosted() -> void:
	_in_room = true
	if Net.vs_cpu:
		_start_cpu_match()
		return
	if DisplayServer.get_name() != "headless":
		_add_player(1)

# Contra a CPU: eu (lado de baixo) e um taco controlado pelo computador
func _start_cpu_match() -> void:
	_add_player(1)
	spawner.spawn({"id": "cpu", "side": _free_side(), "ai": true, "level": Net.cpu_level})
	rival_name = "CPU"
	rival_stats = {}
	info_label.text = ""
	_try_start()

# Sem rede (CPU) o placar/estado é atualizado direto; online, via RPC
func _sync_score() -> void:
	if Net.vs_cpu:
		_set_score(scores[0], scores[1])
	else:
		_set_score.rpc(scores[0], scores[1])

func _on_room_status(text: String) -> void:
	info_label.text = text

func _on_joined() -> void:
	_in_room = true
	info_label.text = ""
	_set_name.rpc(_my_name_payload())
	_set_avatar.rpc(PlayGames.my_avatar_jpg)

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_add_player(id)
		_set_name.rpc_id(id, _my_name_payload())
		_set_avatar.rpc_id(id, PlayGames.my_avatar_jpg)
		_try_start()
		info_label.text = ""

func _on_peer_disconnected(id: int) -> void:
	if _ending:      # <- novo: estou saindo, não há mais nada a atualizar
		return
	if not multiplayer.is_server():
		return
	if players.has_node(str(id)):
		players.get_node(str(id)).queue_free()
	puck.stop()
	scores = [0, 0]
	_set_score.rpc(0, 0)
	info_label.text = "Rival saiu.\nAguardando novo jogador..."
	_set_match_active.rpc(false)   # <- novo (já zera e esconde)

# Chamado no cliente quando o host cai
func _on_net_ended(reason: String) -> void:
	if _ending:
		return
	_ending = true
	_faceoff.cancel()
	_flush_play_time()
	players.process_mode = Node.PROCESS_MODE_DISABLED  # congela tacos e entrada
	header.visible = false          # <- novo
	scores = [0, 0]                 # <- novo
	_refresh_score()                # <- novo
	puck.set_physics_process(false)
	info_label.text = reason
	await get_tree().create_timer(2.5).timeout
	get_tree().reload_current_scene()

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
		_sync_score()
		if Net.vs_cpu:
			_set_match_active(true)
		else:
			_set_match_active.rpc(true)
		_faceoff.start()   # o X1 decide quem fica com o disco; o saque sai em _on_faceoff_finished

# O X1 acabou (em todos os aparelhos). caller_side = -1: disputa do começo da partida.
# Senão foi o botão de raiva: a barra de quem chamou zera e o PERDEDOR fica enfraquecido por um tempo.
func _on_faceoff_finished(winner_side: int, caller_side: int) -> void:
	if not _in_match:
		return
	if caller_side >= 0:
		rage[caller_side] = 0.0
		puck.nerf(1 - winner_side, NERF_SECONDS, NERF_POWER)
	else:
		_show_hint()
	GameAudio.whistle_start()   # apito: o disco volta ao jogo
	if multiplayer.is_server():
		puck.serve(winner_side)

# ---------------------------------------------------------------- raiva

# Cada gol: quem sofreu enche a barra, quem fez esvazia (roda nos dois aparelhos, via _goal_fx)
func _rage_on_goal(scorer_side: int) -> void:
	var conceded := 1 - scorer_side
	rage[conceded] = minf(1.0, float(rage[conceded]) + RAGE_GAIN)
	rage[scorer_side] = maxf(0.0, float(rage[scorer_side]) - RAGE_DROP)

# O X1 do botão pode ser chamado? (chamado também pelo FaceOff, no host, para validar o pedido)
func can_call_x1(side: int) -> bool:
	if _faceoff == null or _faceoff.is_active():
		return false
	return _in_match and not _match_done and not _ending and float(rage[clampi(side, 0, 1)]) >= 0.999

func _on_x1_pressed() -> void:
	if can_call_x1(my_side):
		_close_menu()
		_faceoff.request_x1()

# Etiqueta pequena (texto claro com contorno) para "FRACO 5s" e "X1!"
func _tag_label(align: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = align as HorizontalAlignment
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", UIStyle.TEXT_LIGHT)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.visible = false
	return l

func _update_rage_hud(delta: float) -> void:
	var me := clampi(my_side, 0, 1)
	meter_mine.value = float(rage[me])
	meter_rival.value = float(rage[1 - me])
	var show_hud := header.visible and not _ending
	var can := show_hud and can_call_x1(me)
	x1_btn.visible = can
	if can:   # botão pulsa para chamar atenção
		var k := 1.0 + 0.06 * sin(Time.get_ticks_msec() / 1000.0 * 9.0)
		x1_btn.scale = Vector2(k, k)
	# minha etiqueta: só aparece enfraquecido (com o botão visível, ele ocupa o lugar)
	var my_nerf: float = puck.nerf_left(me)
	tag_mine.visible = show_hud and not can and my_nerf > 0.0
	tag_mine.text = "FRACO %ds" % ceili(my_nerf)
	# etiqueta do rival: "X1!" quando a barra dele está cheia; senão "FRACO"
	var riv_nerf: float = puck.nerf_left(1 - me)
	var riv_ready := float(rage[1 - me]) >= 0.999 and _in_match and not _match_done
	tag_rival.visible = show_hud and (riv_ready or riv_nerf > 0.0)
	if riv_ready:
		tag_rival.text = "X1!"
		tag_rival.add_theme_color_override("font_color", Color("ffcf5c") if int(Time.get_ticks_msec() / 250) % 2 == 0 else Color("ff6a2a"))
	else:
		tag_rival.text = "FRACO %ds" % ceili(riv_nerf)
		tag_rival.add_theme_color_override("font_color", UIStyle.TEXT_LIGHT)
	# CPU (Normal/Difícil) também usa o X1 quando a barra dela enche
	if Net.vs_cpu and _in_match and not _match_done and Net.cpu_level >= 1 and not _faceoff.is_active():
		if float(rage[1 - me]) >= 0.999:
			_cpu_x1_wait += delta
			if _cpu_x1_wait >= CPU_X1_DELAY:
				_cpu_x1_wait = 0.0
				_faceoff.call_x1(1 - me)
		else:
			_cpu_x1_wait = 0.0

func _on_wall_hit(impact: float) -> void:
	if _in_match:
		GameAudio.wall(impact)   # som + vibração bem sutil

func _on_paddle_hit(impact: float, mine: bool) -> void:
	if _in_match:
		GameAudio.hit(impact, mine)   # som do taco + vibração sutil (só no meu taco)

func _on_goal(scorer_side: int, info: int = 0) -> void:
	scores[scorer_side] += 1
	_sync_score()
	if Net.vs_cpu:
		_goal_fx(scorer_side)
	else:
		_goal_fx.rpc(scorer_side)
	if scores[scorer_side] >= WIN_SCORE:
		_end_match(scorer_side)

# Em cada aparelho: painel GOL!, torcida e vibração forte
@rpc("authority", "call_local", "reliable")
func _goal_fx(_scorer_side: int) -> void:
	_rage_on_goal(_scorer_side)
	GameAudio.goal()
	if _goal_tween:
		_goal_tween.kill()
	goal_panel.visible = true
	goal_panel.modulate.a = 0.0
	goal_panel.scale = Vector2(0.5, 0.5)
	_goal_tween = create_tween()
	_goal_tween.tween_property(goal_panel, "modulate:a", 1.0, 0.12)
	_goal_tween.parallel().tween_property(goal_panel, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_goal_tween.tween_interval(maxf(GOAL_PANEL_SECONDS - 0.75, 0.1))
	_goal_tween.tween_property(goal_panel, "modulate:a", 0.0, 0.35)
	_goal_tween.tween_callback(func(): goal_panel.visible = false)

@rpc("authority", "call_local", "reliable")
func _set_score(a: int, b: int) -> void:
	scores = [a, b]
	_refresh_score()

@rpc("authority", "call_local", "reliable")
func _set_match_active(active: bool) -> void:
	_in_match = active
	_match_done = false      # nova partida (ou rival saiu): o menu de fim não vale mais
	_rematch_votes = []
	rage = [0.0, 0.0]
	_cpu_x1_wait = 0.0
	end_root.visible = false
	_update_blocking()
	header.visible = active
	GameAudio.set_in_match(active)
	if not active:
		_faceoff.cancel()   # rival saiu no meio do X1
		_flush_play_time()
		_hide_hint()
		if _goal_tween:
			_goal_tween.kill()
		goal_panel.visible = false
		_close_menu()
		_close_confirm()
		scores = [0, 0]
		rival_name = "Rival"
		rival_stats = {}
		_close_rival_card()
		UIStyle.rival_avatar = null
		_refresh_score()

@rpc("any_peer", "reliable")
func _set_name(n: String) -> void:
	# Formato novo: "nome|nível|vitórias|derrotas". Versão antiga manda só o nome.
	var parts := n.split("|")
	rival_stats = {}
	if parts.size() >= 4 and parts[1].is_valid_int() and parts[2].is_valid_int() and parts[3].is_valid_int():
		rival_stats = {
			"level": clampi(int(parts[1]), 1, 999),
			"wins": clampi(int(parts[2]), 0, 1000000),
			"losses": clampi(int(parts[3]), 0, 1000000),
		}
	var clean := parts[0].replace("\n", " ").strip_edges().left(10)
	rival_name = clean if clean != "" else "Rival"
	_refresh_score()

# Foto do rival (JPEG pequeno). Vazio = ele não tem foto: fica a silhueta
@rpc("any_peer", "reliable")
func _set_avatar(bytes: PackedByteArray) -> void:
	UIStyle.rival_avatar = null
	if bytes.size() > 2 and bytes.size() <= MAX_AVATAR_BYTES and bytes[0] == 0xFF and bytes[1] == 0xD8:
		var img := Image.new()
		if img.load_jpg_from_buffer(bytes) == OK and img.get_width() <= 256 and img.get_height() <= 256:
			UIStyle.rival_avatar = ImageTexture.create_from_image(img)
	_refresh_score()

func _refresh_score() -> void:
	var mine := Net.player_name if Net.player_name != "" else "Você"
	name_mine.text = mine
	score_mine.text = str(scores[my_side])
	score_rival.text = str(scores[1 - my_side])
	name_rival.text = rival_name
	avatar_mine.texture = UIStyle.my_avatar
	avatar_rival.texture = UIStyle.rival_avatar

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
	draw_rect(Rect2(gl, -GOAL_DEPTH, GOAL_W, GOAL_DEPTH), Color(1, 1, 1, 0.15))
	draw_rect(Rect2(gl, h, GOAL_W, GOAL_DEPTH), Color(1, 1, 1, 0.15))

func _on_exit_pressed() -> void:
	if _ending:
		return
	_ending = true
	var finished := _match_done      # saindo DEPOIS de uma partida terminada (desistir não mostra anúncio)
	_flush_play_time()
	Net.leave()                      # fecha a conexão e limpa a sala no Firebase
	if finished:
		await Monetization.show_if_due()   # só mostra se as regras de frequência deixarem
	get_tree().reload_current_scene()  # volta ao menu (com o overlay)

# Só no servidor: decide o vencedor e avisa todos. A próxima partida só começa com a REVANCHE.
func _end_match(winner_side: int) -> void:
	puck.stop()
	if Net.vs_cpu:
		_match_over(winner_side)
	else:
		_match_over.rpc(winner_side)

# Roda em cada aparelho, e cada um registra o seu próprio resultado
@rpc("authority", "call_local", "reliable")
func _match_over(winner_side: int) -> void:
	var won := winner_side == my_side
	_in_match = false   # já registrado aqui: sair agora não conta derrota de novo
	_match_done = true
	_flush_play_time()
	PlayGames.record_match(won, scores[my_side], Net.vs_cpu, Net.cpu_level)
	Monetization.on_match_finished()   # conta a partida e deixa o próximo anúncio carregando
	# deixa o painel "GOL!" aparecer antes do apito final e do resultado (mesmo lugar da tela)
	await get_tree().create_timer(GOAL_PANEL_SECONDS).timeout
	if _ending or not _match_done:   # saiu, ou o rival foi embora nesse meio tempo
		return
	GameAudio.whistle_end()   # apito de fim
	_close_menu()
	_close_confirm()
	var t := "Você venceu!" if won else "Você perdeu"
	t += "\n+%d XP" % PlayGames.last_xp_gain
	if PlayGames.last_level_up:
		t += " · Nível %d!" % PlayGames.level()
	end_title.text = t
	end_social.visible = PlayGames.can_show_social()
	_refresh_end_menu()
	end_root.visible = true
	_update_blocking()
	# depois de alguns minutos jogados, pede a avaliação por cima do menu de fim
	if RatePrompt.should_ask():
		await get_tree().create_timer(0.8).timeout
		if not _ending and _match_done and end_root.visible:
			_rate.show_prompt()
			_update_blocking()

# ---------------------------------------------------------------- revanche

func _on_rematch_pressed() -> void:
	if _ending or not _match_done:
		return
	if Net.vs_cpu:
		# Contra a CPU: a cada 3 partidas terminadas (contando as de revanche) mostra um anúncio
		# antes de começar a próxima. Online NUNCA: o rival ficaria esperando o anúncio fechar.
		rematch_btn.disabled = true   # evita toque duplo enquanto o anúncio está aberto
		await Monetization.show_if_due()
		if _ending or not _match_done:
			return
		rematch_btn.disabled = false
		_start_rematch()
	elif multiplayer.is_server():
		_add_rematch_vote(1)
	else:
		_rematch_vote.rpc_id(1)
		rematch_btn.disabled = true   # feedback imediato; o servidor confirma em seguida

# Cliente -> servidor: "quero revanche"
@rpc("any_peer", "reliable")
func _rematch_vote() -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	_add_rematch_vote(id if id != 0 else 1)

# Só no servidor: anota o voto, avisa todos e começa quando os dois quiserem
func _add_rematch_vote(id: int) -> void:
	if not _match_done or _rematch_votes.has(id):
		return
	var votes := _rematch_votes.duplicate()
	votes.append(id)
	_set_rematch_votes.rpc(votes)
	if votes.size() >= 2:
		_start_rematch()

func _start_rematch() -> void:
	if _ending or players.get_child_count() < 2:
		return
	_try_start()   # zera o placar, esconde o menu de fim (via _set_match_active) e saca

@rpc("authority", "call_local", "reliable")
func _set_rematch_votes(votes: Array) -> void:
	_rematch_votes = votes
	_refresh_end_menu()

func _refresh_end_menu() -> void:
	var me := multiplayer.get_unique_id()
	var i_want := _rematch_votes.has(me)
	var rival_wants := false
	for v in _rematch_votes:
		if v != me:
			rival_wants = true
	rematch_btn.disabled = i_want
	rematch_btn.text = "Aguardando..." if i_want else "Revanche"
	var line := "Placar final: %d x %d" % [scores[my_side], scores[1 - my_side]]
	if not Net.vs_cpu:
		if i_want:
			line += "\nAguardando %s..." % rival_name
		elif rival_wants:
			line += "\n%s quer revanche!" % rival_name
	end_sub.text = line

# Grava o tempo jogado (usado pelo pop-up de avaliação)
func _flush_play_time() -> void:
	if _session_play > 0.0:
		RatePrompt.add_play_time(_session_play)
		_session_play = 0.0
