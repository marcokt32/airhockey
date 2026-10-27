class_name AvatarArt
extends RefCounted
## Avatares próprios do jogo, desenhados por código: nenhum arquivo de imagem
## (sem download, sem direitos autorais). Cada avatar = jogador de hóquei de capacete e cara de bravo,
## sobre um fundo em degradê. Uso: AvatarArt.make(i) devolve a Image; AvatarArt.texture(i) uma miniatura em cache.
## Para criar mais: acrescente uma linha em _specs() e aumente COUNT.
## Obs.: o preenchimento não mistura transparência (fill_rect), então só cores sólidas.

const COUNT := 12
const SIZE := 128            # desenha maior que o necessário (64 px no jogo): as bordas ficam suaves ao reduzir
const SCALE := 0.88          # parte do raio ocupada pelo desenho (coordenadas -1..1)
const CENTER_DY := 0.03      # desce o desenho um pouco (fração do tamanho): sobra espaço para crista/chifres

# Extras (lista por avatar): 1 cicatriz, 2 moicano, 3 chifres, 4 grade de goleiro, 5 bigode,
# 6 olho roxo, 7 viseira escura, 8 monocelha, 9 curativo, 10 estrela no capacete
# Olhos: 0 normal, 1 semicerrado, 3 olho esquerdo fechado, 4 injetados (vermelhos), 5 olhar de lado
# (2 = viseira, vem dos extras)
# Boca: 0 dentes cerrados, 1 gritando, 2 dente faltando, 3 reta, 4 carranca, 5 sorriso malvado,
# 6 sorriso largo de tubarão, 7 carranca com presas

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
	for layer in _layers(spec):
		_fill(img, layer[0], layer[1], top, bottom)
	return img

# [fundo topo, fundo base, capacete, camisa, pele, olhos, boca, extras, inclinação da sobrancelha (0..1)]
static func _specs() -> Array:
	return [
		[Color.html("#3a7bd5"), Color.html("#00d2ff"), Color.html("#2f6fdb"), Color.html("#f5f5f5"), Color.html("#f1c9a0"), 0, 0, [], 1.0],        # brigão
		[Color.html("#ff512f"), Color.html("#dd2476"), Color.html("#3a3f47"), Color.html("#ffd54f"), Color.html("#c98f6a"), 3, 3, [1], 0.7],       # veterano
		[Color.html("#141e30"), Color.html("#243b55"), Color.html("#0d0d12"), Color.html("#4dd0e1"), Color.html("#d9a67a"), 2, 2, [7], 0.0],       # viseira negra
		[Color.html("#11998e"), Color.html("#38ef7d"), Color.html("#f2f2f2"), Color.html("#1a237e"), Color.html("#7d4b2c"), 5, 6, [], 0.45],       # negro: sorriso de tubarão, olhar de lado
		[Color.html("#7f00ff"), Color.html("#e100ff"), Color.html("#2e7d32"), Color.html("#ffee58"), Color.html("#f1c9a0"), 0, 5, [2], 0.6],       # moicano
		[Color.html("#f7971e"), Color.html("#ffd200"), Color.html("#c62828"), Color.html("#263238"), Color.html("#f1c9a0"), 0, 4, [8], 0.8],       # monocelha
		[Color.html("#4568dc"), Color.html("#b06ab3"), Color.html("#ff6f00"), Color.html("#eceff1"), Color.html("#a8744f"), 0, 1, [], 1.0],        # gritão
		[Color.html("#232526"), Color.html("#414345"), Color.html("#6a1b9a"), Color.html("#e53935"), Color.html("#e0b090"), 4, 7, [3], 1.0],       # chifrudo: olhos injetados e presas
		[Color.html("#56ab2f"), Color.html("#a8e063"), Color.html("#1a237e"), Color.html("#ffd54f"), Color.html("#f1c9a0"), 0, 4, [5], 0.9],       # bigode
		[Color.html("#0f2027"), Color.html("#2c5364"), Color.html("#9e9e9e"), Color.html("#e53935"), Color.html("#d9a67a"), 0, 2, [6, 9], 1.0],    # olho roxo
		[Color.html("#f12711"), Color.html("#f5af19"), Color.html("#00897b"), Color.html("#fff8e1"), Color.html("#f1c9a0"), 0, 2, [], 1.0],        # dentuço
		[Color.html("#373b44"), Color.html("#4286f4"), Color.html("#90caf9"), Color.html("#ffffff"), Color.html("#e9d3c0"), 1, 3, [10], 0.7],     # pedra
	]

