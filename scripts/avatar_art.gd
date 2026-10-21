class_name AvatarArt
extends RefCounted
## Avatares próprios do jogo, desenhados por código: não usa nenhum arquivo de imagem
## (sem download, sem direitos autorais). Cada avatar = fundo em degradê + um emblema.
## Uso: AvatarArt.make(i) devolve a Image; AvatarArt.texture(i) devolve uma miniatura em cache.
## Para criar mais: acrescente uma linha em _specs() e um caso em _layers(), e aumente COUNT.

const COUNT := 12
const SIZE := 192            # desenha grande; ao reduzir (64 px) as bordas ficam suaves
const EMBLEM_SCALE := 0.78   # parte do raio ocupada pelo emblema

static var _cache := {}

## Miniatura em cache (para a grade de escolha).
static func texture(i: int, px: int = 64) -> ImageTexture:
	var key := "%d_%d" % [posmod(i, COUNT), px]
	if not _cache.has(key):
		var img := make(i)
		img.resize(px, px, Image.INTERPOLATE_LANCZOS)
		_cache[key] = ImageTexture.create_from_image(img)
	return _cache[key]

## Imagem quadrada SIZE x SIZE do avatar i.
static func make(i: int) -> Image:
	var spec: Array = _specs()[posmod(i, COUNT)]
	var top: Color = spec[0]
	var bottom: Color = spec[1]
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		img.fill_rect(Rect2i(0, y, SIZE, 1), top.lerp(bottom, float(y) / float(SIZE - 1)))
	for layer in _layers(int(spec[2]), spec[3], spec[4]):
		_fill(img, layer[0], layer[1], top, bottom)
	return img

# [cor do topo, cor da base, emblema, cor principal, cor de destaque]
static func _specs() -> Array:
	return [
		[Color.html("#3a7bd5"), Color.html("#00d2ff"), 0, Color.html("#263238"), Color.html("#ffd54f")],   # disco
		[Color.html("#ff512f"), Color.html("#dd2476"), 1, Color.html("#fff176"), Color.html("#ffb300")],   # estrela
		[Color.html("#7f00ff"), Color.html("#e100ff"), 2, Color.html("#ffee58"), Color.html("#4a148c")],   # raio
		[Color.html("#11998e"), Color.html("#38ef7d"), 3, Color.html("#ffd54f"), Color.html("#e65100")],   # coroa
		[Color.html("#f7971e"), Color.html("#ffd200"), 4, Color.html("#e53935"), Color.html("#ffcdd2")],   # coração
		[Color.html("#141e30"), Color.html("#243b55"), 5, Color.html("#4dd0e1"), Color.html("#e0f7fa")],   # diamante
		[Color.html("#0f2027"), Color.html("#2c5364"), 6, Color.html("#fff9c4"), Color.html("#ffee58")],   # lua
		[Color.html("#232526"), Color.html("#414345"), 7, Color.html("#ffffff"), Color.html("#e53935")],   # alvo
		[Color.html("#56ab2f"), Color.html("#a8e063"), 8, Color.html("#ffd54f"), Color.html("#5d4037")],   # sorriso
		[Color.html("#4568dc"), Color.html("#b06ab3"), 9, Color.html("#eceff1"), Color.html("#3949ab")],   # escudo
		[Color.html("#f12711"), Color.html("#f5af19"), 10, Color.html("#fff8e1"), Color.html("#ff6f00")],  # colmeia
		[Color.html("#373b44"), Color.html("#4286f4"), 11, Color.html("#ffffff"), Color.html("#ffca28")],  # patente
	]

