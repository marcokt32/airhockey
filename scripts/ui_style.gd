class_name UIStyle
extends RefCounted

const TEXT_DARK := Color("010139")

# --- Labels / cabeçalho: degradê bege (topo) -> bege escuro (base) ---
const LABEL_TOP := Color("e8e7e5ff")
const LABEL_BOTTOM := Color("797e7cff")       # <- ajuste aqui o "escuro" do degradê
const LABEL_CUT := 12.0                     # corte a 45° dos cantos, em pixels
const LABEL_SHADOW := Color(0, 0, 0, 0.5)
const LABEL_SHADOW_OFFSET := 3.0            # sombra para baixo e para a esquerda

# --- Altura padrão de labels e campos de entrada (LineEdit, OptionButton) ---
const FIELD_H := 44

# --- Contorno preto da fonte ---
const OUTLINE_COLOR := Color.BLACK
const OUTLINE_SIZE_TEXT := 2      # Label, LineEdit, OptionButton (texto escuro)
const OUTLINE_SIZE_BUTTON := 3    # Button (texto claro)

# --- Paleta dos botões (azul-noite #010139 + laranja #bf6801) ---
const ACCENT := Color("bf6801")        # laranja (ação principal)
const TEXT_LIGHT := Color("fff3e3")    # branco quente

enum Kind { PRIMARY, SECONDARY, GHOST }

# Fonte padrão do jogo: definida no export do menu.gd (fica nula se não houver)
static var game_font: Font
# Fonte dos números do placar (header): export do menu.gd. Nula = usa game_font
static var number_font: Font
static var number_size := 22
# Fonte do aviso "toque na sua foto" e dos dados de rede (ping/diagnóstico): export do menu.gd.
# Nula = usa a fonte padrão do jogo
static var info_font: Font

# Avatares: nulos = foto genérica. Quando a foto do Play Games estiver disponível
# (ou a do rival chegar pela rede), basta atribuir um Texture2D aqui.
static var my_avatar: Texture2D
static var rival_avatar: Texture2D

# Menu/diálogo abertos: o taco ignora toques enquanto isto for true (player.gd)
static var ui_blocking := false
# Altura do cabeçalho: toques nessa faixa não movem o taco (definido pelo main.gd)
static var hud_top := 0.0

# Theme com a fonte do jogo, para aplicar em qualquer Control/CanvasLayer
static func make_theme() -> Theme:
	var t := Theme.new()
	if game_font:
		t.default_font = game_font
	apply_outline(t)
	return t

# Contorno preto em todo texto de Label, Button, LineEdit e OptionButton
static func apply_outline(t: Theme) -> void:
	var sizes := {
		"Label": OUTLINE_SIZE_TEXT,
		"LineEdit": OUTLINE_SIZE_TEXT,
		"OptionButton": OUTLINE_SIZE_TEXT,
		"Button": OUTLINE_SIZE_BUTTON,
	}
	for type in sizes:
		t.set_color("font_outline_color", type, OUTLINE_COLOR)
		t.set_constant("outline_size", type, sizes[type])

# Fundo de label: degradê, cantos cortados, sombra. cut menor p/ controles pequenos
static func label_box(cut: float = LABEL_CUT) -> GradientBox:
	var sb := GradientBox.new()
	sb.top = LABEL_TOP
	sb.bottom = LABEL_BOTTOM
	sb.cut = cut
	sb.shadow_color = LABEL_SHADOW
	sb.shadow_offset = LABEL_SHADOW_OFFSET
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

# Faixa do cabeçalho (placar): mesmo estilo dos labels
static func header_box() -> GradientBox:
	return label_box()

# Altura padrão + texto centralizado verticalmente
static func style_label(l: Label) -> void:
	l.custom_minimum_size.y = FIELD_H
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

# Altura padrão para LineEdit / OptionButton
static func style_field(c: Control) -> void:
	c.custom_minimum_size.y = FIELD_H

# Caixa com degradê vertical, cantos cortados a 45° (inferior esquerdo e
# superior direito, igual aos botões) e sombra deslocada p/ baixo e esquerda.
class GradientBox extends StyleBox:
	var top := Color.WHITE
	var bottom := Color.BLACK
	var cut := 12.0
	var shadow_color := Color(0, 0, 0, 0.5)
	var shadow_offset := 3.0

	func _shape(rect: Rect2, c: float, off: Vector2) -> PackedVector2Array:
		var x := rect.position.x + off.x
		var y := rect.position.y + off.y
		var w := rect.size.x
		var h := rect.size.y
		return PackedVector2Array([
			Vector2(x, y), Vector2(x + w - c, y),
			Vector2(x + w, y + c), Vector2(x + w, y + h),
			Vector2(x + c, y + h), Vector2(x, y + h - c),
		])

	func _draw(to_canvas_item: RID, rect: Rect2) -> void:
		var c := minf(cut, minf(rect.size.x, rect.size.y) * 0.5)
		if shadow_offset > 0.0:
			RenderingServer.canvas_item_add_polygon(
				to_canvas_item,
				_shape(rect, c, Vector2(-shadow_offset, shadow_offset)),
				PackedColorArray([shadow_color]))
		var pts := _shape(rect, c, Vector2.ZERO)
		var cols := PackedColorArray()
		for p in pts:
			var t := clampf((p.y - rect.position.y) / maxf(rect.size.y, 1.0), 0.0, 1.0)
			cols.append(top.lerp(bottom, t))
		RenderingServer.canvas_item_add_polygon(to_canvas_item, pts, cols)

