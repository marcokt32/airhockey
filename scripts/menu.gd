extends CanvasLayer

enum Screen { MAIN, PLAY, MODE, ONLINE, CPU, LOCAL, QUICK, SHARE }

# Texto usado só se nenhuma arte for definida em title_art
const GAME_TITLE := "AIR HOCKEY"

const SETTINGS_PATH := "user://settings.cfg"
const BTN_HEIGHT := 52
const SMALL_BTN_HEIGHT := 36      # Placar, Conquistas e Compartilhar
const SMALL_BTN_FONT := 14
const COLUMN_WIDTH := 300
const SHARE_TEXT := "Venha jogar Air Hockey comigo!"   # texto enviado ao compartilhar
const NOTICE_FONT_SIZE := 11   # tamanho da fonte dos avisos do menu
const REGION_FONT_SIZE := 12   # fonte do seletor de servidor (evita alargar a tela)
const LOADING_FADE_SECONDS := 0.25   # fade da tela de loading ao sair
const REGION_LABEL_H := 28     # altura do rótulo "Servidor" (o padrão dos labels é maior)

# --- Personalização (arraste os arquivos no Inspector, no nó do menu) ---
@export var game_font: Font                 # fonte padrão do jogo todo
@export var header_number_font: Font        # fonte dos NÚMEROS do placar no header (vazio = game_font)
@export var header_number_size := 22        # tamanho dessa fonte
@export var info_font: Font                 # fonte do aviso "toque na sua foto..." e dos dados de rede (ping)
@export var title_art: Texture2D            # sua arte com logo + nome (substitui o texto do topo)
@export var title_art_height := 160         # altura máxima da arte no menu, em pixels
@export var remove_ads_icon: Texture2D      # ícone sutil (canto esquerdo) de "Remover anúncios"
@export var share_icon: Texture2D           # ícone sutil (canto direito) de "Compartilhar"
@export var corner_icon_size := 32          # tamanho dos dois ícones
@export_range(0.1, 1.0, 0.05) var corner_icon_opacity := 0.85   # opacidade em repouso
@export var corner_icon_glow := Color("ffd9a0")                 # cor da luz que pulsa atrás dos ícones
@export_range(1.0, 1.4, 0.01) var corner_icon_pulse_scale := 1.12   # quanto o ícone cresce no pulso
@export_range(0.3, 3.0, 0.1) var corner_icon_pulse_seconds := 0.9   # meio ciclo do pulso

var _overlay: ColorRect
var _center: CenterContainer
var _title: Label
var _brand: VBoxContainer
var _top_bar: Control   # nível/XP no topo (só no menu principal)
var _social_row: HBoxContainer   # Placar + Conquistas: só aparece logado
var _login_btn: Button           # "Entrar no Play Games": só aparece deslogado
var _remove_ads_btn: Button      # "Remover anúncios": compra única; some depois de comprar
var _share_btn: Button           # ícone de compartilhar (canto direito)
var _corner_bar: HBoxContainer   # linha dos dois ícones (topo do painel principal)
var _play_panel: VBoxContainer   # "Contra a CPU" / "Jogar online"
var _loading_layer: CanvasLayer      # tela de loading da abertura do app
var _loading_root: Control
var _loading_label: Label
var _loading_tween: Tween
var _banner_placeholder: ColorRect   # só no editor: mostra onde o banner fica
var _top_avatar: UIStyle.Avatar   # avatar do botão de perfil (topo)
var _top_name: Label
var _profile_card: Control
var _card_avatar: UIStyle.Avatar
var _card_name: LineEdit
var _card_msg: Label
var _card_reset: Button
var _avatar_picker: Control   # grade de avatares do jogo
var _file_dialog: FileDialog
var _status: Label
var _main_panel: VBoxContainer
var _mode_panel: VBoxContainer
var _online_panel: VBoxContainer
var _local_panel: VBoxContainer
var _cpu_panel: VBoxContainer
var _quick_panel: VBoxContainer
var _share_panel: VBoxContainer
var _quick_label: Label
var _level: OptionButton
var _code: LineEdit
var _ip: LineEdit

