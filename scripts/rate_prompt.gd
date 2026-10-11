class_name RatePrompt
extends CanvasLayer
## Pop-up "Está gostando do jogo? Avalie com 5 estrelas" que leva à Google Play.
## Não precisa de autoload: o main.gd cria o nó e chama show_prompt() no fim da partida.
##
## Regras (ajuste nas constantes):
##  - só aparece depois de MIN_PLAY_SECONDS de partida jogada (tempo acumulado, salvo no aparelho);
##  - "Agora não" pergunta de novo só depois de mais REMIND_AFTER_SECONDS jogados;
##  - pergunta no máximo MAX_ASKS vezes; se a pessoa tocar em avaliar, nunca mais pergunta.

signal closed

const PACKAGE_NAME := "com.godotengine.airhockey"   # <- TROQUE pelo package name do seu app (Export > Android)
const MIN_PLAY_SECONDS := 300.0       # 5 minutos jogados até a primeira pergunta
const REMIND_AFTER_SECONDS := 900.0   # "Agora não": volta a perguntar após mais 15 min
const MAX_ASKS := 3
const PATH := "user://rating.cfg"

var _root: Control

# ------------------------------------------------------------ controle (estático)

static func _load() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(PATH)   # se não existir, fica vazio
	return cfg

static func _played(cfg: ConfigFile) -> float:
	return float(cfg.get_value("rating", "play_seconds", 0.0))

## Soma tempo de partida jogada (chamado pelo main.gd).
static func add_play_time(seconds: float) -> void:
	if seconds <= 0.0:
		return
	var cfg := _load()
	cfg.set_value("rating", "play_seconds", _played(cfg) + seconds)
	cfg.save(PATH)

## Já é hora de perguntar?
static func should_ask() -> bool:
	var cfg := _load()
	if bool(cfg.get_value("rating", "done", false)):
		return false
	if int(cfg.get_value("rating", "asks", 0)) >= MAX_ASKS:
		return false
	return _played(cfg) >= float(cfg.get_value("rating", "next_at", MIN_PLAY_SECONDS))

# ------------------------------------------------------------ pop-up

func is_open() -> bool:
	return _root != null and _root.visible

func show_prompt() -> void:
	if _root == null:
		_build()
	_root.theme = UIStyle.make_theme()   # fonte do jogo (já definida pelo menu a esta altura)
	_root.visible = true
	# conta a pergunta já ao mostrar (se o app fechar com o pop-up aberto, não insiste na hora)
	var cfg := _load()
	cfg.set_value("rating", "asks", int(cfg.get_value("rating", "asks", 0)) + 1)
	cfg.set_value("rating", "next_at", _played(cfg) + REMIND_AFTER_SECONDS)
	cfg.save(PATH)

func _build() -> void:
	layer = 20   # acima de tudo (menus e fim de partida ficam no layer 1)
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(290, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	box.add_child(_label("Está gostando do jogo?", 22, Vector2(290, 56)))
	box.add_child(_label("Avalie com 5 estrelas na Google Play e ajude o jogo a crescer!", 15, Vector2(290, 64)))

	var stars := Stars.new()
	stars.tapped.connect(_on_rate)
	box.add_child(stars)

	box.add_child(_button("Avaliar", _on_rate, UIStyle.Kind.PRIMARY))
	box.add_child(_button("Agora não", _on_later, UIStyle.Kind.GHOST))

func _label(text: String, font_size: int, min_size: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = min_size
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", UIStyle.TEXT_DARK)
	l.add_theme_stylebox_override("normal", UIStyle.label_box())
	return l

func _button(text: String, callback: Callable, kind: UIStyle.Kind) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 52)
	b.pressed.connect(callback)
	UIStyle.style_button(b, kind)
	return b

func _on_rate() -> void:
	var cfg := _load()
	cfg.set_value("rating", "done", true)   # nunca mais pergunta
	cfg.save(PATH)
	_close()
	var url := "https://play.google.com/store/apps/details?id=" + PACKAGE_NAME
	if OS.get_name() == "Android":
		url = "market://details?id=" + PACKAGE_NAME   # abre direto no app da Play Store
	OS.shell_open(url)

func _on_later() -> void:
	_close()

func _close() -> void:
	_root.visible = false
	closed.emit()

# Fileira de 5 estrelas douradas; tocar em qualquer uma leva à loja
class Stars extends Control:
	signal tapped
	const STAR := 40.0
	const GAP := 8.0

	func _init() -> void:
		custom_minimum_size = Vector2(5.0 * STAR + 4.0 * GAP, STAR + 4.0)
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _draw() -> void:
		for i in 5:
			_star(Vector2(STAR * 0.5 + i * (STAR + GAP), STAR * 0.5 + 2.0), STAR * 0.5)

	func _star(c: Vector2, r: float) -> void:
		var pts := PackedVector2Array()
		for k in 10:
			var a := -PI / 2.0 + k * PI / 5.0
			var rad := r if k % 2 == 0 else r * 0.45
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
		draw_colored_polygon(pts, Color("ffc933"))
		var outline := pts.duplicate()
		outline.append(pts[0])
		draw_polyline(outline, Color.BLACK, 2.0, true)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			tapped.emit()