# Foto redonda com contorno. Sem textura, desenha um avatar genérico (silhueta).
class Avatar extends Control:
	var texture: Texture2D:
		set(value):
			texture = value
			queue_redraw()
	var ring_color := Color.BLACK
	var ring_width := 2.0
	var bg_color := Color("4a5f8a")
	var fg_color := Color("c9d3e6")

	func _init(px: float = 32.0) -> void:
		custom_minimum_size = Vector2(px, px)
		mouse_filter = Control.MOUSE_FILTER_IGNORE   # o clique vai para o botão pai
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _circle(center: Vector2, rad: float, n: int = 40) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in n:
			var a := TAU * float(i) / float(n)
			pts.append(center + Vector2(cos(a), sin(a)) * rad)
		return pts

	func _draw() -> void:
		var r := minf(size.x, size.y) * 0.5
		var c := size * 0.5
		var disc := _circle(c, r - ring_width * 0.5)
		if texture != null:
			# recorta a foto em círculo: mapeia cada ponto do círculo para a UV da textura
			var uvs := PackedVector2Array()
			for p in disc:
				uvs.append((p - (c - Vector2(r, r))) / (r * 2.0))
			draw_colored_polygon(disc, Color.WHITE, uvs, texture)
		else:
			draw_colored_polygon(disc, bg_color)
			draw_circle(c + Vector2(0, -r * 0.2), r * 0.32, fg_color)         # cabeça
			var body := PackedVector2Array()                                    # ombros
			for i in 32:
				var a := TAU * float(i) / 32.0
				body.append(Vector2(c.x + cos(a) * r * 0.8, c.y + r * 1.0 + sin(a) * r * 0.6))
			for piece in Geometry2D.intersect_polygons(disc, body):
				draw_colored_polygon(piece, fg_color)
		draw_arc(c, r - ring_width * 0.5, 0.0, TAU, 40, ring_color, ring_width, true)

# ------------------------------------------------------------ botões do menu

# Caixa com cantos cortados a 45° e borda só na esquerda e embaixo.
# Cortes: inferior esquerdo e superior direito (os outros dois são retos).
# (StyleBoxFlat não faz corte reto, então desenhamos à mão.)
class BevelBox extends StyleBox:
	var fill := Color.BLACK
	var border_color := Color.WHITE
	var border_w := 4.0
	var cut := 12.0            # tamanho do corte nos cantos, em pixels

	func _draw(to_canvas_item: RID, rect: Rect2) -> void:
		var x := rect.position.x
		var y := rect.position.y
		var w := rect.size.x
		var h := rect.size.y
		var c := minf(cut, minf(w, h) * 0.5)

		# Fundo: canto sup. esquerdo e inf. direito retos; os outros cortados
		var shape := PackedVector2Array([
			Vector2(x, y), Vector2(x + w - c, y),
			Vector2(x + w, y + c), Vector2(x + w, y + h),
			Vector2(x + c, y + h), Vector2(x, y + h - c),
		])
		RenderingServer.canvas_item_add_polygon(
			to_canvas_item, shape, PackedColorArray([fill]))

		if border_w <= 0.0:
			return
		# Borda: lado esquerdo + corte inferior esquerdo + lado de baixo.
		# O traço fica por dentro da forma (deslocado meia espessura).
		var hw := border_w * 0.5
		var k := hw * (sqrt(2.0) - 1.0)
		var line := PackedVector2Array([
			Vector2(x + hw, y),
			Vector2(x + hw, y + h - c - k),
			Vector2(x + c + k, y + h - hw),
			Vector2(x + w, y + h - hw),
		])
		RenderingServer.canvas_item_add_polyline(
			to_canvas_item, line, PackedColorArray([border_color]), border_w, true)

# Aplica o visual personalizado a um Button: fundo azul, borda laranja
# (esquerda + embaixo) e dois cantos cortados a 45°.
static func style_button(b: Button, kind: Kind = Kind.PRIMARY) -> void:
	var fill := Color("010139")
	var edge := ACCENT
	var text := TEXT_LIGHT
	var width := 5.0
	match kind:
		Kind.PRIMARY:
			width = 5.0
		Kind.SECONDARY:
			width = 3.0
		_:  # GHOST: discreto, para Voltar / Sair
			width = 2.0
			fill = Color(fill, 0.55)
			edge = Color(ACCENT, 0.6)

	b.add_theme_stylebox_override("normal", _bevel(fill, edge, width, false))
	b.add_theme_stylebox_override("hover", _bevel(fill.lightened(0.15), edge.lightened(0.2), width, false))
	b.add_theme_stylebox_override("pressed", _bevel(fill.lightened(0.05), edge, width, true))
	b.add_theme_stylebox_override("disabled", _bevel(fill.darkened(0.4), Color(edge, 0.3), width, false))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, text)
	b.add_theme_color_override("font_disabled_color", Color(text, 0.5))
	b.add_theme_font_size_override("font_size", 20)

static func _bevel(fill: Color, edge: Color, width: float, pressed: bool) -> BevelBox:
	var sb := BevelBox.new()
	sb.fill = fill
	sb.border_color = edge
	sb.border_w = width
	sb.cut = 12.0
	sb.content_margin_left = 16 + width
	sb.content_margin_right = 16
	sb.content_margin_top = 6 if pressed else 2   # texto "afunda" ao apertar
	sb.content_margin_bottom = 2 + width
	return sb