func _ready() -> void:
	_inicializar_admob()
	if not Monetization.startup_needed():
		GameAudio.ensure(get_tree())   # música tema começa já no menu (depois do loading, se houver)
	UIStyle.game_font = game_font   # usado pelo HUD da partida (main.gd)
	UIStyle.number_font = header_number_font
	UIStyle.number_size = header_number_size
	UIStyle.info_font = info_font

	# --- Fonte padrão do jogo (menu, placar, avisos... tudo que não tem fonte própria) ---
	if game_font != null:
		ThemeDB.get_default_theme().default_font = game_font

	# --- Overlay atrás do menu (esconde o campo) ---
	_overlay = ColorRect.new()
	_overlay.color = Color(Color("010139"), 0.9)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	# --- Coluna centralizada ---
	_center = CenterContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_center)

	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	column.add_theme_constant_override("separation", 12)
	column.theme = _column_theme()
	_center.add_child(column)

	# Nível e XP, pequeno, colado no topo da tela
	_top_bar = _build_top_bar()
	add_child(_top_bar)

	# Marca do jogo (logo + título): só no menu principal
	_brand = _build_brand()
	column.add_child(_brand)

	# Título da tela atual (submenus)
	_title = _label("")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title)

	# Painéis
	_main_panel = _build_main_panel()
	_play_panel = _build_play_panel()
	_mode_panel = _build_mode_panel()
	_online_panel = _build_online_panel()
	_local_panel = _build_local_panel()
	_cpu_panel = _build_cpu_panel()
	_quick_panel = _build_quick_panel()
	_share_panel = _build_share_panel()
	column.add_child(_main_panel)
	column.add_child(_play_panel)
	column.add_child(_mode_panel)
	column.add_child(_online_panel)
	column.add_child(_local_panel)
	column.add_child(_cpu_panel)
	column.add_child(_quick_panel)
	column.add_child(_share_panel)

	# Status / mensagens (ex.: "O host desconectou")
	_status = _notice_label("")
	column.add_child(_status)
	_set_status("")

	# Card do perfil (por cima de tudo)
	_migrate_old_name()
	Net.player_name = PlayGames.player_name()
	_profile_card = _build_profile_card()
	add_child(_profile_card)
	_avatar_picker = _build_avatar_picker()
	add_child(_avatar_picker)   # por cima do card

	# Conectar a MÉTODOS (não a lambdas): o Net sobrevive ao reload da cena
	Net.status_changed.connect(_on_status_changed)
	PlayGames.name_changed.connect(_on_profile_changed)
	PlayGames.avatar_changed.connect(_on_profile_changed)
	PlayGames.stats_restored.connect(_on_stats_restored)
	Net.hosted.connect(_hide_menu)
	Net.joined.connect(_hide_menu)
	Net.quick_status.connect(_on_quick_status)
	# Monetization é autoload (sobrevive ao reload da cena); ao liberar o menu antigo a conexão cai sozinha
	Monetization.ads_removed_changed.connect(_on_ads_removed_changed)
	Monetization.store_changed.connect(_refresh_remove_ads_button)
	Monetization.purchase_busy_changed.connect(_on_purchase_busy_changed)
	Monetization.purchase_message.connect(_set_status)
	_refresh_remove_ads_button()

	_show_screen(Screen.MAIN)

	# voltou de uma partida encerrada: mostra o motivo
	if Net.last_message != "":
		_set_status(Net.last_message)
		Net.last_message = ""

	# Rodapé: espaço do banner. Na abertura do app, o loading roda primeiro e o banner entra depois dele.
	_apply_banner_space()
	_add_banner_placeholder()
	if Monetization.startup_needed():
		_run_startup()
	else:
		Monetization.set_banner_wanted("menu", true)

# ---------------------------------------------------------------- painéis

func _build_brand() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	if title_art != null:
		# Sua arte (logo + nome do jogo)
		var art := TextureRect.new()
		art.texture = title_art
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.custom_minimum_size = Vector2(0, title_art_height)
		box.add_child(art)
	else:
		# Sem arte: título em texto, sem a caixa clara dos outros labels
		var title := Label.new()
		title.text = GAME_TITLE
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		title.add_theme_font_size_override("font_size", 44)
		title.add_theme_color_override("font_color", UIStyle.TEXT_LIGHT)
		title.add_theme_color_override("font_outline_color", UIStyle.ACCENT)
		title.add_theme_constant_override("outline_size", 8)
		box.add_child(title)

	# respiro entre a marca e os botões
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	box.add_child(gap)
	return box

# Nível + barra fina + XP, em uma linha pequena no topo da tela
func _build_top_bar() -> Control:
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_theme_constant_override("margin_top", 10 + _safe_top())
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_right", 16)

	var theme := Theme.new()
	theme.default_font_size = 14
	if game_font != null:
		theme.default_font = game_font
	UIStyle.apply_outline(theme)
	theme.set_constant("outline_size", "Label", 3)
	theme.set_color("font_color", "Label", UIStyle.TEXT_LIGHT)
	theme.set_stylebox("normal", "Label", StyleBoxEmpty.new())
	root.theme = theme

	var prog := PlayGames.level_progress()
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	root.add_child(vb)
	vb.add_child(_build_profile_button())
	vb.add_child(row)

	var lvl := Label.new()
	lvl.text = "Nv %d" % PlayGames.level()
	row.add_child(lvl)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = float(prog.y)
	bar.value = float(prog.x)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(120, 8)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0, 0, 0, 0.35)
	bar_bg.set_corner_radius_all(4)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = UIStyle.ACCENT
	bar_fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bar_bg)
	bar.add_theme_stylebox_override("fill", bar_fill)
	row.add_child(bar)

	var xp_text := Label.new()
	xp_text.text = "%d/%d" % [prog.x, prog.y]
	row.add_child(xp_text)
	return root