# Camadas do emblema, de trás para frente: [lista de polígonos (coordenadas -1..1), cor].
# cor = null recorta o desenho, mostrando o fundo (vazado).
static func _layers(id: int, c1: Color, c2: Color) -> Array:
	var o := Vector2.ZERO
	match id:
		0:  # disco (puck): miolo escuro com anel de destaque
			return [[[_circle(o, 0.72)], c1], [[_circle(o, 0.58)], c2], [[_circle(o, 0.44)], c1]]
		1:  # estrela
			return [[[_star(o, 0.85, 0.36)], c1], [[_star(o, 0.42, 0.18)], c2]]
		2:  # raio, com sombra
			var bolt := _bolt()
			return [[[_shift(bolt, Vector2(0.07, 0.07))], c2], [[bolt], c1]]
		3:  # coroa
			var tips := [Vector2(-0.7, -0.3), Vector2(0.0, -0.55), Vector2(0.7, -0.3)]
			var layers: Array = [
				[[PackedVector2Array([Vector2(-0.7, 0.5), Vector2(-0.7, -0.3), Vector2(-0.35, 0.05), Vector2(0.0, -0.55),
					Vector2(0.35, 0.05), Vector2(0.7, -0.3), Vector2(0.7, 0.5)])], c1],
				[[_rect(Vector2(-0.7, 0.52), Vector2(0.7, 0.74))], c2],
			]
			for t in tips:
				layers.append([[_circle(t, 0.11)], c2])
			return layers
		4:  # coração
			return [[[_heart()], c1], [[_circle(Vector2(-0.32, -0.3), 0.11)], c2]]
		5:  # diamante (gema)
			return [
				[[PackedVector2Array([Vector2(-0.45, -0.7), Vector2(0.45, -0.7), Vector2(0.8, -0.15), Vector2(0.0, 0.85), Vector2(-0.8, -0.15)])], c1],
				[[PackedVector2Array([Vector2(-0.45, -0.7), Vector2(0.45, -0.7), Vector2(0.8, -0.15), Vector2(-0.8, -0.15)])], c2],
				[[PackedVector2Array([Vector2(-0.8, -0.15), Vector2(0.8, -0.15), Vector2(0.0, 0.85)])], c1],
				[[PackedVector2Array([Vector2(-0.34, -0.15), Vector2(0.34, -0.15), Vector2(0.0, 0.5)])], c2],
			]
		6:  # lua crescente + estrela
			return [[[_circle(o, 0.7)], c1], [[_circle(Vector2(0.32, -0.14), 0.58)], null],
				[[_star(Vector2(0.42, 0.04), 0.22, 0.09)], c2]]
		7:  # alvo
			return [[[_circle(o, 0.78)], c1], [[_circle(o, 0.58)], c2], [[_circle(o, 0.38)], c1], [[_circle(o, 0.17)], c2]]
		8:  # sorriso
			return [[[_circle(o, 0.78)], c1],
				[[_circle(Vector2(-0.27, -0.2), 0.1)], c2], [[_circle(Vector2(0.27, -0.2), 0.1)], c2],
				[[_smile(Vector2(0.0, -0.05), 0.5, 0.36)], c2]]
		9:  # escudo
			var shield := PackedVector2Array([Vector2(-0.62, -0.7), Vector2(0.62, -0.7), Vector2(0.62, 0.0),
				Vector2(0.4, 0.5), Vector2(0.0, 0.85), Vector2(-0.4, 0.5), Vector2(-0.62, 0.0)])
			return [[[shield], c1], [[_scale(shield, 0.68, Vector2(0.0, -0.06))], c2],
				[[_star(Vector2(0.0, -0.08), 0.3, 0.13)], c1]]
		10:  # colmeia
			return [[[_ngon(o, 0.82, 6)], c1], [[_ngon(o, 0.56, 6)], c2], [[_ngon(o, 0.26, 6)], c1]]
		_:  # patente (setas para cima)
			var chev := PackedVector2Array([Vector2(-0.7, 0.0), Vector2(0.0, -0.7), Vector2(0.7, 0.0),
				Vector2(0.7, 0.34), Vector2(0.0, -0.36), Vector2(-0.7, 0.34)])
			return [[[_shift(chev, Vector2(0.0, 0.46))], c2], [[_shift(chev, Vector2(0.0, 0.0))], c1]]
	return []

