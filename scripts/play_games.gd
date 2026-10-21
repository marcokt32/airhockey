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
signal stats_restored          # progresso (XP, vitórias...) foi recuperado da nuvem (reinstalou o app)

# IDs criados no Play Console (Play Games Services > Placares / Conquistas).
# Substitua pelos seus (começam com "CgkI...").
const LEADERBOARD_ONLINE_WINS := "CgkIhvHshOkcEAIQAQ"
# Placar "XP total": serve de BACKUP do XP na nuvem do Google (sobrevive a desinstalar o app).
# Crie no Play Console como Numérico, 0 casas, "maior é melhor", e cole o ID aqui.
# Deixe "" até criar (envio e restauração ficam desligados).
const LEADERBOARD_XP := ""
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
# IDs e regras das conquistas: veja achievements.gd
# --- Jogos Salvos (nuvem do Google): guarda o perfil inteiro num JSON ---
# Pré-requisito: Play Console > Play Games Services > Configuração > ativar "Jogos salvos".
const SAVE_FILE := "profile"         # nome do arquivo na nuvem (a-z, 0-9, - . _ ~)
const SAVE_VERSION := 1
# Contadores que só SOBEM: ao juntar nuvem + aparelho vale o MAIOR de cada um (nunca perde progresso)
const COUNTER_KEYS := ["wins", "online_wins", "losses", "goals", "hard_wins", "rated_wins", "rated_losses", "xp",
		"cpu_wins", "online_played", "matches", "days_played"]
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

# --- Conquistas (ver achievements.gd) ---
var cpu_wins := 0            # vitórias contra a CPU
var online_played := 0       # partidas online válidas (ranking) terminadas
var matches := 0             # partidas terminadas (todos os modos)
var days_played := 0         # dias diferentes em que terminou uma partida
var last_play_day := ""
var cpu_mask := 0            # bits dos níveis da CPU já vencidos (1 fácil, 2 normal, 4 difícil)
var win_streak := 0          # vitórias seguidas (só no aparelho)
var loss_streak := 0         # derrotas seguidas
var online_win_streak := 0   # vitórias seguidas em partidas válidas online
var rival_wins := {}         # uid do rival -> vitórias contra ele (Meu freguês)
var _earned := {}            # conquistas já ganhas (chave -> true); vão para a nuvem
var _steps_sent := {}        # ID -> último progresso enviado (conquistas incrementais)
var _sent_session := {}      # chaves já enviadas ao Google nesta abertura do jogo
var _last_rival_uid := ""
var _last_rival_lost := false
var _dirty := false          # ganhou conquista fora de uma partida: precisa salvar

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
var _restore_connected := false
var _snap: Node                 # cliente de Jogos Salvos
var _cloud_ready := false       # só envia à nuvem DEPOIS de ler o que já existe lá (senão zera o perfil)
var _load_tries := 0
var _conflict_retries := 0


func _ready() -> void:
	status = "iniciando"
	_load_stats()
	_evaluate()      # quem já tinha progresso ganha as conquistas que já merecia
	_save_stats()
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
	_snap = _make_client("snapshots_client.gd")
	if _snap != null:
		if _snap.has_signal("game_loaded"):
			_snap.connect("game_loaded", _on_game_loaded)
		if _snap.has_signal("game_saved"):
			_snap.connect("game_saved", _on_game_saved)
		if _snap.has_signal("conflict_emitted"):
			_snap.connect("conflict_emitted", _on_save_conflict)
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
	# O Google às vezes ainda não terminou o login automático quando perguntamos pela 1ª vez:
	# reconfirma em silêncio, para os botões Placar/Conquistas não ficarem escondidos à toa.
	for delay in [3.0, 8.0]:
		get_tree().create_timer(delay).timeout.connect(_recheck_sign_in)

# Pergunta de novo se já está logado (nunca abre tela de login).
func _recheck_sign_in() -> void:
	if signed_in or _sign_in == null:
		return
	_sign_in.call("is_authenticated")

# Voltou de outro app (ex.: terminou o login no Play Games): confere o estado.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_recheck_sign_in()

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
	# Sem sign_in() automático: o Google já loga sozinho quem tem perfil no Play Games.
	# Quem não está logado gerencia a conta por fora (app Play Games); aqui só reconferimos.
	var changed := signed_in != is_authenticated
	signed_in = is_authenticated
	status = "LOGADO" if signed_in else "não logado (login recusado ou falhou)"
	print("[PlayGames] login: ", signed_in)
	sign_in_changed.emit(signed_in)   # sempre emite: o menu só mostra os botões por este aviso
	if signed_in and changed:
		_load_cloud_save()
		_restore_from_cloud()
		_sync()
		_load_profile()