# Recuo do topo (notch/barra de status) no Android, convertido para unidades da tela do jogo
func _safe_top() -> int:
	if OS.get_name() != "Android":
		return 0
	var safe := DisplayServer.get_display_safe_area()
	var win_h := DisplayServer.window_get_size().y
	if safe.size.y <= 0 or win_h <= 0:
		return 0
	var scale := get_viewport().get_visible_rect().size.y / float(win_h)
	return int(safe.position.y * scale)

func _build_main_panel() -> VBoxContainer:
	var p := _new_panel()
	# Ícones sutis (remover anúncios / compartilhar), acima do painel cinza do ranking
	_corner_bar = _build_corner_bar()
	p.add_child(_corner_bar)
	# Resumo do ranking online (só aparece depois da primeira partida válida)
	var record := PlayGames.profile_text()
	if record != "":
		var rec_label := _notice_label(record)   # fonte 11 + quebra automática (não estoura a coluna)
		rec_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		p.add_child(rec_label)

	p.add_child(_button("Jogar", func(): _show_screen(Screen.PLAY)))

	# Logo abaixo de "Jogar":
	#  - deslogado: botão "Entrar no Play Games"
	#  - logado: Placar e Conquistas lado a lado (e o botão de login some)
	_login_btn = _button("Entrar no Play Games", func(): PlayGames.sign_in(), UIStyle.Kind.SECONDARY)
	_shrink_button(_login_btn)
	p.add_child(_login_btn)

	_social_row = HBoxContainer.new()
	_social_row.add_theme_constant_override("separation", 12)
	var lb_btn := _button("Placar", func(): PlayGames.show_leaderboard(), UIStyle.Kind.SECONDARY)
	var ach_btn := _button("Conquistas", func(): PlayGames.show_achievements(), UIStyle.Kind.SECONDARY)
	for b in [lb_btn, ach_btn]:
		_shrink_button(b)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.x = 0
		_social_row.add_child(b)
	p.add_child(_social_row)
	if not PlayGames.sign_in_changed.is_connected(_on_sign_in_changed):
		PlayGames.sign_in_changed.connect(_on_sign_in_changed)
	_update_social_visibility()

	p.add_child(_button("Sair", _on_quit_pressed, UIStyle.Kind.GHOST))
	return p

# Primeiro passo do fluxo: escolher como jogar
func _build_play_panel() -> VBoxContainer:
	var p := _new_panel()
	p.add_child(_button("Contra a CPU", func(): _show_screen(Screen.CPU)))
	p.add_child(_button("Jogar online", func(): _show_screen(Screen.MODE), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.MAIN), UIStyle.Kind.GHOST))
	return p

# Linha de ícones no topo do painel principal, acima do painel cinza do ranking:
# remover anúncios à esquerda, compartilhar à direita.
func _build_corner_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_remove_ads_btn = _icon_button(remove_ads_icon, "Sem anúncios", _on_remove_ads_pressed, 0.0)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_share_btn = _icon_button(share_icon, "Compartilhar", func(): _show_screen(Screen.SHARE), 0.45)
	bar.add_child(_remove_ads_btn)
	bar.add_child(spacer)
	bar.add_child(_share_btn)
	return bar

# Botão discreto só com ícone: sombra + brilho pulsante atrás, e um leve "respirar" de tamanho.
func _icon_button(tex: Texture2D, fallback_text: String, callback: Callable, pulse_delay: float) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	var side := float(corner_icon_size) + 12.0
	b.custom_minimum_size = Vector2(side, side)
	b.modulate.a = corner_icon_opacity
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	if tex != null:
		b.icon = tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		b.text = fallback_text
		b.add_theme_font_size_override("font_size", 12)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
			b.add_theme_color_override(c, UIStyle.TEXT_LIGHT)
	var glow := Glow.new()
	glow.color = corner_icon_glow
	glow.show_behind_parent = true   # desenha atrás do ícone
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	b.add_child(glow)
	b.resized.connect(func(): b.pivot_offset = b.size / 2.0)   # a escala cresce a partir do centro
	b.button_down.connect(func(): b.modulate.a = 1.0)           # feedback ao tocar
	b.button_up.connect(func(): b.modulate.a = corner_icon_opacity)
	b.pressed.connect(callback)
	b.tree_entered.connect(_start_pulse.bind(b, glow, pulse_delay), CONNECT_ONE_SHOT)
	return b

