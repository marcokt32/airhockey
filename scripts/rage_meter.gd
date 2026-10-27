class_name RageMeter
extends Control
## Barra de raiva que fica embaixo do nome no cabeçalho. Enche com um efeito de chamas
## (línguas de fogo que crescem com o nível) e, cheia, pulsa e solta fogo no comprimento todo.
## Quem controla o valor é o main.gd (value = 0..1). `mine` decide de que lado a barra enche:
## true = da esquerda para a direita (meu nome, à esquerda); false = da direita para a esquerda (rival).

var value := 0.0:
	set(v):
		value = clampf(v, 0.0, 1.0)
var mine := true

const BAR_H := 8.0          # altura da barra (as chamas sobem para fora do controle)
const FLAME_STEP := 7.0     # espaço entre as línguas de fogo (px)

var _shown := 0.0           # valor suavizado (a barra "escorre" até o valor real)
var _t := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	_shown = lerpf(_shown, value, 1.0 - exp(-8.0 * delta))
	if absf(_shown - value) < 0.002:
		_shown = value
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	var top := h - BAR_H
	draw_rect(Rect2(0.0, top, w, BAR_H), Color(0.0, 0.0, 0.0, 0.5))
	var full := _shown >= 0.995
	var fill_w := w * _shown
	if fill_w > 0.5:
		var x0 := 0.0 if mine else w - fill_w
		var heat := Color("ffa000").lerp(Color("e53100"), _shown)
		draw_rect(Rect2(x0, top, fill_w, BAR_H), heat)
		draw_rect(Rect2(x0, top, fill_w, BAR_H * 0.4), heat.lightened(0.35))
		# línguas de fogo sobre a parte cheia: mais altas e mais vivas quanto mais cheia
		var n := clampi(int(fill_w / FLAME_STEP), 1, 40)
		var lift := 3.0 + 9.0 * _shown + (5.0 if full else 0.0)
		for i in n:
			var cx := x0 + (float(i) + 0.5) * (fill_w / float(n))
			var wob := 0.55 + 0.45 * absf(sin(_t * 8.0 + float(i) * 1.9))
			var fh := lift * wob
			var sway := sin(_t * 5.0 + float(i) * 0.9) * 1.6
			draw_colored_polygon(PackedVector2Array([
				Vector2(cx - 3.6, top + 1.0), Vector2(cx + sway, top - fh), Vector2(cx + 3.6, top + 1.0)]),
				Color(1.0, 0.42, 0.05, 0.92))
			draw_colored_polygon(PackedVector2Array([
				Vector2(cx - 1.8, top + 1.0), Vector2(cx + sway * 0.6, top - fh * 0.62), Vector2(cx + 1.8, top + 1.0)]),
				Color(1.0, 0.92, 0.35, 0.95))
	if full:   # cheia: brilho pulsando em volta (dá para ver de longe que o X1 está liberado)
		var pulse := 0.5 + 0.5 * sin(_t * 10.0)
		draw_rect(Rect2(-2.0, top - 2.0, w + 4.0, BAR_H + 4.0), Color(1.0, 0.85, 0.2, 0.35 + 0.4 * pulse), false, 2.0)
	draw_rect(Rect2(0.0, top, w, BAR_H), Color.BLACK, false, 2.0)