# ---------------------------------------------------------------- montagem do jogador
# Camadas de trás para frente: [lista de polígonos (coordenadas -1..1, y para baixo), cor].

static func _layers(sp: Array) -> Array:
	var helmet: Color = sp[2]
	var jersey: Color = sp[3]
	var skin: Color = sp[4]
	var eyes: int = sp[5]
	var mouth: int = sp[6]
	var ex: Array = sp[7]
	var slope: float = sp[8]
	var visor: bool = ex.has(7)
	var L: Array = []

	# atrás do capacete: crista de moicano e chifres
	if ex.has(2):
		for i in 5:
			var x := -0.48 + 0.24 * float(i)
			var tip := Vector2(x * 0.85, -1.17 + 0.05 * absf(x) / 0.48)
			_outline_shift(L, PackedVector2Array([Vector2(x - 0.13, -0.80), Vector2(x + 0.13, -0.80), tip]), jersey, 0.04)
	if ex.has(3):
		for s in [-1.0, 1.0]:
			var horn := PackedVector2Array([Vector2(s * 0.45, -0.85), Vector2(s * 0.78, -0.55), Vector2(s * 0.92, -1.08)])
			_outline_shift(L, horn, Color("f5f0dc"), 0.04)

	# camisa e cabeça
	var jc := Vector2(0.0, 1.22)
	_outline_convex(L, _ellipse(jc, 1.0, 0.6), jc, jersey, 0.05)
	var hc := Vector2(0.0, 0.02)
	_outline_convex(L, _circle(hc, 0.78), hc, skin, 0.05)

	# capacete: casca com janela para o rosto, respiros e brilho
	_outline_shift(L, _helmet_shell(), helmet, 0.045)
	var vent := helmet.darkened(0.45)
	for s in [-1.0, 1.0]:
		for j in 2:
			var x0: float = s * (0.25 + 0.20 * j)
			var y0: float = -(0.88 - 0.08 * j)
			var vp := PackedVector2Array()
			for k in 5:
				var t := float(k) / 4.0
				vp.append(Vector2(x0 + s * 0.20 * t, y0 + 0.14 * t * t))
			_polyline(L, vp, 0.05, vent, 0.0)
	var shine := PackedVector2Array()
	for k in 6:
		var a := lerpf(PI * 1.22, PI * 1.40, float(k) / 5.0)
		shine.append(Vector2(cos(a) * 0.80, -0.08 + sin(a) * 0.80))
	_polyline(L, shine, 0.06, helmet.lightened(0.5), 0.0)
	if ex.has(10):
		var sc := Vector2(0.0, -0.72)
		_outline_shift(L, _star(sc, 0.17, 0.075), Color("ffe066"), 0.03)

	# olho roxo (por baixo do olho)
	if ex.has(6):
		_add(L, _ellipse(Vector2(0.28, -0.02), 0.21, 0.18), Color("7b4a9e"))

	# olhos
	if not visor:
		for s in [-1.0, 1.0]:
			var c := Vector2(s * 0.28, -0.04)
			if eyes == 3 and s < 0.0:
				_polyline(L, PackedVector2Array([c + Vector2(-0.15, -0.02), c + Vector2(0.0, 0.03), c + Vector2(0.15, -0.02)]), 0.06, Color.BLACK, 0.0)
				continue
			var white := Color("ff6b5e") if eyes == 4 else Color.WHITE
			_outline_convex(L, _ellipse(c, 0.15, 0.12), c, white, 0.03)
			var pupil_x: float = c.x - s * 0.03   # normal: pupila levemente para dentro (olhar zangado)
			if eyes == 5:
				pupil_x = c.x + 0.07              # olhando de lado, desconfiado
			_add(L, _circle(Vector2(pupil_x, -0.03), 0.065), Color.BLACK)
			if eyes == 1:   # pálpebra caída: metade de cima coberta
				_add(L, _rect(c + Vector2(-0.18, -0.17), c + Vector2(0.18, -0.01)), skin)
				_polyline(L, PackedVector2Array([c + Vector2(-0.16, -0.01), c + Vector2(0.16, -0.01)]), 0.045, Color.BLACK, 0.0)

	# sobrancelhas zangadas (pontas de dentro descem). Monocelha: as duas se encontram no meio
	if not visor:
		var inner_x := 0.0 if ex.has(8) else 0.07
		var bw := 0.13 if ex.has(8) else 0.10
		for s in [-1.0, 1.0]:
			var outer := Vector2(s * 0.52, -0.30 - 0.05 * slope)
			var inner := Vector2(s * inner_x, -0.28 + 0.17 * slope)
			_polyline(L, PackedVector2Array([outer, inner]), bw, Color.BLACK, 0.0)

	# boca
	var y0m := 0.45
	match mouth:
		0, 2:   # dentes cerrados (2 = com um dente faltando)
			_add(L, _rect(Vector2(-0.33, y0m - 0.13), Vector2(0.33, y0m + 0.14)), Color.BLACK)
			_add(L, _rect(Vector2(-0.30, y0m - 0.10), Vector2(0.30, y0m + 0.11)), Color.WHITE)
			if mouth == 2:
				_add(L, _rect(Vector2(0.02, y0m - 0.10), Vector2(0.14, y0m + 0.11)), Color.BLACK)
			var gaps := [-0.15, 0.15] if mouth == 2 else [-0.15, 0.0, 0.15]
			for gx in gaps:
				_polyline(L, PackedVector2Array([Vector2(gx, y0m - 0.10), Vector2(gx, y0m + 0.11)]), 0.025, Color.BLACK, 0.0)
			_polyline(L, PackedVector2Array([Vector2(-0.30, y0m + 0.005), Vector2(0.30, y0m + 0.005)]), 0.025, Color.BLACK, 0.0)
		1:      # gritando
			var mc := Vector2(0.0, y0m + 0.02)
			_outline_convex(L, _ellipse(mc, 0.26, 0.19), mc, Color("7a1020"), 0.035)
			_add(L, _ellipse(Vector2(0.0, y0m + 0.12), 0.13, 0.07), Color("e57373"))
			_add(L, _rect(Vector2(-0.14, y0m - 0.14), Vector2(0.14, y0m - 0.07)), Color.WHITE)
		3:      # reta
			_polyline(L, PackedVector2Array([Vector2(-0.22, y0m), Vector2(0.22, y0m)]), 0.07, Color.BLACK, 0.0)
		4:      # carranca
			var fp := PackedVector2Array()
			for k in 9:
				var u := lerpf(-1.0, 1.0, float(k) / 8.0)
				fp.append(Vector2(u * 0.26, y0m + 0.06 - 0.12 * (1.0 - u * u)))
			_polyline(L, fp, 0.07, Color.BLACK, 0.0)
		6:      # sorriso largo de tubarão
			var gl := PackedVector2Array()
			for k in 13:
				var u := lerpf(-1.0, 1.0, float(k) / 12.0)
				gl.append(Vector2(u * 0.34, y0m - 0.06))
			for k in 13:
				var u2 := lerpf(1.0, -1.0, float(k) / 12.0)
				gl.append(Vector2(u2 * 0.34, y0m - 0.06 + 0.22 * (1.0 - u2 * u2)))
			_outline_convex(L, gl, Vector2(0.0, y0m + 0.02), Color.WHITE, 0.035)
			for gx in [-0.17, 0.0, 0.17]:
				var uu: float = gx / 0.34
				_polyline(L, PackedVector2Array([Vector2(gx, y0m - 0.06), Vector2(gx, y0m - 0.06 + 0.22 * (1.0 - uu * uu))]), 0.025, Color.BLACK, 0.0)
		7:      # carranca com presas
			var fp2 := PackedVector2Array()
			for k in 9:
				var u3 := lerpf(-1.0, 1.0, float(k) / 8.0)
				fp2.append(Vector2(u3 * 0.28, y0m + 0.06 - 0.12 * (1.0 - u3 * u3)))
			_polyline(L, fp2, 0.07, Color.BLACK, 0.0)
			for s in [-1.0, 1.0]:
				var fx: float = s * 0.12
				var fu: float = fx / 0.28
				var fy: float = y0m + 0.06 - 0.12 * (1.0 - fu * fu)
				_outline_shift(L, PackedVector2Array([Vector2(fx - 0.05, fy + 0.01), Vector2(fx + 0.05, fy + 0.01), Vector2(fx, fy + 0.12)]), Color.WHITE, 0.02)
		_:      # sorriso malvado
			_polyline(L, PackedVector2Array([Vector2(-0.26, y0m + 0.05), Vector2(0.0, y0m + 0.03), Vector2(0.26, y0m - 0.05)]), 0.07, Color.BLACK, 0.0)

	# por cima do rosto
	if ex.has(5):   # bigode
		for s in [-1.0, 1.0]:
			var mc2 := Vector2(s * 0.14, 0.27)
			_outline_convex(L, _ellipse(mc2, 0.17, 0.08), mc2, Color("3b2314"), 0.025)
	if ex.has(9):   # curativo na bochecha
		_polyline(L, PackedVector2Array([Vector2(0.30, 0.18), Vector2(0.56, 0.42)]), 0.07, Color("f3e3c3"), 0.04)
		_polyline(L, PackedVector2Array([Vector2(0.30, 0.42), Vector2(0.56, 0.18)]), 0.07, Color("f3e3c3"), 0.04)
	if ex.has(1):   # cicatriz com pontos, cruzando o olho esquerdo
		var a1 := Vector2(-0.44, -0.30)
		var b1 := Vector2(-0.14, 0.08)
		_polyline(L, PackedVector2Array([a1, b1]), 0.05, Color("c0392b"), 0.04)
		var dir := (b1 - a1).normalized()
		var perp := Vector2(-dir.y, dir.x)
		for f in [0.3, 0.5, 0.7]:
			var m: Vector2 = a1.lerp(b1, f)
			_polyline(L, PackedVector2Array([m - perp * 0.07, m + perp * 0.07]), 0.03, Color.BLACK, 0.0)
	if visor:       # viseira escura com olhos vermelhos
		_outline_shift(L, _rrect(Vector2(-0.70, -0.40), Vector2(0.70, 0.12), 0.14), Color("10141c"), 0.04)
		for s in [-1.0, 1.0]:
			_add(L, PackedVector2Array([Vector2(s * 0.10, -0.12), Vector2(s * 0.52, -0.24), Vector2(s * 0.52, -0.10), Vector2(s * 0.16, 0.0)]), Color("ff3b30"))
		_polyline(L, PackedVector2Array([Vector2(-0.58, -0.30), Vector2(-0.48, -0.30)]), 0.04, Color("3a4a63"), 0.0)
	if ex.has(4):   # grade de goleiro
		for k in 5:
			var gx2 := -0.40 + 0.20 * float(k)
			var lim := sqrt(maxf(0.78 * 0.78 - gx2 * gx2, 0.0))
			_polyline(L, PackedVector2Array([Vector2(gx2, -0.36), Vector2(gx2, 0.02 + lim * 0.94)]), 0.035, Color("dfe3ea"), 0.04)
		for gy in [0.22, 0.48]:
			var hw := sqrt(maxf(0.78 * 0.78 - (gy - 0.02) * (gy - 0.02), 0.0)) * 0.94
			_polyline(L, PackedVector2Array([Vector2(-hw, gy), Vector2(hw, gy)]), 0.035, Color("dfe3ea"), 0.04)
	return L