func _start_pulse(b: Button, glow: Glow, delay: float) -> void:
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if not is_instance_valid(b):
		return
	var t := b.create_tween().set_loops()
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(b, "scale", Vector2.ONE * corner_icon_pulse_scale, corner_icon_pulse_seconds)
	t.parallel().tween_method(func(v: float): glow.strength = v, 0.3, 1.0, corner_icon_pulse_seconds)
	t.tween_property(b, "scale", Vector2.ONE, corner_icon_pulse_seconds)
	t.parallel().tween_method(func(v: float): glow.strength = v, 1.0, 0.3, corner_icon_pulse_seconds)

# Sombra suave (embaixo/esquerda) + halo de luz cuja força pulsa
class Glow extends Control:
	var color := Color("ffd9a0")
	var strength := 0.3:
		set(v):
			strength = v
			queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		for i in 4:   # sombra em camadas (bordas macias)
			var k := float(i) / 3.0
			draw_circle(c + Vector2(-2.0, 3.0), r * (1.0 - k * 0.15), Color(0, 0, 0, 0.10))
		for i in 6:   # halo: do maior/mais fraco ao menor/mais forte
			var k := float(i) / 5.0
			draw_circle(c, r * (1.55 - k * 0.65), Color(color, strength * (0.05 + 0.08 * k)))

# Submenu do "Jogar online": jogo rápido (fila), sala com código ou rede local
func _build_mode_panel() -> VBoxContainer:
	var p := _new_panel()
	p.add_child(_button("Jogo rápido", _on_quick_pressed))
	p.add_child(_button("Criar sala", func(): _show_screen(Screen.ONLINE), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Local", func(): _show_screen(Screen.LOCAL), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.PLAY), UIStyle.Kind.GHOST))
	return p

# Tela de busca do jogo rápido: mostra o andamento e permite cancelar
func _build_quick_panel() -> VBoxContainer:
	var p := _new_panel()
	_quick_label = _notice_label("Procurando jogador...")
	_quick_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(_quick_label)
	p.add_child(_button("Cancelar", _on_quick_cancel, UIStyle.Kind.GHOST))
	return p

# Compartilhar nas redes: abre o app/site de cada rede com o texto e o link da Play Store
func _build_share_panel() -> VBoxContainer:
	var p := _new_panel()
	p.add_child(_button("WhatsApp", func(): _share_to("https://wa.me/?text=%s" % _share_message().uri_encode())))
	p.add_child(_button("Telegram", func(): _share_to("https://t.me/share/url?url=%s&text=%s" % [_share_link().uri_encode(), SHARE_TEXT.uri_encode()]), UIStyle.Kind.SECONDARY))
	p.add_child(_button("X (Twitter)", func(): _share_to("https://twitter.com/intent/tweet?text=%s" % _share_message().uri_encode()), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Facebook", func(): _share_to("https://www.facebook.com/sharer/sharer.php?u=%s" % _share_link().uri_encode()), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Copiar link", _on_copy_link_pressed, UIStyle.Kind.SECONDARY))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.MAIN), UIStyle.Kind.GHOST))
	return p

func _share_link() -> String:
	return "https://play.google.com/store/apps/details?id=" + RatePrompt.PACKAGE_NAME

func _share_message() -> String:
	return SHARE_TEXT + " " + _share_link()

func _share_to(url: String) -> void:
	OS.shell_open(url)

func _on_copy_link_pressed() -> void:
	DisplayServer.clipboard_set(_share_link())
	_set_status("Link copiado!")

func _build_online_panel() -> VBoxContainer:
	var p := _new_panel()
	_code = LineEdit.new()
	_code.placeholder_text = "Código da sala (ex: ABC123)"
	_code.max_length = 12
	UIStyle.style_field(_code)
	p.add_child(_code)
	p.add_child(_button("Criar sala", _on_create_pressed))
	p.add_child(_button("Entrar na sala", _on_enter_pressed, UIStyle.Kind.SECONDARY))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.MODE), UIStyle.Kind.GHOST))
	return p

func _build_cpu_panel() -> VBoxContainer:
	var p := _new_panel()
	var level_label := _label("Dificuldade")
	level_label.custom_minimum_size.y = REGION_LABEL_H
	level_label.add_theme_font_size_override("font_size", REGION_FONT_SIZE)
	p.add_child(level_label)
	_level = OptionButton.new()
	UIStyle.style_field(_level)
	for n in ["Fácil", "Normal", "Difícil"]:
		_level.add_item(n)
	_level.selected = _load_level()
	p.add_child(_level)
	p.add_child(_button("Começar", _on_cpu_start_pressed))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.PLAY), UIStyle.Kind.GHOST))
	return p

