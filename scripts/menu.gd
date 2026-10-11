extends CanvasLayer

enum Screen { MAIN, MODE, ONLINE, CPU, LOCAL, QUICK, SHARE }

# Texto usado só se nenhuma arte for definida em title_art
const GAME_TITLE := "AIR HOCKEY"

const SETTINGS_PATH := "user://settings.cfg"
const BTN_HEIGHT := 52
const COLUMN_WIDTH := 300
const SHARE_TEXT := "Venha jogar Air Hockey comigo!"   # texto enviado ao compartilhar
const NOTICE_FONT_SIZE := 11   # tamanho da fonte dos avisos do menu

# --- Personalização (arraste os arquivos no Inspector, no nó do menu) ---
@export var game_font: Font                 # fonte padrão do jogo todo
@export var header_number_font: Font        # fonte dos NÚMEROS do placar no header (vazio = game_font)
@export var header_number_size := 22        # tamanho dessa fonte
@export var info_font: Font                 # fonte do aviso "toque na sua foto..." e dos dados de rede (ping)
@export var title_art: Texture2D            # sua arte com logo + nome (substitui o texto do topo)
@export var title_art_height := 160         # altura máxima da arte no menu, em pixels

var _overlay: ColorRect
var _center: CenterContainer
var _title: Label
var _brand: VBoxContainer
var _top_bar: Control   # nível/XP no topo (só no menu principal)
var _social_row: HBoxContainer
var _top_avatar: UIStyle.Avatar   # avatar do botão de perfil (topo)
var _top_name: Label
var _profile_card: Control
var _card_avatar: UIStyle.Avatar
var _card_name: LineEdit
var _card_msg: Label
var _card_reset: Button
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
var _region: OptionButton

func _ready() -> void:
	GameAudio.ensure(get_tree())   # música tema começa já no menu
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
	_mode_panel = _build_mode_panel()
	_online_panel = _build_online_panel()
	_local_panel = _build_local_panel()
	_cpu_panel = _build_cpu_panel()
	_quick_panel = _build_quick_panel()
	_share_panel = _build_share_panel()
	column.add_child(_main_panel)
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

	# Conectar a MÉTODOS (não a lambdas): o Net sobrevive ao reload da cena
	Net.status_changed.connect(_on_status_changed)
	PlayGames.name_changed.connect(_on_profile_changed)
	PlayGames.avatar_changed.connect(_on_profile_changed)
	Net.hosted.connect(_hide_menu)
	Net.joined.connect(_hide_menu)
	Net.quick_status.connect(_on_quick_status)

	_show_screen(Screen.MAIN)

	# voltou de uma partida encerrada: mostra o motivo
	if Net.last_message != "":
		_set_status(Net.last_message)
		Net.last_message = ""

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
	# Resumo do ranking online (só aparece depois da primeira partida válida)
	var record := PlayGames.profile_text()
	if record != "":
		var rec_label := _label(record)
		rec_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		p.add_child(rec_label)
	p.add_child(_button("Jogar contra CPU", func(): _show_screen(Screen.CPU)))
	p.add_child(_button("Jogar online", func(): _show_screen(Screen.MODE)))

	# Placar e Conquistas lado a lado (só com login no Play Games)
	_social_row = HBoxContainer.new()
	_social_row.add_theme_constant_override("separation", 12)
	var lb_btn := _button("Placar", func(): PlayGames.show_leaderboard(), UIStyle.Kind.SECONDARY)
	var ach_btn := _button("Conquistas", func(): PlayGames.show_achievements(), UIStyle.Kind.SECONDARY)
	for b in [lb_btn, ach_btn]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.x = 0
		_social_row.add_child(b)
	_social_row.visible = PlayGames.signed_in
	PlayGames.sign_in_changed.connect(_on_sign_in_changed)
	p.add_child(_social_row)

	p.add_child(_button("Compartilhar", func(): _show_screen(Screen.SHARE), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Sair", _on_quit_pressed, UIStyle.Kind.GHOST))
	return p

# Submenu do "Jogar online": jogo rápido (fila), sala com código ou rede local
func _build_mode_panel() -> VBoxContainer:
	var p := _new_panel()
	p.add_child(_button("Jogo rápido", _on_quick_pressed))
	p.add_child(_button("Criar sala", func(): _show_screen(Screen.ONLINE), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Local", func(): _show_screen(Screen.LOCAL), UIStyle.Kind.SECONDARY))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.MAIN), UIStyle.Kind.GHOST))
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
	var region_label := _label("Servidor")
	p.add_child(region_label)
	_region = OptionButton.new()
	UIStyle.style_field(_region)
	for r in Net.TURN_REGIONS:
		_region.add_item(r[0])
	_region.selected = _load_region_index()
	p.add_child(_region)
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
	p.add_child(level_label)
	_level = OptionButton.new()
	UIStyle.style_field(_level)
	for n in ["Fácil", "Normal", "Difícil"]:
		_level.add_item(n)
	_level.selected = _load_level()
	p.add_child(_level)
	p.add_child(_button("Começar", _on_cpu_start_pressed))
	p.add_child(_button("Voltar", func(): _show_screen(Screen.MAIN), UIStyle.Kind.GHOST))
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

# ---------------------------------------------------------------- navegação

func _show_screen(s: Screen) -> void:
	_main_panel.visible = s == Screen.MAIN
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
		Screen.MODE: _title.text = "Jogar online"
		Screen.ONLINE: _title.text = "Criar sala"
		Screen.QUICK: _title.text = "Jogo rápido"
		Screen.CPU: _title.text = "Contra a CPU"
		Screen.LOCAL: _title.text = "Local"
		Screen.SHARE: _title.text = "Compartilhar"
	_set_status("")

func _set_status(t: String) -> void:
	_status.text = t
	_status.visible = t != ""

func _hide_menu() -> void:
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

func _on_sign_in_changed(signed_in: bool) -> void:
	_social_row.visible = signed_in

func _on_status_changed(t: String) -> void:
	if _quick_panel != null and _quick_panel.visible:
		return   # durante a busca, quem fala é o jogo rápido (quick_status)
	_set_status(t)

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
	col.add_child(_button("Trocar foto", _on_change_photo_pressed, UIStyle.Kind.SECONDARY))

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

func _on_photo_picked(path: String) -> void:
	if PlayGames.set_custom_avatar_from_file(path):
		_card_msg.visible = false
		_card_avatar.texture = UIStyle.my_avatar
		_card_reset.visible = true
	else:
		_card_msg.text = "Não consegui abrir essa imagem. Tente uma foto PNG, JPG ou WEBP."
		_card_msg.visible = true

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
	Net.turn_host = Net.TURN_REGIONS[_region.selected][1]
	var cfg := ConfigFile.new()
	cfg.set_value("net", "turn_host", Net.turn_host)
	cfg.set_value("cpu", "level", _level.selected)
	cfg.save(SETTINGS_PATH)

# Região salva; se não houver, a primeira da lista (América do Sul)
func _load_region_index() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return 0
	var saved: String = cfg.get_value("net", "turn_host", "")
	for i in Net.TURN_REGIONS.size():
		if Net.TURN_REGIONS[i][1] == saved:
			return i
	return 0

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