# ---------------------------------------------------------------- formas (coordenadas -1..1, y para baixo)

static func _ngon(c: Vector2, r: float, n: int, rot: float = -PI / 2.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in n:
		var a := rot + TAU * float(k) / float(n)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts

static func _circle(c: Vector2, r: float) -> PackedVector2Array:
	return _ngon(c, r, 56)

static func _star(c: Vector2, big: float, small: float, n: int = 5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in n * 2:
		var a := -PI / 2.0 + PI * float(k) / float(n)
		var rad := big if k % 2 == 0 else small
		pts.append(c + Vector2(cos(a), sin(a)) * rad)
	return pts

static func _rect(a: Vector2, b: Vector2) -> PackedVector2Array:
	return PackedVector2Array([a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)])

static func _bolt() -> PackedVector2Array:
	return PackedVector2Array([Vector2(0.1, -0.9), Vector2(-0.45, 0.15), Vector2(-0.05, 0.15), Vector2(-0.15, 0.9),
		Vector2(0.45, -0.2), Vector2(0.05, -0.2), Vector2(0.35, -0.9)])

static func _heart() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 64:
		var t := TAU * float(k) / 64.0
		var x := 16.0 * pow(sin(t), 3.0)
		var y := -(13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t))
		pts.append(Vector2(x, y - 2.5) / 17.0 * 0.95)
	return pts

# Faixa curva em "U" (boca): arco externo indo e arco interno voltando
static func _smile(c: Vector2, r_out: float, r_in: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 13:
		var a := deg_to_rad(20.0 + 140.0 * float(k) / 12.0)
		pts.append(c + Vector2(cos(a), sin(a)) * r_out)
	for k in 13:
		var a := deg_to_rad(160.0 - 140.0 * float(k) / 12.0)
		pts.append(c + Vector2(cos(a), sin(a)) * r_in)
	return pts

static func _shift(poly: PackedVector2Array, d: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(p + d)
	return out

static func _scale(poly: PackedVector2Array, s: float, d: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(p * s + d)
	return out

# ---------------------------------------------------------------- preenchimento (varredura por linhas)

# Preenche os polígonos (regra par-ímpar). col = null: usa a cor do fundo naquela linha (recorte).
static func _fill(img: Image, polys: Array, col: Variant, top: Color, bottom: Color) -> void:
	var half := SIZE * 0.5
	var k := half * EMBLEM_SCALE
	var edges: Array[Vector4] = []
	var min_y := 1.0e9
	var max_y := -1.0e9
	for poly in polys:
		var pts: PackedVector2Array = poly
		var n := pts.size()
		for i in n:
			var a := Vector2(half, half) + pts[i] * k
			var b := Vector2(half, half) + pts[(i + 1) % n] * k
			min_y = minf(min_y, minf(a.y, b.y))
			max_y = maxf(max_y, maxf(a.y, b.y))
			if not is_equal_approx(a.y, b.y):
				edges.append(Vector4(a.x, a.y, b.x, b.y))
	for y in range(maxi(0, int(floorf(min_y))), mini(SIZE - 1, int(ceilf(max_y))) + 1):
		var yc := float(y) + 0.5
		var xs: Array[float] = []
		for e in edges:
			if (e.y <= yc and e.w > yc) or (e.w <= yc and e.y > yc):
				xs.append(e.x + (yc - e.y) / (e.w - e.y) * (e.z - e.x))
		xs.sort()
		var c: Color = col if col is Color else top.lerp(bottom, float(y) / float(SIZE - 1))
		var j := 0
		while j + 1 < xs.size():
			var x0 := clampi(int(roundf(xs[j])), 0, SIZE)
			var x1 := clampi(int(roundf(xs[j + 1])), 0, SIZE)
			if x1 > x0:
				img.fill_rect(Rect2i(x0, y, x1 - x0, 1), c)
			j += 2
