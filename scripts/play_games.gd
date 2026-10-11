extends Node
## Autoload "PlayGames": camada fina sobre o plugin Google Play Games Services (v3+).
## O resto do jogo só fala com ESTE script. Sem o plugin (PC, plugin desligado,
## sem login) tudo vira "não faz nada" e o jogo funciona normalmente.
##
## Registro: Project Settings > Autoload > play_games.gd, nome "PlayGames".
## Deixe-o DEPOIS do autoload do plugin na lista.
##
## Como o plugin v3 funciona (README):
##  - o autoload principal precisa ser inicializado manualmente (initialize());
##  - os clientes (login, conquistas, placares...) são NÓS, criados por nós aqui;
##  - não há verificação automática de login: pedimos nós mesmos.

signal sign_in_changed(signed_in: bool)
signal avatar_changed          # a foto do perfil chegou (ou veio do cache)
signal name_changed            # o nome do perfil chegou (ou veio do cache)

# IDs criados no Play Console (Play Games Services > Placares / Conquistas).
# Substitua pelos seus (começam com "CgkI...").
const LEADERBOARD_ONLINE_WINS := "CgkIhvHshOkcEAIQAQ"
# Placar de taxa de vitórias online. Deixe "" até criar no Play Console (envio desligado).
# Crie como Numérico, 2 casas decimais, "maior é melhor". Enviamos a taxa x 100
# (66,67% -> 6667). Atenção: o Play Games guarda só a MELHOR pontuação de cada jogador,
# então este placar mostra a melhor taxa já alcançada (batizar como "Melhor taxa").
const LEADERBOARD_WIN_RATE := ""
const MIN_RATED_MATCHES := 10   # partidas online mínimas para entrar no placar de taxa

# --- XP e nível (progressão visual; conta todas as partidas terminadas) ---
const XP_MATCH := 20                 # terminar uma partida
const XP_WIN := 30                   # vencer
const XP_ONLINE_WIN := 20            # bônus: vitória online válida (ranking)
const XP_CPU_WIN := [0, 5, 10]       # bônus: vitória contra a CPU (fácil, normal, difícil)
const XP_PER_GOAL := 2
const XP_GOALS_CAP := 10             # gols que rendem XP por partida
const ACH_FIRST_WIN := "COLOQUE_O_ID"      # primeira vitória
const ACH_WINS_10 := "COLOQUE_O_ID"        # 10 vitórias
const ACH_BEAT_HARD := "COLOQUE_O_ID"      # vencer a CPU no difícil
const ACH_GOALS_100 := "COLOQUE_O_ID"      # 100 gols marcados
const PLUGIN_DIR := "res://addons/GodotPlayGameServices/"
const STATS_PATH := "user://stats.cfg"
const AVATAR_PATH := "user://avatar.jpg"   # cache da foto: aparece já na próxima abertura do jogo
const NAME_MAX := 10                      # tamanho máximo do nome no jogo
const CUSTOM_AVATAR_PATH := "user://avatar_custom.jpg"   # foto escolhida pela pessoa (vale mais que a do Google)
const AVATAR_PX := 64                      # a foto é reduzida para 64x64 (leve para mandar ao rival)

# O README chama o autoload principal de GodotPlayGamesServices; a pasta do plugin
# é GodotPlayGameServices. Tentamos os dois nomes por segurança.
const MAIN_AUTOLOAD_NAMES := ["GodotPlayGamesServices", "GodotPlayGameServices"]

var signed_in := false
var status := "desligado (não é Android)"

# estatísticas (guardadas no aparelho)
var wins := 0            # todas as vitórias (CPU + online): alimentam as conquistas
var online_wins := 0     # só online: alimenta o placar (não dá para "farmar" contra a CPU)
var losses := 0
var goals := 0
var hard_wins := 0       # vitórias contra a CPU no difícil
# Partidas VALIDAS para o ranking: só pela internet, contra pessoa. Contam a partir da
# versão que criou este recurso (derrotas online antigas não foram guardadas).
var rated_wins := 0
var rated_losses := 0
var xp := 0
var last_xp_gain := 0        # XP da última partida (para mostrar no fim)
var last_level_up := false   # a última partida fez subir de nível?

# foto do perfil Google, reduzida e em JPEG (~3 KB): é o que se envia ao rival pela rede
var my_avatar_jpg := PackedByteArray()

# nome do perfil Google (vazio = ainda não veio / sem Play Games)
var my_name := ""
# nome escolhido pela pessoa no card do perfil (vale mais que o do Google)
var custom_name := ""

var _players: Node
var _http: HTTPRequest
var _sign_in: Node
var _ach: Node
var _lb: Node
var _tried_sign_in := false