## Só para um botão manual "Entrar com Google" (abre a escolha de conta). Não é chamado sozinho.
func sign_in() -> void:
	if _sign_in != null:
		_sign_in.call("sign_in")
		# confere de novo em silêncio, caso o aviso do login não chegue
		for delay in [2.0, 5.0]:
			get_tree().create_timer(delay).timeout.connect(_recheck_sign_in)

# ------------------------------------------------------------ partida

## Chame UMA vez no fim de cada partida, em cada aparelho, com o resultado dele.
## finished = false para desistência no meio da partida (não rende XP).
## opp_goals / max_deficit / max_run alimentam as conquistas (placar do rival, maior desvantagem
## que o jogador teve, maior sequência de gols seguidos).
func record_match(won: bool, my_goals: int, vs_cpu: bool, cpu_level: int, finished: bool = true,
		opp_goals: int = 0, max_deficit: int = 0, max_run: int = 0) -> void:
	# Só conta para o ranking partida pela internet (sala WebRTC). Teste por IP/Wi-Fi
	# e CPU não valem, para ninguém "farmar" jogando contra o próprio aparelho.
	var ranked := not vs_cpu and Net.is_ranked_match()
	goals += my_goals
	if won:
		wins += 1
		win_streak += 1
		loss_streak = 0
		if vs_cpu:
			cpu_wins += 1
			cpu_mask |= 1 << clampi(cpu_level, 0, 2)
			if cpu_level == 2:
				hard_wins += 1
		elif ranked:
			online_wins += 1
			rated_wins += 1
			online_win_streak += 1
	else:
		losses += 1
		loss_streak += 1
		win_streak = 0
		if ranked:
			rated_losses += 1
			online_win_streak = 0
	last_xp_gain = 0
	last_level_up = false
	if finished:
		var before := level()
		last_xp_gain = _calc_xp(won, my_goals, vs_cpu, cpu_level, ranked)
		xp += last_xp_gain
		last_level_up = level() > before
		matches += 1
		if ranked:
			online_played += 1
		_count_play_day()
		_check_match_achievements(won, my_goals, opp_goals, vs_cpu, cpu_level, ranked, max_deficit, max_run)
	_evaluate()
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
	if _lb != null and LEADERBOARD_XP != "" and xp > 0:
		_lb.call("submit_score", LEADERBOARD_XP, xp)   # o placar guarda só o maior: XP só sobe, então serve
	if _lb != null and LEADERBOARD_WIN_RATE != "" and rated_matches() >= MIN_RATED_MATCHES:
		_lb.call("submit_score", LEADERBOARD_WIN_RATE, int(round(win_rate_pct() * 100.0)))
	_sync_achievements()
	_push_cloud()

# ------------------------------------------------------------ perfil na nuvem (Jogos Salvos)

# Pede o perfil salvo. A resposta chega em _on_game_loaded.
func _load_cloud_save() -> void:
	if _snap == null:
		return
	_cloud_ready = false
	_snap.call("load_game", SAVE_FILE, false)

func _on_game_loaded(snapshot: Variant) -> void:
	if snapshot == null:
		# Sem save na nuvem (primeira vez) OU falha de leitura: tenta mais uma vez antes de assumir "vazio"
		if _load_tries < 3:
			_load_tries += 1
			get_tree().create_timer(3.0 * _load_tries).timeout.connect(_load_cloud_save)
			return
		print("[PlayGames] nenhum perfil na nuvem: este vira o primeiro")
		_cloud_ready = true
		_push_cloud()
		return
	_load_tries = 0
	var remote := _parse_save(snapshot.get("content"))
	print("[PlayGames] perfil da nuvem: xp=%s nome=%s" % [remote.get("xp", 0), remote.get("custom_name", "")])
	_apply_remote(remote)
	_cloud_ready = true
	if _remote_is_stale(remote):
		_push_cloud()

# Junta o perfil da nuvem com o do aparelho e avisa o jogo se algo mudou.
func _apply_remote(remote: Dictionary) -> void:
	var name_before := custom_name
	if _merge_remote(remote):
		_evaluate()
		_sync_achievements()
		_save_stats()
		stats_restored.emit()
		if custom_name != name_before:
			name_changed.emit()

