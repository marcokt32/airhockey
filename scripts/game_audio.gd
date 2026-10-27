class_name GameAudio
extends Node
## Sons, música e vibração do jogo. Sobrevive à troca de cena: fica pendurado
## na raiz da árvore (não precisa registrar como Autoload).
## Uso: GameAudio.ensure(get_tree()) uma vez; depois GameAudio.wall(...), GameAudio.goal() etc.
## Arquivo ausente = som mudo (nada quebra). Para trocar um som, substitua o arquivo em res://audio/.

const PATH_THEME := "res://audio/theme.ogg"                 # música tema (loop)
const PATH_WALL := "res://audio/wall.wav"                   # disco na parede
const PATH_HIT := "res://audio/hit.wav"                     # taco bate no disco
const PATH_WHISTLE_START := "res://audio/whistle_start.wav" # apito de início
const PATH_WHISTLE_END := "res://audio/whistle_end.wav"     # apito de fim
const PATH_CROWD := "res://audio/crowd.ogg"                 # torcida no gol
# Socos do X1: um sorteado a cada golpe (arquivo ausente = fica de fora; sem nenhum, usa o som do taco)
const PATHS_PUNCH := ["res://audio/punch1.wav", "res://audio/punch2.wav", "res://audio/punch3.wav",
		"res://audio/punch4.wav", "res://audio/punch5.wav"]

# Volumes (dB; 0 = original, negativo = mais baixo)
const MUSIC_DB_MENU := -10.0     # música no menu
const MUSIC_DB_MATCH := -17.0    # música durante a partida (deixa os efeitos aparecerem)
const WALL_DB_SOFT := -14.0      # batida fraca na parede
const WALL_DB_HARD := -3.0       # batida forte
const HIT_DB_SOFT := -16.0       # toque leve do taco
const HIT_DB_HARD := -5.0        # tacada forte
const WHISTLE_DB := -2.0
const CROWD_DB := -3.0
const PUNCH_DB_SOFT := -9.0      # soco fraco
const PUNCH_DB_HARD := -1.0      # soco forte

# Vibração
const WALL_BUZZ_MS := 22         # parede: curta, mas já dá para sentir...
const WALL_BUZZ_MIN := 0.16      # ...(amplitude 0..1)
const WALL_BUZZ_MAX := 0.45
const HIT_BUZZ_MS := 12          # taco no disco: ainda mais sutil que a parede
const HIT_BUZZ_MIN := 0.08
const HIT_BUZZ_MAX := 0.20
const HIT_BUZZ_MIN_IMPACT := 80.0     # toques mais leves que isso (px/s) não vibram
const WALL_BUZZ_MIN_IMPACT := 120.0   # batidas mais fracas que isso (px/s) não vibram
const GOAL_BUZZ_MS := 220        # gol: bem mais evidente
const GOAL_BUZZ_AMP := 1.0

# Ligar/desligar (para uma futura tela de opções)
static var music_enabled := true
static var sfx_enabled := true
static var vibration_enabled := true

static var _inst: GameAudio

var _music: AudioStreamPlayer
var _wall: AudioStreamPlayer
var _hit: AudioStreamPlayer
var _whistle_start: AudioStreamPlayer
var _whistle_end: AudioStreamPlayer
var _crowd: AudioStreamPlayer
var _punches: Array[AudioStreamPlayer] = []
var _last_punch_ms := 0
var _last_punch_buzz_ms := 0
var _last_punch_idx := -1
var _music_tween: Tween
var _last_wall_ms := 0
var _last_buzz_ms := 0
var _last_hit_ms := 0
var _last_hit_buzz_ms := 0
var _in_match := false

# ---------------------------------------------------------------- API estática

# Cria (uma vez) e pendura na raiz. Pode ser chamado de qualquer _ready.
static func ensure(tree: SceneTree) -> void:
	if _inst != null and is_instance_valid(_inst):
		return
	_inst = GameAudio.new()
	_inst.name = "GameAudio"
	tree.root.add_child.call_deferred(_inst)   # a raiz está ocupada durante o _ready

static func _ready_inst() -> bool:
	return _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree()

## Disco bateu na parede. impact = velocidade contra a parede (px/s).
static func wall(impact: float) -> void:
	if _ready_inst():
		_inst._on_wall(impact)

## Taco bateu no disco. impact = velocidade de aproximação (px/s); mine = foi o meu taco (só ele vibra).
static func hit(impact: float, mine: bool) -> void:
	if _ready_inst():
		_inst._on_hit(impact, mine)

static func goal() -> void:
	if not _ready_inst():
		return
	_inst._play(_inst._crowd, sfx_enabled)
	vibrate(GOAL_BUZZ_MS, GOAL_BUZZ_AMP)

## Soco do X1: sorteia um dos sons, com volume e tom levemente aleatórios.
## strength 0..1 (força do golpe); buzz = vibração curtinha (só nos meus toques).
static func punch(strength: float = 0.7, buzz: bool = false) -> void:
	if _ready_inst():
		_inst._on_punch(strength, buzz)