func _build_local_panel() -> VBoxContainer:
	var p := _new_panel()
	var my_ip := _label("Seu IP: " + _get_local_ip())
	p.add_child(my_ip)
	_ip = LineEdit.new()
	_ip.placeholder_text = "IP do host"
	UIStyle.style_field(_ip)
	p.add_child(_ip)
	p.add_child(_button("Hospedar", _on_host_pressed))
	p.add_child(_button("Entrar", _on_join_pressed, UIStyle.Kind.SECONDARY))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.MODE), UIStyle.Kind.GHOST))
	return p

func _new_panel() -> VBoxContainer:
	var p := VBoxContainer.new()
	p.add_theme_constant_override("separation", 12)
	return p

# Label com a altura padrão (o fundo em degradê vem do theme da coluna)
func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	UIStyle.style_label(l)
	return l

# Label de aviso: fonte 11 + quebra de linha automática na largura da coluna
func _notice_label(text: String) -> Label:
	var l := _label(text)
	l.add_theme_font_size_override("font_size", NOTICE_FONT_SIZE)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = COLUMN_WIDTH
	return l

func _button(text: String, callback: Callable, kind: UIStyle.Kind = UIStyle.Kind.PRIMARY) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, BTN_HEIGHT)
	b.pressed.connect(callback)
	UIStyle.style_button(b, kind)
	return b

# Versão menor do botão (altura e fonte reduzidas)
func _shrink_button(b: Button) -> void:
	b.custom_minimum_size.y = SMALL_BTN_HEIGHT
	b.add_theme_font_size_override("font_size", SMALL_BTN_FONT)

# ---------------------------------------------------------------- navegação

func _show_screen(s: Screen) -> void:
	_main_panel.visible = s == Screen.MAIN
	_play_panel.visible = s == Screen.PLAY
	_mode_panel.visible = s == Screen.MODE
	_brand.visible = s == Screen.MAIN
	_top_bar.visible = s == Screen.MAIN
	_title.visible = s != Screen.MAIN
	_online_panel.visible = s == Screen.ONLINE
	_local_panel.visible = s == Screen.LOCAL
	_cpu_panel.visible = s == Screen.CPU
	_quick_panel.visible = s == Screen.QUICK
	_share_panel.visible = s == Screen.SHARE
	match s:
		Screen.MAIN: _title.text = ""
		Screen.PLAY: _title.text = "Jogar"
		Screen.MODE:
			_title.text = "Jogar online"
			Net.prefetch_ice()   # já busca as credenciais TURN enquanto o jogador escolhe
		Screen.ONLINE: _title.text = "Criar sala"
		Screen.QUICK: _title.text = "Jogo rápido"
		Screen.CPU: _title.text = "Contra a CPU"
		Screen.LOCAL: _title.text = "Local"
		Screen.SHARE: _title.text = "Compartilhar"
	_update_social_visibility()   # corrige se o aviso de login chegou antes/depois do menu
	_set_status("")

func _set_status(t: String) -> void:
	_status.text = t
	_status.visible = t != ""

func _hide_menu() -> void:
	Monetization.set_banner_wanted("menu", false)   # com a partida rolando não há banner
	if _banner_placeholder != null:
		_banner_placeholder.visible = false
	_profile_card.visible = false
	_center.visible = false
	_overlay.visible = false
	_top_bar.visible = false

# ---------------------------------------------------------------- ações

func _on_cpu_start_pressed() -> void:
	_apply_settings()
	Net.start_cpu(_level.selected)

func _on_quick_pressed() -> void:
	_apply_settings()
	_set_status("")
	_quick_label.text = "Procurando jogador..."
	_show_screen(Screen.QUICK)
	Net.quick_match()

func _on_quick_cancel() -> void:
	Net.leave()   # cancela a busca e limpa a sala/fila
	_show_screen(Screen.MODE)

func _on_quick_status(t: String) -> void:
	if _quick_label != null:
		_quick_label.text = t

func _on_create_pressed() -> void:
	_apply_settings()
	Net.host_room(_code.text)

func _on_enter_pressed() -> void:
	_apply_settings()
	Net.join_room(_code.text)

func _on_host_pressed() -> void:
	_apply_settings()
	Net.host()