# Contadores: maior valor vence. Nome/foto escolhidos: só entram se o aparelho ainda não tem.
func _merge_remote(remote: Dictionary) -> bool:
	var changed := false
	for k in COUNTER_KEYS:
		var rv := int(remote.get(k, 0))
		if rv > int(get(k)):
			set(k, rv)
			changed = true
	var rmask := int(remote.get("cpu_mask", 0))
	if (cpu_mask | rmask) != cpu_mask:
		cpu_mask |= rmask
		changed = true
	var rach: Variant = remote.get("ach", [])
	if rach is Array:
		for k in rach:
			var ks := str(k)
			if Achievements.has_key(ks) and not _earned.has(ks):
				_earned[ks] = true
				changed = true
	var rn := str(remote.get("custom_name", "")).strip_edges().substr(0, NAME_MAX)
	if custom_name == "" and rn != "":
		custom_name = rn
		changed = true
	var av := str(remote.get("avatar", ""))
	if av != "" and not has_custom_avatar():
		var img := _decode_image(Marshalls.base64_to_raw(av))
		if img != null:
			_set_my_avatar(img, CUSTOM_AVATAR_PATH)   # emite avatar_changed
			changed = true
	return changed

# A nuvem está atrás do aparelho? (então vale reenviar)
func _remote_is_stale(remote: Dictionary) -> bool:
	for k in COUNTER_KEYS:
		if int(get(k)) > int(remote.get(k, 0)):
			return true
	if (cpu_mask & ~int(remote.get("cpu_mask", 0))) != 0:
		return true
	var rach: Variant = remote.get("ach", [])
	for k in _earned:
		if not (rach is Array) or not (k in rach):
			return true
	if custom_name != str(remote.get("custom_name", "")):
		return true
	if has_custom_avatar() != (str(remote.get("avatar", "")) != ""):
		return true
	return false

func _has_progress() -> bool:
	return xp > 0 or wins > 0 or losses > 0 or goals > 0 or matches > 0 or not _earned.is_empty() \
			or custom_name != "" or has_custom_avatar()

func _to_save_dict() -> Dictionary:
	var d := {"v": SAVE_VERSION, "custom_name": custom_name, "saved_at": int(Time.get_unix_time_from_system())}
	for k in COUNTER_KEYS:
		d[k] = int(get(k))
	d["cpu_mask"] = cpu_mask
	d["ach"] = _earned.keys()
	d["avatar"] = ""
	if has_custom_avatar():   # 64x64 JPEG, ~3 KB: cabe fácil
		d["avatar"] = Marshalls.raw_to_base64(FileAccess.get_file_as_bytes(CUSTOM_AVATAR_PATH))
	return d