func _ready() -> void:
	status = "iniciando"
	_load_stats()
	_load_cached_avatar()
	if OS.get_name() != "Android":
		return
	# espera um frame: garante que os autoloads do plugin já existem
	_start_plugin.call_deferred()

func _start_plugin() -> void:
	if not _init_main_autoload():
		status = "ERRO: autoload do plugin não encontrado"
		return
	_sign_in = _make_client("sign_in_client.gd")
	_ach = _make_client("achievements_client.gd")
	_lb = _make_client("leaderboards_client.gd")
	_players = _make_client("players_client.gd")
	if _players != null and _players.has_signal("current_player_loaded"):
		_players.connect("current_player_loaded", _on_player_loaded)
	if _sign_in == null:
		status = "ERRO: sign_in_client.gd não achado. addons=" + str(DirAccess.get_directories_at("res://addons"))
		return
	if not _sign_in.has_signal("user_authenticated") or not _sign_in.has_method("is_authenticated"):
		status = "ERRO nomes: " + _describe(_sign_in)
		return
	_sign_in.connect("user_authenticated", _on_authenticated)
	_sign_in.call("is_authenticated")
	status = "aguardando resposta do login"

# Procura um arquivo pelo nome, em qualquer subpasta de dir_path.
# No jogo exportado, scripts aparecem como "arquivo.gd.remap": removemos o sufixo.
func _find_file(dir_path: String, file_name: String) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	for f in dir.get_files():
		var n := String(f).trim_suffix(".remap")
		if n == file_name:
			return dir_path.path_join(n)
	for d in dir.get_directories():
		var r := _find_file(dir_path.path_join(d), file_name)
		if r != "":
			return r
	return ""

# Inicialização manual exigida pelo plugin (README, seção "Philosophy").
func _init_main_autoload() -> bool:
	for n in MAIN_AUTOLOAD_NAMES:
		var node := get_node_or_null("/root/" + n)
		if node != null:
			node.call("initialize")
			return true
	return false

# Cria o nó de um cliente carregando o script direto pelo caminho.
func _make_client(file_name: String) -> Node:
	var path := _find_file("res://addons", file_name)
	if path == "":
		return null
	var node = load(path).new()
	add_child(node)
	return node

# Lista sinais e métodos que o script do cliente realmente define (para depurar nomes).
func _describe(node: Node) -> String:
	var sigs: Array[String] = []
	var mets: Array[String] = []
	var scr: Script = node.get_script()
	for s in scr.get_script_signal_list():
		sigs.append(s["name"])
	for m in scr.get_script_method_list():
		if not String(m["name"]).begins_with("_"):
			mets.append(m["name"])
	return "sinais=%s metodos=%s" % [sigs, mets]

func _on_authenticated(is_authenticated: bool) -> void:
	if not is_authenticated and not _tried_sign_in:
		_tried_sign_in = true
		status = "abrindo tela de login"
		_sign_in.call("sign_in")
		return
	signed_in = is_authenticated
	status = "LOGADO" if signed_in else "não logado (login recusado ou falhou)"
	print("[PlayGames] login: ", signed_in)
	sign_in_changed.emit(signed_in)
	if signed_in:
		_sync()
		_load_profile()

## Para um botão "Entrar com Google", se o login falhou.
func sign_in() -> void:
	if _sign_in != null:
		_tried_sign_in = true
		_sign_in.call("sign_in")

# ------------------------------------------------------------ partida

## Chame UMA vez no fim de cada partida, em cada aparelho, com o resultado dele.
## finished = false para desistência no meio da partida (não rende XP).
func record_match(won: bool, my_goals: int, vs_cpu: bool, cpu_level: int, finished: bool = true) -> void:
	# Só conta para o ranking partida pela internet (sala WebRTC). Teste por IP/Wi-Fi
	# e CPU não valem, para ninguém "farmar" jogando contra o próprio aparelho.
	var ranked := not vs_cpu and Net.is_ranked_match()
	goals += my_goals
	if won:
		wins += 1
		if vs_cpu:
			if cpu_level == 2:
				hard_wins += 1
		elif ranked:
			online_wins += 1
			rated_wins += 1
	else:
		losses += 1
		if ranked:
			rated_losses += 1
	last_xp_gain = 0
	last_level_up = false
	if finished:
		var before := level()
		last_xp_gain = _calc_xp(won, my_goals, vs_cpu, cpu_level, ranked)
		xp += last_xp_gain
		last_level_up = level() > before
	_save_stats()
	_sync()

func _calc_xp(won: bool, my_goals: int, vs_cpu: bool, cpu_level: int, ranked: bool) -> int:
	var gain := XP_MATCH + XP_PER_GOAL * mini(my_goals, XP_GOALS_CAP)
	if won:
		gain += XP_WIN
		if vs_cpu:
			gain += int(XP_CPU_WIN[clampi(cpu_level, 0, XP_CPU_WIN.size() - 1)])
		elif ranked:
			gain += XP_ONLINE_WIN
	return gain