func _on_join_pressed() -> void:
	_apply_settings()
	var ip := _ip.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"   # campo vazio = testar na mesma máquina
	Net.join(ip)

func _on_sign_in_changed(_signed_in: bool) -> void:
	_update_social_visibility()

# Logado: Placar/Conquistas. Deslogado: botão de entrar (só no Android, onde o Play Games existe).
func _update_social_visibility() -> void:
	if _social_row != null:
		_social_row.visible = PlayGames.signed_in
	if _login_btn != null:
		_login_btn.visible = OS.get_name() == "Android" and not PlayGames.signed_in

func _on_status_changed(t: String) -> void:
	if _quick_panel != null and _quick_panel.visible:
		return   # durante a busca, quem fala é o jogo rápido (quick_status)
	_set_status(t)

# ---------------------------------------------------------------- rodapé (banner) e loading da abertura

# Deixa livre, no rodapé, o espaço do banner (que é uma view nativa por cima do jogo)
func _apply_banner_space() -> void:
	_center.offset_bottom = -Monetization.banner_reserved_height(get_viewport())

# Só no editor/PC (debug): faixa clara para você enxergar onde o banner vai ficar
func _add_banner_placeholder() -> void:
	if OS.get_name() == "Android" or not OS.is_debug_build() or not Monetization.banner_enabled():
		return
	var h := Monetization.banner_reserved_height(get_viewport())
	_banner_placeholder = ColorRect.new()
	_banner_placeholder.color = Color(1, 1, 1, 0.12)
	_banner_placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_placeholder.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_banner_placeholder.offset_top = -h
	_banner_placeholder.offset_bottom = 0
	add_child(_banner_placeholder)
	var tag := Label.new()
	tag.text = "espaço do banner (só aparece no editor)"
	tag.add_theme_font_size_override("font_size", 10)
	tag.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	tag.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_placeholder.add_child(tag)

# Loading da abertura do app: cobre tudo enquanto o anúncio de abertura carrega, depois some com um fade
func _run_startup() -> void:
	_loading_layer = CanvasLayer.new()
	_loading_layer.layer = 100   # acima do menu, do cabeçalho e dos pop-ups
	add_child(_loading_layer)
	_loading_root = _build_loading_screen()
	_loading_layer.add_child(_loading_root)
	await Monetization.run_startup()
	if _loading_tween != null:
		_loading_tween.kill()
	var fade := create_tween()
	fade.tween_property(_loading_root, "modulate:a", 0.0, LOADING_FADE_SECONDS)
	await fade.finished
	_loading_layer.queue_free()
	_loading_layer = null
	GameAudio.ensure(get_tree())   # a música só começa depois do loading/anúncio
	if _center.visible:
		Monetization.set_banner_wanted("menu", true)

func _build_loading_screen() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP   # ninguém toca no menu por baixo

	var bg := ColorRect.new()
	bg.color = Color("010139")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	box.add_theme_constant_override("separation", 20)
	center.add_child(box)
	box.add_child(_build_brand())   # a mesma marca (arte ou título) do menu

	_loading_label = Label.new()
	_loading_label.text = "Carregando"
	_loading_label.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_loading_label.add_theme_font_size_override("font_size", 16)
	_loading_label.add_theme_color_override("font_color", UIStyle.TEXT_LIGHT)
	box.add_child(_loading_label)

	_loading_tween = create_tween().set_loops()
	for t in ["Carregando", "Carregando.", "Carregando..", "Carregando..."]:
		_loading_tween.tween_callback(_loading_label.set_text.bind(t))
		_loading_tween.tween_interval(0.35)
	return root

func _on_remove_ads_pressed() -> void:
	Monetization.buy_remove_ads()

func _on_ads_removed_changed(_removed: bool) -> void:
	_refresh_remove_ads_button()
	_apply_banner_space()

func _on_purchase_busy_changed(_busy: bool) -> void:
	_refresh_remove_ads_button()

func _refresh_remove_ads_button() -> void:
	if _remove_ads_btn == null:
		return
	_remove_ads_btn.visible = Monetization.can_offer_remove_ads()
	_remove_ads_btn.disabled = Monetization.purchase_busy
	_remove_ads_btn.tooltip_text = "Remover anúncios" \
			+ ((" · " + Monetization.remove_ads_price) if Monetization.remove_ads_price != "" else "")

func _on_quit_pressed() -> void:
	Net.leave()          # garante que nenhuma sala ou conexão fique aberta
	get_tree().quit()

# ---------------------------------------------------------------- perfil (avatar + nome)