# Casca do capacete: arco por cima e pelos lados, com uma janela aberta para olhos, sobrancelhas e boca.
static func _helmet_shell() -> PackedVector2Array:
	var poly := PackedVector2Array()
	var cy := -0.08
	var big := 0.93
	var a0 := PI - 0.28
	var a1 := TAU + 0.28
	for k in 25:
		var a := lerpf(a0, a1, float(k) / 24.0)
		poly.append(Vector2(cos(a) * big, cy + sin(a) * big))
	poly.append(Vector2(0.64, 0.20))
	for k in 9:
		var x := lerpf(0.64, -0.64, float(k) / 8.0)
		poly.append(Vector2(x, -0.40 + 0.12 * x * x))
	poly.append(Vector2(-0.64, 0.20))
	return poly

# ---------------------------------------------------------------- desenho de camadas

static func _add(L: Array, poly: PackedVector2Array, col: Color) -> void:
	L.append([[poly], col])

# Contorno preto para formas convexas (círculo, elipse): uma cópia maior por trás
static func _outline_convex(L: Array, poly: PackedVector2Array, c: Vector2, col: Color, w: float) -> void:
	var big := PackedVector2Array()
	for p in poly:
		var d: Vector2 = p - c
		big.append(p + (d.normalized() * w if d.length() > 0.0001 else Vector2.ZERO))
	_add(L, big, Color.BLACK)
	_add(L, poly, col)