## Dificuldade da CPU do jogo rápido, pelo nível do jogador (0 fácil, 1 normal, 2 difícil).
const CPU_NORMAL_FROM_LEVEL := 4
const CPU_HARD_FROM_LEVEL := 12

func cpu_level_for_xp() -> int:
	var lv := level()
	if lv >= CPU_HARD_FROM_LEVEL:
		return 2
	if lv >= CPU_NORMAL_FROM_LEVEL:
		return 1
	return 0

# XP necessário para sair do nível lv para o lv+1 (100, 140, 180, ...)
func xp_to_next(lv: int) -> int:
	return 100 + 40 * (lv - 1)

func level() -> int:
	var lv := 1
	var rest := xp
	while rest >= xp_to_next(lv):
		rest -= xp_to_next(lv)
		lv += 1
	return lv

## [XP dentro do nível atual, XP que o nível pede]
func level_progress() -> Vector2i:
	var lv := 1
	var rest := xp
	while rest >= xp_to_next(lv):
		rest -= xp_to_next(lv)
		lv += 1
	return Vector2i(rest, xp_to_next(lv))

func rated_matches() -> int:
	return rated_wins + rated_losses

## Taxa de vitórias online, 0 a 100.
func win_rate_pct() -> float:
	var n := rated_matches()
	return 100.0 * float(rated_wins) / float(n) if n > 0 else 0.0

## Linha de resumo para o menu ("" enquanto não há partida online válida).
func profile_text() -> String:
	var n := rated_matches()
	if n == 0:
		return ""
	var line := "Online: %d V · %d D · %d%%" % [rated_wins, rated_losses, int(round(win_rate_pct()))]
	if n < MIN_RATED_MATCHES:
		line += "\nFaltam %d partidas para o ranking" % (MIN_RATED_MATCHES - n)
	return line

# Envia placar e conquistas. Reenviar é inofensivo: o Play Games ignora
# conquista já desbloqueada e só guarda o melhor valor do placar.
func _sync() -> void:
	if not signed_in:
		return
	if _lb != null and online_wins > 0:
		_lb.call("submit_score", LEADERBOARD_ONLINE_WINS, online_wins)
	if _lb != null and LEADERBOARD_WIN_RATE != "" and rated_matches() >= MIN_RATED_MATCHES:
		_lb.call("submit_score", LEADERBOARD_WIN_RATE, int(round(win_rate_pct() * 100.0)))
	if wins >= 1:
		_unlock(ACH_FIRST_WIN)
	if wins >= 10:
		_unlock(ACH_WINS_10)
	if hard_wins >= 1:
		_unlock(ACH_BEAT_HARD)
	if goals >= 100:
		_unlock(ACH_GOALS_100)

func _unlock(id: String) -> void:
	if _ach != null:
		_ach.call("unlock_achievement", id)

# ------------------------------------------------------------ telas do Google

func show_leaderboard() -> void:
	if signed_in and _lb != null:
		_lb.call("show_all_leaderboards")

func show_achievements() -> void:
	if signed_in and _ach != null:
		_ach.call("show_achievements")

# ------------------------------------------------------------ estatísticas locais

func _load_stats() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STATS_PATH) != OK:
		return
	wins = int(cfg.get_value("stats", "wins", 0))
	online_wins = int(cfg.get_value("stats", "online_wins", 0))
	losses = int(cfg.get_value("stats", "losses", 0))
	goals = int(cfg.get_value("stats", "goals", 0))
	hard_wins = int(cfg.get_value("stats", "hard_wins", 0))
	rated_wins = int(cfg.get_value("stats", "rated_wins", 0))
	rated_losses = int(cfg.get_value("stats", "rated_losses", 0))
	xp = int(cfg.get_value("stats", "xp", 0))
	my_name = str(cfg.get_value("profile", "name", ""))
	custom_name = str(cfg.get_value("profile", "custom_name", ""))

func _save_stats() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "wins", wins)
	cfg.set_value("stats", "online_wins", online_wins)
	cfg.set_value("stats", "losses", losses)
	cfg.set_value("stats", "goals", goals)
	cfg.set_value("stats", "hard_wins", hard_wins)
	cfg.set_value("stats", "rated_wins", rated_wins)
	cfg.set_value("stats", "rated_losses", rated_losses)
	cfg.set_value("stats", "xp", xp)
	cfg.set_value("profile", "name", my_name)
	cfg.set_value("profile", "custom_name", custom_name)
	cfg.save(STATS_PATH)

# ------------------------------------------------------------ foto do perfil