# Tema da coluna do menu (texto escuro em caixa clara); o card do perfil usa o mesmo
func _column_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 18
	if game_font != null:
		theme.default_font = game_font
	UIStyle.apply_outline(theme)
	theme.set_color("font_color", "Label", UIStyle.TEXT_DARK)
	theme.set_stylebox("normal", "Label", UIStyle.label_box())
	return theme

# Botão no topo (acima da barra de XP): avatar + nome. Toque abre o card do perfil.
func _build_profile_button() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.custom_minimum_size = Vector2(180, 44)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(1, 1, 1, 0.18)
	hover.set_corner_radius_all(22)
	var pressed := StyleBoxFlat.new()
	pressed.bg_color = Color(0, 0, 0, 0.25)
	pressed.set_corner_radius_all(22)
	b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.pressed.connect(_open_profile_card)

	var inner := HBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_theme_constant_override("separation", 8)
	b.add_child(inner)
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_top_avatar = UIStyle.Avatar.new(36)
	inner.add_child(_top_avatar)
	_top_name = Label.new()
	_top_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_top_name.add_theme_font_size_override("font_size", 16)
	_top_name.clip_text = true
	_top_name.custom_minimum_size.x = 100
	inner.add_child(_top_name)
	_refresh_profile_button()
	return b

func _refresh_profile_button() -> void:
	if _top_avatar == null:
		return
	_top_avatar.texture = UIStyle.my_avatar
	var n := PlayGames.player_name()
	_top_name.text = n if n != "" else "Você"

# Card para trocar nome e foto
func _build_profile_card() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	col.add_theme_constant_override("separation", 12)
	col.theme = _column_theme()
	center.add_child(col)

	var title := _label("Seu perfil")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	_card_avatar = UIStyle.Avatar.new(96)
	_card_avatar.ring_width = 3.0
	col.add_child(_card_avatar)
	col.add_child(_button("Escolher avatar", _open_avatar_picker, UIStyle.Kind.SECONDARY))

	col.add_child(_label("Seu nome"))
	_card_name = LineEdit.new()
	_card_name.placeholder_text = "Você"
	_card_name.max_length = PlayGames.NAME_MAX
	UIStyle.style_field(_card_name)
	col.add_child(_card_name)

	_card_msg = _notice_label("")
	_card_msg.visible = false
	col.add_child(_card_msg)

	col.add_child(_button("Salvar", _on_profile_save_pressed))
	_card_reset = _button("Restaurar padrão", _on_profile_reset_pressed, UIStyle.Kind.SECONDARY)
	col.add_child(_card_reset)
	col.add_child(_button("Voltar", _close_profile_card, UIStyle.Kind.GHOST))
	return root

func _open_profile_card() -> void:
	_card_avatar.texture = UIStyle.my_avatar
	_card_name.text = PlayGames.player_name()
	_card_msg.visible = false
	_card_reset.visible = PlayGames.has_custom_profile()
	_profile_card.visible = true

func _close_profile_card() -> void:
	_profile_card.visible = false

func _on_profile_save_pressed() -> void:
	var n := _card_name.text.strip_edges()
	PlayGames.set_custom_name("" if n == PlayGames.my_name else n)   # igual ao do Google = sem personalizar
	_close_profile_card()

func _on_profile_reset_pressed() -> void:
	PlayGames.reset_profile()   # volta ao nome e à foto do Google (ou ao padrão)
	_open_profile_card()

func _on_change_photo_pressed() -> void:
	if _file_dialog == null:
		_file_dialog = FileDialog.new()
		_file_dialog.title = "Escolha sua foto"
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.use_native_dialog = true   # seletor do sistema (Android/desktop)
		_file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Imagens"])
		_file_dialog.file_selected.connect(_on_photo_picked)
		add_child(_file_dialog)
	_file_dialog.popup_centered_ratio(0.9)

# Grade com os avatares do jogo + opção de usar uma foto da galeria
func _build_avatar_picker() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	col.add_theme_constant_override("separation", 12)
	col.theme = _column_theme()
	center.add_child(col)

	var title := _label("Escolha seu avatar")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(grid)
	for i in AvatarArt.COUNT:
		grid.add_child(_avatar_choice(i))

	col.add_child(_button("Foto da galeria", _on_change_photo_pressed, UIStyle.Kind.SECONDARY))
	col.add_child(_button("Voltar", _close_avatar_picker, UIStyle.Kind.GHOST))
	return root

# Um botão redondo da grade (o Avatar desenha a miniatura; o clique é do botão)
func _avatar_choice(index: int) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(66, 66)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(1, 1, 1, 0.18)
	hover.set_corner_radius_all(33)
	var pressed := StyleBoxFlat.new()
	pressed.bg_color = Color(0, 0, 0, 0.25)
	pressed.set_corner_radius_all(33)
	b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	var cc := CenterContainer.new()
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var av := UIStyle.Avatar.new(58)
	av.texture = AvatarArt.texture(index)
	cc.add_child(av)
	b.pressed.connect(_on_avatar_chosen.bind(index))
	return b