static func whistle_start() -> void:
	if _ready_inst():
		_inst._play(_inst._whistle_start, sfx_enabled)

static func whistle_end() -> void:
	if _ready_inst():
		_inst._play(_inst._whistle_end, sfx_enabled)

## true durante a partida: a música abaixa um pouco.
static func set_in_match(in_match: bool) -> void:
	if _ready_inst():
		_inst._fade_music(in_match)
	elif _inst != null:
		_inst._in_match = in_match   # ainda entrando na árvore: aplica no _ready

static func vibrate(ms: int, amplitude: float) -> void:
	if vibration_enabled:
		Input.vibrate_handheld(ms, amplitude)   # no PC não faz nada

# ---------------------------------------------------------------- internos

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_music = _make_player(PATH_THEME, MUSIC_DB_MATCH if _in_match else MUSIC_DB_MENU, true)
	_wall = _make_player(PATH_WALL, WALL_DB_SOFT, false, 4)   # até 4 batidas sobrepostas
	_hit = _make_player(PATH_HIT, HIT_DB_SOFT, false, 4)
	_whistle_start = _make_player(PATH_WHISTLE_START, WHISTLE_DB)
	_whistle_end = _make_player(PATH_WHISTLE_END, WHISTLE_DB)
	_crowd = _make_player(PATH_CROWD, CROWD_DB)
	for path in PATHS_PUNCH:
		var pp := _make_player(path, PUNCH_DB_SOFT, false, 2)
		if pp.stream != null:
			_punches.append(pp)
	if music_enabled and _music.stream != null:
		_music.play()

func _make_player(path: String, db: float, loop := false, polyphony := 1) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = db
	p.max_polyphony = polyphony
	if ResourceLoader.exists(path):
		var s: AudioStream = load(path)
		if loop:
			if s is AudioStreamOggVorbis:
				s.loop = true
			elif s is AudioStreamWAV:
				s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		p.stream = s
	add_child(p)
	return p

func _play(p: AudioStreamPlayer, enabled: bool) -> void:
	if enabled and p.stream != null:
		p.play()

func _on_wall(impact: float) -> void:
	var now := Time.get_ticks_msec()
	var k := clampf(impact / 500.0, 0.0, 1.0)
	if sfx_enabled and _wall.stream != null and now - _last_wall_ms > 45:
		_last_wall_ms = now
		_wall.volume_db = lerpf(WALL_DB_SOFT, WALL_DB_HARD, k)   # mais forte = mais alto
		_wall.pitch_scale = randf_range(0.94, 1.06)              # varia um pouco p/ não cansar
		_wall.play()
	if impact >= WALL_BUZZ_MIN_IMPACT and now - _last_buzz_ms > 90:
		_last_buzz_ms = now
		vibrate(WALL_BUZZ_MS, lerpf(WALL_BUZZ_MIN, WALL_BUZZ_MAX, k))

func _on_hit(impact: float, mine: bool) -> void:
	var now := Time.get_ticks_msec()
	var k := clampf(impact / 700.0, 0.0, 1.0)
	if sfx_enabled and _hit.stream != null and now - _last_hit_ms > 45:
		_last_hit_ms = now
		_hit.volume_db = lerpf(HIT_DB_SOFT, HIT_DB_HARD, k)
		_hit.pitch_scale = randf_range(0.95, 1.05)
		_hit.play()
	if mine and impact >= HIT_BUZZ_MIN_IMPACT and now - _last_hit_buzz_ms > 90:
		_last_hit_buzz_ms = now
		vibrate(HIT_BUZZ_MS, lerpf(HIT_BUZZ_MIN, HIT_BUZZ_MAX, k))

func _on_punch(strength: float, buzz: bool) -> void:
	var now := Time.get_ticks_msec()
	var k := clampf(strength, 0.0, 1.0)
	if sfx_enabled and now - _last_punch_ms > 40:
		_last_punch_ms = now
		if _punches.is_empty():
			_on_hit(lerpf(150.0, 700.0, k), false)   # sem arquivos de soco: usa o som do taco no disco
		else:
			var idx := randi() % _punches.size()
			if _punches.size() > 1 and idx == _last_punch_idx:
				idx = (idx + 1 + randi() % (_punches.size() - 1)) % _punches.size()   # nunca o mesmo duas vezes seguidas
			_last_punch_idx = idx
			var p := _punches[idx]
			p.volume_db = lerpf(PUNCH_DB_SOFT, PUNCH_DB_HARD, k) + randf_range(-1.5, 1.5)
			p.pitch_scale = randf_range(0.88, 1.15)
			p.play()
	if buzz and now - _last_punch_buzz_ms > 90:
		_last_punch_buzz_ms = now
		vibrate(14, lerpf(0.25, 0.6, k))

func _fade_music(in_match: bool) -> void:
	_in_match = in_match
	if _music_tween:
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(_music, "volume_db", MUSIC_DB_MATCH if in_match else MUSIC_DB_MENU, 0.8)