# Pede o jogador atual ao Play Games (resposta no sinal current_player_loaded)
func _load_profile() -> void:
	if _players != null:
		_players.call("load_current_player", true)

func _on_player_loaded(player: Object) -> void:
	if player == null:
		return
	# Nome de exibição (lido antes da foto: o jogador pode ter nome e não ter foto)
	for prop in ["display_name", "name"]:
		var nv: Variant = player.get(prop)
		if nv != null and str(nv).strip_edges() != "" and str(nv) != "null":
			_set_my_name(str(nv))
			break
	# Prefere o ícone (menor); se não houver, a versão em alta resolução.
	var uri := ""
	for prop in ["icon_image_uri", "hi_res_image_uri"]:
		var v: Variant = player.get(prop)
		if v != null and str(v) != "" and str(v) != "null":
			uri = str(v)
			break
	if uri == "":
		# nomes dos campos do PlayGamesPlayer, para ajustar se o plugin usar outros
		var names: Array[String] = []
		for pr in player.get_property_list():
			if int(pr["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				names.append(pr["name"])
		print("[PlayGames] jogador sem foto. campos: ", names)
		return
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_avatar_downloaded)
	_http.cancel_request()
	var err := _http.request(uri)
	if err != OK:
		print("[PlayGames] erro ao pedir a foto: ", error_string(err))

# Nome que vale no jogo: o escolhido > o do Google > vazio (o jogo mostra "Você")
func player_name() -> String:
	return custom_name if custom_name != "" else my_name

func has_custom_avatar() -> bool:
	return FileAccess.file_exists(CUSTOM_AVATAR_PATH)

func has_custom_profile() -> bool:
	return custom_name != "" or has_custom_avatar()

func set_custom_name(n: String) -> void:
	custom_name = n.replace("\n", " ").strip_edges().substr(0, NAME_MAX)
	_save_stats()
	name_changed.emit()

## Troca a foto por uma imagem do aparelho (png/jpg/webp). false = não deu para ler.
func set_custom_avatar_from_file(path: String) -> bool:
	var img := _decode_image(FileAccess.get_file_as_bytes(path))
	if img == null:
		return false
	_set_my_avatar(img, CUSTOM_AVATAR_PATH)
	return true

## Volta ao nome e à foto do Google (ou ao padrão do jogo, se não houver).
func reset_profile() -> void:
	custom_name = ""
	_save_stats()
	if has_custom_avatar():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CUSTOM_AVATAR_PATH))
	my_avatar_jpg = PackedByteArray()
	UIStyle.my_avatar = null
	_load_cached_avatar()
	avatar_changed.emit()
	name_changed.emit()

func _set_my_name(n: String) -> void:
	n = n.strip_edges().substr(0, NAME_MAX)
	if n == "" or n == my_name:
		return
	my_name = n
	_save_stats()
	name_changed.emit()

func _on_avatar_downloaded(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		print("[PlayGames] foto não baixou (result=%d, http=%d)" % [result, code])
		return
	var img := _decode_image(body)
	if img != null:
		_set_my_avatar(img, AVATAR_PATH, not has_custom_avatar())   # foto escolhida pela pessoa não é trocada

# Decide o formato pelos primeiros bytes (o Google pode servir jpg, png ou webp)
func _decode_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0x52 and bytes[1] == 0x49:   # "RI" de RIFF/WEBP
		err = img.load_webp_from_buffer(bytes)
	return img if err == OK else null

# Recorta em quadrado, reduz e (se save_path) guarda em arquivo. Com apply, vira a foto atual
# (textura + JPEG para a rede) e avisa o jogo.
@warning_ignore("integer_division")
func _set_my_avatar(img: Image, save_path: String = "", apply := true) -> void:
	var side := mini(img.get_width(), img.get_height())
	var sq := img.get_region(Rect2i((img.get_width() - side) / 2, (img.get_height() - side) / 2, side, side))
	sq.convert(Image.FORMAT_RGB8)
	sq.resize(AVATAR_PX, AVATAR_PX, Image.INTERPOLATE_LANCZOS)
	var jpg: PackedByteArray = sq.save_jpg_buffer(0.85)
	if save_path != "":
		var f := FileAccess.open(save_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(jpg)
	if not apply:
		return
	my_avatar_jpg = jpg
	UIStyle.my_avatar = ImageTexture.create_from_image(sq)
	avatar_changed.emit()

# Foto escolhida > cache da foto do Google
func _load_cached_avatar() -> void:
	var path := CUSTOM_AVATAR_PATH if has_custom_avatar() else AVATAR_PATH
	if not FileAccess.file_exists(path):
		return
	var img := _decode_image(FileAccess.get_file_as_bytes(path))
	if img != null:
		_set_my_avatar(img)