func _open_avatar_picker() -> void:
	_avatar_picker.visible = true

func _close_avatar_picker() -> void:
	_avatar_picker.visible = false

func _on_avatar_chosen(index: int) -> void:
	PlayGames.set_preset_avatar(index)
	_card_avatar.texture = UIStyle.my_avatar
	_card_msg.visible = false
	_card_reset.visible = true
	_close_avatar_picker()

func _on_photo_picked(path: String) -> void:
	if PlayGames.set_custom_avatar_from_file(path):
		_close_avatar_picker()
		_card_msg.visible = false
		_card_avatar.texture = UIStyle.my_avatar
		_card_reset.visible = true
	else:
		_card_msg.text = "Não consegui abrir essa imagem. Tente uma foto PNG, JPG ou WEBP."
		_card_msg.visible = true

# XP voltou da nuvem (app reinstalado): refaz a barra de nível do topo
func _on_stats_restored() -> void:
	if _top_bar == null or not is_instance_valid(_top_bar):
		return
	var was_visible := _top_bar.visible
	var idx := _top_bar.get_index()
	_top_bar.queue_free()
	_top_bar = _build_top_bar()
	_top_bar.visible = was_visible
	add_child(_top_bar)
	move_child(_top_bar, idx)

# Nome, foto ou nome do Google mudaram: atualiza o botão do topo e o nome usado nas partidas
func _on_profile_changed() -> void:
	Net.player_name = PlayGames.player_name()
	_refresh_profile_button()
	if _profile_card != null and _profile_card.visible:
		_card_avatar.texture = UIStyle.my_avatar

# Quem digitava o nome no campo antigo não perde o nome: vira o nome personalizado (uma vez)
func _migrate_old_name() -> void:
	var old := _load_name().strip_edges()
	if old == "":
		return
	if PlayGames.custom_name == "":
		PlayGames.set_custom_name(old)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		cfg.set_value("player", "name", "")
		cfg.save(SETTINGS_PATH)

# ---------------------------------------------------------------- nome (legado)

# Lê os campos, guarda no Net e salva no aparelho
func _apply_settings() -> void:
	Net.player_name = PlayGames.player_name()   # escolhido no card > Play Games > vazio ("Você")
	var cfg := ConfigFile.new()
	cfg.set_value("cpu", "level", _level.selected)
	cfg.save(SETTINGS_PATH)

func _load_level() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return 1   # Normal
	return clampi(int(cfg.get_value("cpu", "level", 1)), 0, 2)

func _load_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return ""
	return cfg.get_value("player", "name", "")

# ---------------------------------------------------------------- IP local

# Devolve o IPv4 da rede local (Wi-Fi/LAN), preferindo 192.168.x.x
func _get_local_ip() -> String:
	var fallback := ""
	for addr in IP.get_local_addresses():
		if addr.contains(":") or addr.begins_with("127.") or addr.begins_with("169.254."):
			continue   # ignora IPv6, loopback e link-local
		if addr.begins_with("192.168."):
			return addr
		if fallback == "" and (addr.begins_with("10.") or _is_172_private(addr)):
			fallback = addr
	return fallback if fallback != "" else "não encontrado"

func _is_172_private(addr: String) -> bool:
	if not addr.begins_with("172."):
		return false
	var second := addr.split(".")[1].to_int()
	return second >= 16 and second <= 31

func _inicializar_admob() -> void:
	# 1. Cria o listener que vai avisar quando o AdMob estiver pronto
	var on_init_listener := OnInitializationCompleteListener.new()
	on_init_listener.on_initialization_complete = _on_admob_pronto

	# 2. Configurações básicas (Opcional - igual ao exemplo da Poing)
	var request_config := RequestConfiguration.new()
	request_config.tag_for_child_directed_treatment = RequestConfiguration.TagForChildDirectedTreatment.TRUE
	request_config.max_ad_content_rating = RequestConfiguration.MAX_AD_CONTENT_RATING_G
	MobileAds.set_request_configuration(request_config)

	# 3. Manda o AdMob inicializar de verdade
	print("AirHockey: Chamando a inicialização do MobileAds...")
	MobileAds.initialize(on_init_listener)

func _on_admob_pronto(status: InitializationStatus) -> void:
	print("AirHockey: AdMob inicializado com sucesso!")
	# Aqui você já pode liberar o carregamento dos seus banners ou anúncios recebidos