func _parse_save(bytes: Variant) -> Dictionary:
	if not (bytes is PackedByteArray):
		return {}
	var parsed: Variant = JSON.parse_string((bytes as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}

# Envia o perfil. Só depois de ler a nuvem e só se houver algo para guardar:
# assim um aparelho recém-instalado (tudo zero) nunca apaga o perfil que está lá.
func _push_cloud() -> void:
	if _snap == null or not signed_in or not _cloud_ready or not _has_progress():
		return
	var data := JSON.stringify(_to_save_dict()).to_utf8_buffer()
	_snap.call("save_game", SAVE_FILE, "Nv %d · %d XP" % [level(), xp], data, 0, xp)

func _on_game_saved(is_saved: bool, _save_name: String, _desc: String) -> void:
	print("[PlayGames] perfil salvo na nuvem: ", is_saved)
	if is_saved:
		_conflict_retries = 0

# Dois aparelhos salvaram ao mesmo tempo: junta as duas versões + a local e salva de novo.
func _on_save_conflict(conflict: Variant) -> void:
	if _conflict_retries >= 2:
		return
	_conflict_retries += 1
	for key in ["server_snapshot", "conflicting_snapshot"]:
		var s: Variant = conflict.get(key)
		if s != null:
			_apply_remote(_parse_save(s.get("content")))
	_cloud_ready = true
	_push_cloud()

# ------------------------------------------------------------ restauração pelo placar (opcional)

# Pede à nuvem o XP e as vitórias online do jogador. Se a nuvem tiver MAIS que o aparelho
# (ex.: app reinstalado), assume o valor da nuvem. Nunca diminui o progresso local.
# Atenção: o nome personalizado e a foto NÃO voltam por aqui (placar só guarda números).
func _restore_from_cloud() -> void:
	if _lb == null:
		return
	if not _restore_connected and _lb.has_signal("score_loaded"):
		# lambda tolerante: aceita 1 ou 2 argumentos, conforme a versão do plugin
		_lb.connect("score_loaded", func(a = null, b = null): _on_cloud_score(a, b))
		_restore_connected = true
	if LEADERBOARD_XP != "":
		_request_cloud_score(LEADERBOARD_XP)
	_request_cloud_score(LEADERBOARD_ONLINE_WINS)

func _request_cloud_score(board_id: String) -> void:
	# 2 = TIME_SPAN_ALL_TIME, 0 = COLLECTION_PUBLIC (valores do Google Play Games)
	if _lb.has_method("load_player_score"):
		_lb.call("load_player_score", board_id, 2, 0)

# Descobre o valor entre os argumentos do sinal (objeto com raw_score ou número) e aplica.
func _on_cloud_score(a: Variant, b: Variant) -> void:
	var board_id := ""
	var raw := -1
	for arg in [a, b]:
		if arg is String:
			board_id = arg
		elif arg is Object and arg != null:
			var v: Variant = arg.get("raw_score")
			if v != null:
				raw = int(v)
			var lid: Variant = arg.get("leaderboard_id")
			if board_id == "" and lid != null:
				board_id = str(lid)
		elif arg is int:
			raw = arg
	print("[PlayGames] placar da nuvem: id=%s valor=%d" % [board_id, raw])
	if raw < 0:
		return
	var changed := false
	if board_id == LEADERBOARD_XP and LEADERBOARD_XP != "" and raw > xp:
		xp = raw
		changed = true
	elif board_id == LEADERBOARD_ONLINE_WINS and raw > online_wins:
		online_wins = raw
		wins = maxi(wins, raw)
		changed = true
	if changed:
		_evaluate()
		_sync_achievements()
		_save_stats()
		stats_restored.emit()

# ------------------------------------------------------------ conquistas
# Fluxo: o jogo detecta o evento -> _earn(chave) guarda no aparelho (e na nuvem, via Jogos Salvos) ->
# se há login, envia ao Google. Sem login, é enviado quando o login chegar (_sync_achievements).

## Um gol aconteceu (chamado pelo main.gd em cada aparelho). mine = fui eu quem marcou.
## info = flags do puck (ver Achievements.GOAL_*).
func record_goal(mine: bool, info: int) -> void:
	var own := (info & Achievements.GOAL_OWN) != 0
	if mine:
		_earn("first_goal")
		if not own:   # gol que o rival fez contra si mesmo não vale como jogada
			if (info & Achievements.GOAL_FAST) != 0:
				_earn("lightning")
			if (info & Achievements.GOAL_ROCKET) != 0:
				_earn("rocket")
			if Achievements.goal_bounces(info) >= Achievements.RICOCHET_BOUNCES:
				_earn("ricochet")
	elif own:
		_earn("own_goal")   # eu mesmo mandei o disco para o meu gol
	if _dirty:
		_save_stats()

func _earn(key: String) -> void:
	if _earned.has(key) or not Achievements.has_key(key):
		return
	_earned[key] = true
	_dirty = true
	_unlock_key(key)

func _unlock_key(key: String) -> void:
	if not signed_in or _ach == null or _sent_session.has(key):
		return
	var id := Achievements.id_of(key)
	if not Achievements.is_valid_id(id):
		return
	_sent_session[key] = true
	_ach.call("unlock_achievement", id)

# Conquistas que dependem só dos contadores/nível (reavaliadas a cada partida e ao restaurar a nuvem)
func _evaluate() -> void:
	var lv := level()
	var checks := {
		"ice_breaker": cpu_wins >= 1,
		"rookie": online_played >= 1,
		"first_goal": goals >= 1,
		"welcome_arena": online_wins >= 1,
		"last_place": loss_streak >= 5,
		"unbeaten": win_streak >= 5,
		"unstoppable": win_streak >= 10,
		"hyped": online_win_streak >= 3,
		"hard_win": hard_wins >= 1,
		"dominator": cpu_mask == 7,
		"ranked_in": rated_matches() >= MIN_RATED_MATCHES,
		"elite_rate": rated_matches() >= Achievements.ELITE_MIN_MATCHES \
				and win_rate_pct() >= Achievements.ELITE_RATE,
		"level_5": lv >= 5,
		"level_10": lv >= 10,
		"level_20": lv >= 20,
		"level_30": lv >= 30,
	}
	for k in checks:
		if checks[k]:
			_earn(k)

# Conquistas que dependem do resultado da partida (só partidas terminadas)
func _check_match_achievements(won: bool, my_goals: int, opp_goals: int, vs_cpu: bool, cpu_level: int,
		ranked: bool, max_deficit: int, max_run: int) -> void:
	var diff := my_goals - opp_goals
	if won:
		if diff >= Achievements.BLOWOUT_DIFF:
			_earn("blowout")
		if diff == 1:
			_earn("nail_biter")
		if max_deficit >= Achievements.COMEBACK_DEFICIT:
			_earn("comeback")
		if opp_goals == 0:
			_earn("historic_rout")
		if vs_cpu and cpu_level == 2 and diff >= Achievements.BLOWOUT_DIFF:
			_earn("system_break")
	elif opp_goals == 7 and my_goals == 1:
		_earn("deja_vu")   # o 7 x 1 (a partida acaba quando alguém faz 7)
	if max_run >= Achievements.HAT_TRICK_RUN:
		_earn("hat_trick")
	if int(Time.get_time_dict_from_system().get("hour", 12)) < Achievements.NIGHT_OWL_UNTIL_HOUR:
		_earn("night_owl")
	_track_rival(won, ranked)

# Meu freguês (mesmo rival 2 vezes) e Vingança (vencer a revanche logo depois de perder)
func _track_rival(won: bool, ranked: bool) -> void:
	var uid := Net.rival_uid
	if not ranked or uid == "":
		_last_rival_uid = ""
		_last_rival_lost = false
		return
	if won:
		rival_wins[uid] = int(rival_wins.get(uid, 0)) + 1
		if int(rival_wins[uid]) >= Achievements.MY_CUSTOMER_WINS:
			_earn("my_customer")
		if uid == _last_rival_uid and _last_rival_lost:
			_earn("revenge")
	_last_rival_uid = uid
	_last_rival_lost = not won
	while rival_wins.size() > Achievements.RIVALS_KEPT:   # lembra só os mais recentes
		rival_wins.erase(rival_wins.keys()[0])

func _count_play_day() -> void:
	var today := Time.get_date_string_from_system()
	if today != last_play_day:
		last_play_day = today
		days_played += 1

# Envia ao Google o que já foi ganho (desbloqueios) e o progresso das incrementais
func _sync_achievements() -> void:
	if not signed_in or _ach == null:
		return
	for key in _earned:
		_unlock_key(key)
	var inc: Dictionary = Achievements.INCREMENTAL
	for key in inc:
		var steps: int = inc[key][1]
		var cur := mini(int(get(inc[key][0])), steps)
		if cur > 0:
			_set_steps(Achievements.id_of(key), cur)

# Progresso absoluto (idempotente). Se o plugin não tiver set_achievement_steps, envia só a diferença.
func _set_steps(id: String, n: int) -> void:
	if not Achievements.is_valid_id(id):
		return
	var sent := int(_steps_sent.get(id, 0))
	if n <= sent:
		return
	if _ach.has_method("set_achievement_steps"):
		_ach.call("set_achievement_steps", id, n)
	elif _ach.has_method("increment_achievement"):
		_ach.call("increment_achievement", id, n - sent)
	else:
		return
	_steps_sent[id] = n
	_save_stats()

# ------------------------------------------------------------ telas do Google

## Placar/Conquistas ficam sempre à mão no Android; no PC só aparecem logado (nunca está).
func can_show_social() -> bool:
	return signed_in or OS.get_name() == "Android"

## Se ainda não há login, o toque no botão tenta entrar (em vez de o botão sumir).
func show_leaderboard() -> void:
	if not signed_in:
		sign_in()
		return
	if _lb != null:
		_lb.call("show_all_leaderboards")

func show_achievements() -> void:
	if not signed_in:
		sign_in()
		return
	if _ach != null:
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
	cpu_wins = int(cfg.get_value("stats", "cpu_wins", 0))
	online_played = int(cfg.get_value("stats", "online_played", 0))
	matches = int(cfg.get_value("stats", "matches", 0))
	days_played = int(cfg.get_value("stats", "days_played", 0))
	cpu_mask = int(cfg.get_value("stats", "cpu_mask", 0))
	win_streak = int(cfg.get_value("stats", "win_streak", 0))
	loss_streak = int(cfg.get_value("stats", "loss_streak", 0))
	online_win_streak = int(cfg.get_value("stats", "online_win_streak", 0))
	last_play_day = str(cfg.get_value("stats", "last_play_day", ""))
	var earned_list: Variant = cfg.get_value("ach", "earned", [])
	if earned_list is Array:
		for k in earned_list:
			if Achievements.has_key(str(k)):
				_earned[str(k)] = true
	var rivals: Variant = cfg.get_value("ach", "rivals", {})
	if rivals is Dictionary:
		rival_wins = rivals
	var sent: Variant = cfg.get_value("ach", "steps_sent", {})
	if sent is Dictionary:
		_steps_sent = sent

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
	cfg.set_value("stats", "cpu_wins", cpu_wins)
	cfg.set_value("stats", "online_played", online_played)
	cfg.set_value("stats", "matches", matches)
	cfg.set_value("stats", "days_played", days_played)
	cfg.set_value("stats", "cpu_mask", cpu_mask)
	cfg.set_value("stats", "win_streak", win_streak)
	cfg.set_value("stats", "loss_streak", loss_streak)
	cfg.set_value("stats", "online_win_streak", online_win_streak)
	cfg.set_value("stats", "last_play_day", last_play_day)
	cfg.set_value("ach", "earned", _earned.keys())
	cfg.set_value("ach", "rivals", rival_wins)
	cfg.set_value("ach", "steps_sent", _steps_sent)
	cfg.save(STATS_PATH)
	_dirty = false

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
	# Endereços da foto, na ordem de preferência. O plugin pode chamar o campo de "url" ou "uri".
	var cands: Array[String] = []
	for prop in ["icon_image_url", "hi_res_image_url", "icon_image_uri", "hi_res_image_uri"]:
		var v: Variant = player.get(prop)
		if v != null and str(v) != "" and str(v) != "null":
			cands.append(str(v))
	print("[PlayGames] endereços da foto: ", cands)
	if cands.is_empty():
		# nomes dos campos do PlayGamesPlayer, para ajustar se o plugin usar outros
		var names: Array[String] = []
		for pr in player.get_property_list():
			if int(pr["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				names.append(pr["name"])
		print("[PlayGames] jogador sem foto. campos: ", names)
		return
	# 1) endereço http(s): o HTTPRequest baixa direto
	for u in cands:
		if u.begins_with("http"):
			_download_avatar(u)
			return
	# 2) content:// (provedor interno do Google): o HTTPRequest não entende; tenta ler como arquivo
	for u in cands:
		if u.begins_with("content://"):
			var bytes := FileAccess.get_file_as_bytes(u)
			var img := _decode_image(bytes)
			if img != null:
				_set_my_avatar(img, AVATAR_PATH, not has_custom_avatar())
				return
			print("[PlayGames] não consegui ler a foto em ", u, " (", error_string(FileAccess.get_open_error()), ")")
	print("[PlayGames] foto indisponível: nenhum endereço utilizável (veja a linha acima)")

func _download_avatar(uri: String) -> void:
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
	_push_cloud()

## Troca a foto por uma imagem do aparelho (png/jpg/webp). false = não deu para ler.
func set_custom_avatar_from_file(path: String) -> bool:
	var img := _decode_image(FileAccess.get_file_as_bytes(path))
	if img == null:
		return false
	_set_my_avatar(img, CUSTOM_AVATAR_PATH)
	_push_cloud()
	return true

## Usa um dos avatares do jogo (AvatarArt, 0..COUNT-1). Vale como foto escolhida: vai para o rival
## pela rede e para a nuvem (Jogos Salvos) igual a uma foto da galeria.
func set_preset_avatar(index: int) -> void:
	_set_my_avatar(AvatarArt.make(index), CUSTOM_AVATAR_PATH)
	_push_cloud()

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
	_push_cloud()

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
	if img == null:
		print("[PlayGames] foto baixou (%d bytes) mas o formato não foi reconhecido" % body.size())
		return
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
	var jpg: PackedByteArray = sq.save_jpg_to_buffer(0.85)
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