# Contorno preto para qualquer forma: cópias pretas deslocadas em 8 direções
static func _outline_shift(L: Array, poly: PackedVector2Array, col: Color, w: float) -> void:
	for k in 8:
		var d := Vector2.from_angle(TAU * float(k) / 8.0) * w
		_add(L, _shift(poly, d), Color.BLACK)
	_add(L, poly, col)

# Traço grosso com pontas redondas. ow > 0: contorno preto de ow de cada lado.
static func _polyline(L: Array, pts: PackedVector2Array, w: float, col: Color, ow: float) -> void:
	if ow > 0.0:
		_stroke(L, pts, w + ow * 2.0, Color.BLACK)
	_stroke(L, pts, w, col)

static func _stroke(L: Array, pts: PackedVector2Array, w: float, col: Color) -> void:
	for i in pts.size() - 1:
		_add(L, _quad(pts[i], pts[i + 1], w), col)
	for p in pts:
		_add(L, _circle(p, w * 0.5), col)

# ---------------------------------------------------------------- formas (coordenadas -1..1, y para baixo)

static func _ngon(c: Vector2, r: float, n: int, rot: float = -PI / 2.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in n:
		var a := rot + TAU * float(k) / float(n)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts

static func _circle(c: Vector2, r: float) -> PackedVector2Array:
	return _ngon(c, r, 40)

static func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 40:
		var a := TAU * float(k) / 40.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts

static func _star(c: Vector2, big: float, small: float, n: int = 5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in n * 2:
		var a := -PI / 2.0 + PI * float(k) / float(n)
		var rad := big if k % 2 == 0 else small
		pts.append(c + Vector2(cos(a), sin(a)) * rad)
	return pts

static func _rect(a: Vector2, b: Vector2) -> PackedVector2Array:
	return PackedVector2Array([a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)])

# Retângulo de cantos arredondados (a = canto sup. esquerdo, b = inf. direito)
static func _rrect(a: Vector2, b: Vector2, rad: float) -> PackedVector2Array:
	var centers := [Vector2(b.x - rad, a.y + rad), Vector2(b.x - rad, b.y - rad),
		Vector2(a.x + rad, b.y - rad), Vector2(a.x + rad, a.y + rad)]
	var starts := [-PI / 2.0, 0.0, PI / 2.0, PI]
	var pts := PackedVector2Array()
	for q in 4:
		var c: Vector2 = centers[q]
		for k in 5:
			var ang: float = float(starts[q]) + (PI / 2.0) * float(k) / 4.0
			pts.append(c + Vector2(cos(ang), sin(ang)) * rad)
	return pts

# Traço reto como retângulo fino
static func _quad(a: Vector2, b: Vector2, w: float) -> PackedVector2Array:
	var d := b - a
	if d.length() < 0.0001:
		return PackedVector2Array()
	d = d.normalized()
	var n := Vector2(-d.y, d.x) * (w * 0.5)
	return PackedVector2Array([a + n, b + n, b - n, a - n])

static func _shift(poly: PackedVector2Array, d: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(p + d)
	return out

# ---------------------------------------------------------------- preenchimento (varredura por linhas)

# Preenche os polígonos (regra par-ímpar). col = null: usa a cor do fundo naquela linha (recorte).
static func _fill(img: Image, polys: Array, col: Variant, top: Color, bottom: Color) -> void:
	var half := SIZE * 0.5
	var k := half * SCALE
	var center := Vector2(half, half + SIZE * CENTER_DY)
	var edges: Array[Vector4] = []
	var min_y := 1.0e9
	var max_y := -1.0e9
	for poly in polys:
		var pts: PackedVector2Array = poly
		var n := pts.size()
		if n < 3:
			continue
		for i in n:
			var a := center + pts[i] * k
			var b := center + pts[(i + 1) % n] * k
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
