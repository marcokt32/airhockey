extends Node
## Autoload "Net": ENet (teste local por IP) e WebRTC por código de sala
## (internet), com sinalização pelo Firebase Realtime Database.
##
## Estrutura no banco:
##   rooms/{código}/host        -> {uid}
##   rooms/{código}/guest       -> {uid}
##   rooms/{código}/offer       -> {type, sdp}
##   rooms/{código}/answer      -> {type, sdp}
##   rooms/{código}/ice_host    -> {chave: {media, index, name}}
##   rooms/{código}/ice_guest   -> {chave: {media, index, name}}

const PORT := 7777
const MAX_PLAYERS := 2
const CONNECT_TIMEOUT := 20.0
const POLL_INTERVAL := 0.5
const ROOM_STALE_S := 60.0       # sala sem batimento por esse tempo = abandonada
const HEARTBEAT_S := 20.0        # o host renova o "ts" da sala nesse intervalo
const PING_INTERVAL := 0.5       # de quanto em quanto tempo medir o ping
const PING_TIMEOUT_MS := 2000.0  # sem resposta depois disso = pacote perdido
# --- Jogo rápido (fila) ---
const QUICK_WAIT_S := 15.0         # espera por um rival antes de cair para a CPU
const QUICK_RETRY_WAIT_S := 8.0    # espera nas tentativas seguintes
const QUICK_JOIN_TIMEOUT := 12.0   # tempo para negociar a conexão com o rival
const QUICK_POLL_S := 1.0          # de quanto em quanto tempo olhar a fila
const QUICK_FALLBACK_MSG_S := 2.0  # quanto tempo mostrar "iniciando com CPU"
const QUICK_MAX_TRIES := 3
const QUEUE_STALE_S := 45.0        # entrada da fila mais velha que isso = host sumiu
const QUEUE_CLEAN_S := 120.0       # entradas bem velhas são apagadas da fila
# Servidor TURN: Cloudflare Realtime TURN. As credenciais são temporárias e vêm de
# um Worker nosso (cloudflare_turn_worker.js); o token da Cloudflare NUNCA fica no app.
const TURN_ENDPOINT := "https://airhockey-turn.quintelamarco94.workers.dev/ice"   # <- troque pela URL do seu Worker
const TURN_TTL_S := 86400            # validade pedida das credenciais (segundos)
const TURN_REFRESH_S := 21600.0      # pede de novo se a cópia local for mais velha que isso
const TURN_FETCH_TIMEOUT := 6.0
# Se o Worker não responder: só STUN (conecta quando os NATs permitem; sem relay)
const FALLBACK_ICE := [
	{"urls": "stun:stun.cloudflare.com:3478"},
	{"urls": "stun:stun.l.google.com:19302"},
]

signal status_changed(text: String)
signal room_status(text: String)   # mensagens para mostrar dentro da partida
signal hosted
signal joined                      # cliente conectou ao host
signal ended(reason: String)       # a partida acabou por causa da rede
signal stats_updated               # ping/jitter/perda foram atualizados
signal quick_status(text: String)  # mensagens do jogo rápido (a tela de busca mostra)

var last_message := ""             # o menu mostra isso depois de recarregar a cena

var _room := ""
var _is_host := false
var _rtc_peer: WebRTCMultiplayerPeer
var _conn: WebRTCPeerConnection
var _session := 0                  # sobe a cada reset; cancela timers/coroutines antigos
var _watch_ids: Array[int] = []
var _seen_ice := {}
var _offer_applied := false
var _answer_applied := false
var _connected := false
var _lost_handled := false
var _cand_local := {"host": 0, "srflx": 0, "relay": 0}
var _cand_remote := {"host": 0, "srflx": 0, "relay": 0}
var _send_fail := 0   # junto das outras variáveis; zere também em _reset_flags()
var player_name := ""   # vazio = sem nome personalizado
var vs_cpu := false      # partida contra a CPU (sem rede)
var cpu_level := 1       # 0 fácil, 1 normal, 2 difícil
var rival_uid := ""      # uid (Firebase) do rival na sala WebRTC; "" = desconhecido (conquistas Meu freguês / Vingança)
var _ice_cache: Array = []       # iceServers vindos do Worker (com credenciais temporárias)
var _ice_fetched_at := 0.0       # segundos (ticks) de quando _ice_cache foi obtido
var _ice_fetching := false

# --- jogo rápido ---
var _quick_id := 0              # sobe a cada leave(): cancela buscas antigas
var _quick_active := false      # buscando partida (ou conectando por ela)
var _quick_tried: Array[String] = []   # salas da fila que já tentei nesta busca
var _room_in_queue := false     # minha sala está publicada em queue/{código}
var _conn_failed := false

# --- diagnóstico de rede (ping medido pelo próprio canal do jogo) ---
var rtt_ms := -1.0       # ping suavizado; -1 = sem medida
var jitter_ms := 0.0
var loss_pct := 0.0
var turn_in_use := ""    # texto para o diagnóstico: "Cloudflare" ou "sem TURN (só STUN)"
var _last_rtt := -1.0
var _ping_clock := 0.0
var _ping_seq := 0
var _pings := {}         # seq -> instante do envio (ms)
var _results: Array[int] = []   # últimas respostas: 1 = chegou, 0 = perdeu
const _STATES := ["novo", "conectando", "conectado", "desconectado", "falhou", "fechado"]


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# ------------------------------------------------------------------ ENet

func host() -> void:
	_begin()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		status_changed.emit("Erro ao hospedar: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Hospedando na porta %d (seu ID: %d)" % [PORT, multiplayer.get_unique_id()])
	hosted.emit()

# Partida contra a CPU: o jogo roda como "servidor" sozinho, sem rede nenhuma.
func start_cpu(level: int) -> void:
	leave()
	_begin()
	vs_cpu = true
	cpu_level = level
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	status_changed.emit("")
	hosted.emit()

func join(ip: String) -> void:
	_begin()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		status_changed.emit("Erro ao conectar: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Conectando a %s..." % ip)

# ---------------------------------------------------------------- WebRTC

func host_room(code: String) -> void:
	code = _clean_code(code)
	if code == "":
		status_changed.emit("Digite um código de sala (letras e números)")
		return
	leave()
	_begin()
	status_changed.emit("Conectando ao Firebase...")
	await _host_room_impl(code, false)

# Cria a sala e o servidor WebRTC. quick = vem do jogo rápido: não avisa o jogo
# (hosted) agora, só quando o rival conectar. Devolve true se deu certo.
func _host_room_impl(code: String, quick: bool) -> bool:
	if not await Firebase.sign_in():
		_tell("Falha no login do Firebase", quick)
		return false
	var sid := _session
	await _ensure_ice()   # a conexão com o rival é criada depois, já com TURN pronto
	if sid != _session:
		return false
	var info := {"host": Firebase.uid, "ts": Firebase.SERVER_TS}
	# Cria só se a sala NÃO existir (atômico: dois jogadores não criam o mesmo código)
	var r: Dictionary = await Firebase.db_create("rooms/" + code, info)
	if sid != _session:
		return false
	if not r.ok and r.code == 412:
		# Já existe: está em uso ou é sobra de uma partida antiga?
		var cur: Dictionary = await Firebase.db_get("rooms/" + code)
		if sid != _session:
			return false
		if cur.ok and _room_is_alive(cur.data):
			_tell("A sala %s já existe. Escolha outro código." % code, quick)
			return false
		# Sobra (host sumiu): assume a sala, apagando restos da partida anterior
		r = await Firebase.db_set("rooms/" + code, info)
		if sid != _session:
			return false
	if not r.ok:
		_tell("Erro ao criar sala: %s" % r.error, quick)
		return false

	_rtc_peer = WebRTCMultiplayerPeer.new()
	var err := _rtc_peer.create_server()
	if err != OK:
		_rtc_peer = null
		Firebase.db_delete("rooms/" + code)
		_tell("Erro ao criar servidor WebRTC: %s" % error_string(err), quick)
		return false
	_room = code
	_is_host = true
	multiplayer.multiplayer_peer = _rtc_peer
	if quick:
		_watch_guest()
		return true
	status_changed.emit("Sala %s criada" % code)
	hosted.emit()
	_say("Sala %s criada.\nAguardando o outro jogador..." % code)
	_heartbeat()
	_watch_guest()
	return true

# Sala "viva" = tem host que não sou eu e o batimento (ts) é recente.
# Sem ts (sala antiga/incompleta) conta como abandonada.
func _room_is_alive(d: Variant) -> bool:
	if not (d is Dictionary) or not d.has("host"):
		return false
	if str(d["host"]) == Firebase.uid:
		return false   # sobra de uma sessão minha anterior
	if not d.has("ts"):
		return false
	var age_s: float = Time.get_unix_time_from_system() - float(d["ts"]) / 1000.0
	return age_s < ROOM_STALE_S

# Enquanto for host de uma sala, renova o "ts" para ela não parecer abandonada
func _heartbeat() -> void:
	var sid := _session
	while true:
		await get_tree().create_timer(HEARTBEAT_S).timeout
		if sid != _session or not _is_host or _room == "":
			return
		Firebase.db_update(_room_path(), {"ts": Firebase.SERVER_TS})

func join_room(code: String) -> void:
	code = _clean_code(code)
	if code == "":
		status_changed.emit("Digite o código da sala")
		return
	leave()
	_begin()
	status_changed.emit("Procurando a sala %s..." % code)
	if not await Firebase.sign_in():
		status_changed.emit("Falha no login do Firebase")
		return
	await _join_room_impl(code, false)

# Entra numa sala existente como convidado. quick = jogo rápido: reserva a vaga de
# forma atômica (só um jogador consegue) e não usa o timeout padrão.
func _join_room_impl(code: String, quick: bool) -> bool:
	var sid := _session
	var r: Dictionary = await Firebase.db_get("rooms/" + code)
	if sid != _session:
		return false
	if not r.ok:
		_tell("Erro ao procurar a sala: %s" % r.error, quick)
		return false
	if not (r.data is Dictionary) or not r.data.has("host"):
		_tell("Sala %s não encontrada" % code, quick)
		return false
	if r.data.has("guest"):
		_tell("Sala %s já está cheia" % code, quick)
		return false
	var host_uid := str(r.data["host"])

	await _ensure_ice()
	if sid != _session:
		return false
	_rtc_peer = WebRTCMultiplayerPeer.new()
	var err := _rtc_peer.create_client(2)
	if err != OK:
		_drop_room()
		_tell("Erro ao criar cliente WebRTC: %s" % error_string(err), quick)
		return false
	_conn = _make_connection()
	if _conn == null:
		_drop_room()  # a mensagem de erro já foi emitida por _make_connection
		return false
	_room = code
	_is_host = false
	rival_uid = host_uid
	_rtc_peer.add_peer(_conn, 1)
	multiplayer.multiplayer_peer = _rtc_peer
	_watch_ids.append(Firebase.watch(_room_path("offer"), _on_offer_changed, POLL_INTERVAL))

	# Avisa o host por último, com tudo já preparado para receber a oferta
	if quick:
		r = await Firebase.db_create(_room_path("guest"), {"uid": Firebase.uid})
	else:
		r = await Firebase.db_set(_room_path("guest"), {"uid": Firebase.uid})
	if sid != _session:
		return false
	if not r.ok:
		_room = ""   # não mexe na sala: o convidado dela pode ser outro jogador
		_drop_room()
		_tell("Erro ao entrar na sala: %s" % r.error, quick)
		return false
	_tell("Conectando à sala %s..." % code, quick)
	if not quick:
		_start_timeout()
	return true

## Fecha qualquer conexão (ENet ou WebRTC), limpa a sala no Firebase e cancela
## qualquer busca do jogo rápido.
func leave() -> void:
	_quick_id += 1
	_quick_active = false
	_drop_room()

# O corpo do antigo leave(): mexe só na sala/conexão, sem cancelar a busca do jogo rápido.
func _drop_room() -> void:
	_lost_handled = true  # sair de propósito não é "host caiu"
	vs_cpu = false
	var room := _room
	var was_host := _is_host
	_room = ""
	_is_host = false
	_session += 1
	_unwatch_all()
	if room != "" and Firebase.is_signed_in():
		if was_host:
			Firebase.db_delete("rooms/" + room)
			if _room_in_queue:
				Firebase.db_delete("queue/" + room)
		else:
			Firebase.db_update("rooms/" + room, {"guest": null, "answer": null, "ice_guest": null})
	_room_in_queue = false
	if _conn != null:
		_conn.close()
		_conn = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_rtc_peer = null
	_reset_flags()

# ------------------------------------------------- sinalização (host)

func _watch_guest() -> void:
	_watch_ids.append(Firebase.watch(_room_path("guest"), _on_guest_changed, POLL_INTERVAL))

func _on_guest_changed(value: Variant) -> void:
	if not _is_host or _conn != null or not (value is Dictionary):
		return
	rival_uid = str(value.get("uid", ""))
	_conn = _make_connection()
	if _conn == null:
		return
	_rtc_peer.add_peer(_conn, 2)
	if _quick_active:
		# Achou rival: sai da fila para ninguém mais tentar entrar
		if _room_in_queue:
			Firebase.db_delete("queue/" + _room)
			_room_in_queue = false
		_start_timeout(QUICK_JOIN_TIMEOUT)
	else:
		_say("Rival encontrado.\nConectando...")
		_start_timeout()
	_watch_ids.append(Firebase.watch(_room_path("answer"), _on_answer_changed, POLL_INTERVAL))
	_conn.create_offer()

func _on_answer_changed(value: Variant) -> void:
	if _conn == null or _answer_applied or not (value is Dictionary):
		return
	_answer_applied = true
	_conn.set_remote_description(value["type"], value["sdp"])
	_watch_ids.append(Firebase.watch(_room_path("ice_guest"), _on_remote_ice, POLL_INTERVAL))

## Reabre a sala para outro jogador (rival saiu ou a negociação falhou).
func _reset_negotiation(message: String = "") -> void:
	if not _is_host or _room == "":
		return
	_session += 1
	var sid := _session
	_unwatch_all()
	if _conn != null:
		if _rtc_peer != null and _rtc_peer.has_peer(2):
			_rtc_peer.remove_peer(2)
		_conn.close()
		_conn = null
	_reset_flags()
	if message != "":
		_say(message)
	# Limpa o rastro da negociação ANTES de voltar a escutar, para não
	# reaproveitar um "guest" antigo.
	await Firebase.db_update(_room_path(), {
		"guest": null, "offer": null, "answer": null,
		"ice_host": null, "ice_guest": null})
	if sid != _session or _room == "":
		return
	_watch_guest()

# ------------------------------------------------ sinalização (cliente)

func _on_offer_changed(value: Variant) -> void:
	if _conn == null or _offer_applied or not (value is Dictionary):
		return
	_offer_applied = true
	# Isso faz a resposta (answer) ser criada automaticamente
	_conn.set_remote_description(value["type"], value["sdp"])
	_watch_ids.append(Firebase.watch(_room_path("ice_host"), _on_remote_ice, POLL_INTERVAL))

# ------------------------------------------------------ comum aos dois

func _ice_servers() -> Array:
	if _ice_cache.is_empty():
		turn_in_use = "sem TURN (só STUN)"
		return FALLBACK_ICE.duplicate(true)
	turn_in_use = "Cloudflare"
	return _ice_cache

## Pré-carrega as credenciais TURN (o menu chama ao abrir "Jogar online").
func prefetch_ice() -> void:
	_ensure_ice()

## Garante credenciais TURN válidas antes de montar a conexão. Se já tem uma cópia
## recente, volta na hora. Se o Worker falhar, mantém a cópia antiga (ou cai para STUN).
func _ensure_ice() -> void:
	if not _ice_cache.is_empty() and _now_s() - _ice_fetched_at < TURN_REFRESH_S:
		return
	if _ice_fetching:
		while _ice_fetching:
			await get_tree().process_frame
		return
	_ice_fetching = true
	var servers: Array = await _fetch_ice()
	_ice_fetching = false
	if servers.is_empty():
		push_warning("TURN: não consegui credenciais da Cloudflare")
		if _ice_cache.is_empty():
			status_changed.emit("Servidor TURN indisponível; tentando só com STUN")
		return
	_ice_cache = servers
	_ice_fetched_at = _now_s()

# Pede ao Worker as credenciais (autenticado com o token do Firebase) e converte
# a resposta da Cloudflare para o formato do Godot. Devolve [] se falhar.
func _fetch_ice() -> Array:
	if not await Firebase.sign_in():
		return []
	var req := HTTPRequest.new()
	req.timeout = TURN_FETCH_TIMEOUT
	add_child(req)
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + Firebase.id_token])
	var err := req.request(TURN_ENDPOINT, headers, HTTPClient.METHOD_POST,
			JSON.stringify({"ttl": TURN_TTL_S}))
	if err != OK:
		req.queue_free()
		return []
	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		push_warning("TURN: Worker respondeu resultado=%d HTTP=%d" % [res[0], res[1]])
		return []
	var data: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return _parse_cloudflare_ice(data)

# Resposta da Cloudflare: {"iceServers": [{urls:[stun...]}, {urls:[turn...], username, credential}]}
# (aceita também "iceServers" como objeto único). Ignora as portas 53 e 5349: ficam
# UDP 3478, TCP 3478, TCP 80 e TLS 443, um servidor por URL (como era no Metered).
func _parse_cloudflare_ice(data: Variant) -> Array:
	if not (data is Dictionary) or not data.has("iceServers"):
		return []
	var raw: Variant = data["iceServers"]
	var list: Array = raw if raw is Array else [raw]
	var out: Array = []
	var has_turn := false
	for entry in list:
		if not (entry is Dictionary):
			continue
		var u: Variant = entry.get("urls", [])
		var urls: Array = u if u is Array else [u]
		for url in urls:
			var s := str(url)
			var port := s.get_slice("?", 0).get_slice(":", 2)
			if s == "" or port == "53" or port == "5349":
				continue
			if entry.has("username") and entry.has("credential"):
				out.append({"urls": s, "username": entry["username"], "credential": entry["credential"]})
				has_turn = true
			else:
				out.append({"urls": s})
	return out if has_turn else []

func _now_s() -> float:
	return Time.get_ticks_msec() / 1000.0

func _make_connection() -> WebRTCPeerConnection:
	var c := WebRTCPeerConnection.new()
	var err := c.initialize({"iceServers": _ice_servers()})
	if err != OK:
		status_changed.emit("WebRTC indisponível (%s). Verifique se a extensão webrtc-native carregou." % error_string(err))
		return null
	c.session_description_created.connect(_on_session_description)
	c.ice_candidate_created.connect(_on_ice_candidate)
	return c

func _on_session_description(type: String, sdp: String) -> void:
	if _conn == null:
		return
	_conn.set_local_description(type, sdp)
	var key := "offer" if type == "offer" else "answer"
	var r: Dictionary = await Firebase.db_set(_room_path(key), {"type": type, "sdp": sdp})
	if not r.ok:
		_send_fail += 1
		print("[Net] falha ao enviar ", key, ": ", r.error)

func _on_ice_candidate(media: String, index: int, cand_name: String) -> void:
	if _room == "":
		return
	_count_cand(_cand_local, cand_name)
	var side := "ice_host" if _is_host else "ice_guest"
	var r: Dictionary = await Firebase.db_push(_room_path(side), {"media": media, "index": index, "name": cand_name})
	if not r.ok:
		_send_fail += 1
		print("[Net] falha ao enviar candidato: ", r.error)

func _on_remote_ice(value: Variant) -> void:
	if _conn == null or not (value is Dictionary):
		return
	var keys: Array = value.keys()
	keys.sort()  # chaves do push() são ordenadas por tempo
	for k in keys:
		if _seen_ice.has(k):
			continue
		_seen_ice[k] = true
		var c: Dictionary = value[k]
		_conn.add_ice_candidate(c["media"], int(c["index"]), c["name"])
		# em _on_remote_ice, dentro do for, depois de "var c: Dictionary = value[k]":
		_count_cand(_cand_remote, c["name"])

func _start_timeout(seconds: float = CONNECT_TIMEOUT) -> void:
	var sid := _session
	var qid := _quick_id
	await get_tree().create_timer(seconds).timeout
	if sid != _session or _connected or _room == "":
		return
	var diag := _diag()
	print("[Net] timeout. ", diag)
	if _is_host:
		if _quick_active:
			_quick_fallback_cpu(qid, "Não foi possível conectar com o rival.")
			return
		_reset_negotiation("Não foi possível conectar com o rival.\n%s\nAguardando novo jogador..." % diag)
	else:
		leave()
		status_changed.emit("Falha ao conectar.\n%s" % diag)

# ------------------------------------------------------------ jogo rápido
#
# Fila no Firebase: cada jogador esperando publica queue/{código} = {uid, ts}, que
# aponta para a sala dele (rooms/{código}). Quem chega procura uma entrada viva:
#  - achou: reserva a vaga de convidado na sala (atômico) e conecta por WebRTC;
#  - não achou: cria sala própria, entra na fila e espera até QUICK_WAIT_S.
# Dois jogadores que entram juntos acabam com salas separadas: o de código MAIOR
# desiste da sua e entra na do menor (desempate sem servidor).
# Sem rival a tempo (ou sem internet / falha ao conectar): partida contra a CPU,
# que NÃO conta para o ranking online (vs_cpu = true).

## Procura um rival pela fila; sem ninguém em QUICK_WAIT_S, joga contra a CPU.
func quick_match() -> void:
	leave()
	_begin()
	_quick_active = true
	_quick_tried.clear()
	var qid := _quick_id
	quick_status.emit("Procurando jogador...")
	if not await Firebase.sign_in():
		if qid == _quick_id:
			_quick_fallback_cpu(qid, "Sem conexão com a internet.")
		return
	if qid != _quick_id:
		return
	var target := await _queue_pick("")
	var wait_s := QUICK_WAIT_S
	for i in QUICK_MAX_TRIES:
		if qid != _quick_id:
			return
		if target == "":
			target = await _quick_host(qid, wait_s)
			if target == "":
				return   # conectou, cancelou ou já caiu para a CPU
			wait_s = QUICK_RETRY_WAIT_S
		_quick_tried.append(target)
		quick_status.emit("Jogador encontrado. Conectando...")
		if await _quick_join(target, qid):
			return
		if qid != _quick_id:
			return
		_drop_room()   # a tentativa falhou: limpa e volta a procurar
		quick_status.emit("Procurando jogador...")
		target = await _queue_pick("")
		wait_s = QUICK_RETRY_WAIT_S
	if qid == _quick_id:
		_quick_fallback_cpu(qid)

# Cria sala própria, entra na fila e espera. Devolve "" quando terminou (conectou,
# cancelou ou caiu para a CPU) ou o código de outra sala em que devo entrar.
func _quick_host(qid: int, wait_s: float) -> String:
	var code := _random_code()
	var ok := await _host_room_impl(code, true)
	if qid != _quick_id:
		return ""
	if not ok:
		_quick_fallback_cpu(qid, "Não foi possível criar a partida.")
		return ""
	var pub: Dictionary = await Firebase.db_set("queue/" + code, {"uid": Firebase.uid, "ts": Firebase.SERVER_TS})
	if qid != _quick_id:
		Firebase.db_delete("queue/" + code)   # cancelou no meio: não deixa entrada solta
		return ""
	if not pub.ok:
		print("[Net] falha ao entrar na fila: ", pub.error)
		_quick_fallback_cpu(qid, "Não foi possível entrar na fila.")
		return ""
	_room_in_queue = true
	var waited := 0.0
	while waited < wait_s:
		quick_status.emit("Procurando jogador...  %d s" % int(ceil(wait_s - waited)))
		await get_tree().create_timer(QUICK_POLL_S).timeout
		if qid != _quick_id:
			return ""
		if _conn != null:
			return ""   # alguém entrou na minha sala: a negociação cuida do resto
		waited += QUICK_POLL_S
		# desempate: se há outro esperando com código MENOR, eu entro na sala dele
		var other := await _queue_pick(code)
		if qid != _quick_id:
			return ""
		if _conn != null:
			return ""
		if other != "":
			_drop_room()   # apaga minha sala e minha entrada na fila
			return other
	if _conn != null:
		return ""
	_quick_fallback_cpu(qid)
	return ""

# Entra na sala `code` e espera a conexão. true = conectou.
func _quick_join(code: String, qid: int) -> bool:
	_conn_failed = false
	if not await _join_room_impl(code, true):
		return false
	var t := 0.0
	while t < QUICK_JOIN_TIMEOUT:
		await get_tree().create_timer(0.25).timeout
		if _connected:
			return true
		if qid != _quick_id:
			return false
		if _conn_failed:
			return false
		t += 0.25
	return false

# Escolhe uma sala da fila para entrar. my_code == "": qualquer entrada viva (a de
# menor código). Com my_code: só entradas de código MENOR que o meu (desempate).
func _queue_pick(my_code: String) -> String:
	var r: Dictionary = await Firebase.db_get("queue")
	if not r.ok:
		print("[Net] falha ao ler a fila: ", r.error)
		return ""
	if not (r.data is Dictionary):
		return ""
	var best := ""
	for key in r.data.keys():
		var code := str(key)
		var d: Variant = r.data[key]
		_queue_clean_if_old(code, d)
		if code == my_code or _quick_tried.has(code):
			continue
		if not _queue_entry_alive(d):
			continue
		if my_code != "" and code >= my_code:
			continue
		if best == "" or code < best:
			best = code
	return best

func _queue_entry_alive(d: Variant) -> bool:
	if not (d is Dictionary) or not d.has("ts") or not d.has("uid"):
		return false
	if str(d["uid"]) == Firebase.uid:
		return false   # sobra de uma sessão minha anterior
	return _queue_age_s(d) < QUEUE_STALE_S

func _queue_age_s(d: Dictionary) -> float:
	return Time.get_unix_time_from_system() - float(d["ts"]) / 1000.0

# Entradas bem velhas (host que fechou o app sem sair) são apagadas por quem passar.
func _queue_clean_if_old(code: String, d: Variant) -> void:
	if d is Dictionary and d.has("ts") and _queue_age_s(d) > QUEUE_CLEAN_S:
		Firebase.db_delete("queue/" + code)

# Ninguém a tempo (ou falha): avisa e começa contra a CPU, no nível do XP do jogador.
func _quick_fallback_cpu(qid: int, reason: String = "Nenhum jogador foi encontrado.") -> void:
	if qid != _quick_id or not _quick_active:
		return
	_drop_room()   # tira a sala e a entrada da fila: ninguém entra durante o aviso
	var level := PlayGames.cpu_level_for_xp()
	var names := ["Fácil", "Normal", "Difícil"]
	quick_status.emit("%s\nIniciando partida com CPU (%s)..." % [reason, names[clampi(level, 0, 2)]])
	await get_tree().create_timer(QUICK_FALLBACK_MSG_S).timeout
	if qid != _quick_id:
		return   # cancelou durante o aviso
	start_cpu(level)

func _random_code() -> String:
	const CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var out := "Q"   # prefixo: salas do jogo rápido
	for i in 5:
		out += CHARS[randi() % CHARS.length()]
	return out

## True se a partida atual é pela internet (sala WebRTC) e contra pessoa: só essas
## valem para o ranking online (CPU e teste por IP/Wi-Fi não valem).
func is_ranked_match() -> bool:
	return not vs_cpu and _room != ""

# Emite a mensagem na tela de status; no jogo rápido só registra no log (erros
# esperados, como "sala cheia", não devem piscar na tela de busca).
func _tell(text: String, quick: bool) -> void:
	if quick:
		print("[Net] jogo rápido: ", text)
	else:
		status_changed.emit(text)

# ---------------------------------------------------------------- helpers

func _begin() -> void:
	_lost_handled = false
	Firebase.poll_ok = 0
	Firebase.poll_err = 0
	Firebase.last_poll_error = ""

func _reset_flags() -> void:
	rival_uid = ""
	_seen_ice.clear()
	_offer_applied = false
	_answer_applied = false
	_connected = false
	_send_fail = 0   # <- novo
	_cand_local = {"host": 0, "srflx": 0, "relay": 0}
	_cand_remote = {"host": 0, "srflx": 0, "relay": 0}

func _unwatch_all() -> void:
	for id in _watch_ids:
		Firebase.unwatch(id)
	_watch_ids.clear()

func _say(text: String) -> void:
	status_changed.emit(text)
	room_status.emit(text)

func _room_path(child: String = "") -> String:
	if child == "":
		return "rooms/" + _room
	return "rooms/%s/%s" % [_room, child]

func _clean_code(code: String) -> String:
	var out := ""
	for ch in code.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out.left(12)

func _handle_host_lost() -> void:
	if _lost_handled:
		return
	_lost_handled = true
	leave()
	last_message = "O host desconectou. Partida encerrada."
	status_changed.emit(last_message)
	ended.emit(last_message)

# ---------------------------------------------------- sinais do multiplayer

func _on_peer_connected(id: int) -> void:
	_connected = true
	if _quick_active:
		# Rival conectou: a busca acabou. O host só avisa o jogo agora (na sala
		# normal ele avisa ao criar a sala).
		_quick_active = false
		_quick_id += 1
		if _is_host:
			hosted.emit()
	status_changed.emit("Jogador %d entrou" % id)
	# Conectou: a sinalização acabou. Para de consultar o banco...
	_unwatch_all()
	# ...e o host apaga o que só servia para negociar (a sala continua existindo)
	if _is_host and _room != "":
		Firebase.db_update(_room_path(), {
			"offer": null, "answer": null,
			"ice_host": null, "ice_guest": null})

func _on_peer_disconnected(id: int) -> void:
	status_changed.emit("Jogador %d saiu" % id)
	if _is_host and _room != "" and id == 2:
		_connected = false
		_reset_negotiation("Rival saiu.\nAguardando novo jogador...")
	elif id == 1 and not multiplayer.is_server():
		_handle_host_lost()

func _on_connected_to_server() -> void:
	status_changed.emit("Conectado! Seu ID: %d" % multiplayer.get_unique_id())
	joined.emit()

func _on_connection_failed() -> void:
	if _quick_active:
		_conn_failed = true   # a busca decide o que fazer (tenta outro rival ou cai para a CPU)
		return
	leave()
	status_changed.emit("Falha na conexão")

func _on_server_disconnected() -> void:
	_handle_host_lost()

func _cand_type(c: String) -> String:
	var i := c.find(" typ ")
	if i == -1:
		return "outro"
	return c.substr(i + 5).get_slice(" ", 0)

func _count_cand(counts: Dictionary, c: String) -> void:
	var t := _cand_type(c)
	counts[t] = int(counts.get(t, 0)) + 1

func _diag() -> String:
	var st := "?"
	if _conn != null:
		var s: int = _conn.get_connection_state()
		st = _STATES[s] if s < _STATES.size() else str(s)
	return "ICE: %s\nlocal: host=%d srflx=%d relay=%d\nremoto: host=%d srflx=%d relay=%d\nsinal: oferta=%s resposta=%s falhas=%d\nleituras: ok=%d erro=%d %s" % [
		st,
		_cand_local.get("host", 0), _cand_local.get("srflx", 0), _cand_local.get("relay", 0),
		_cand_remote.get("host", 0), _cand_remote.get("srflx", 0), _cand_remote.get("relay", 0),
		_offer_applied, _answer_applied, _send_fail,
		Firebase.poll_ok, Firebase.poll_err, Firebase.last_poll_error]

# ------------------------------------------------------------ diagnóstico

func _process(delta: float) -> void:
	var peers := multiplayer.get_peers()
	if peers.is_empty():
		if rtt_ms >= 0.0 or not _pings.is_empty():
			_reset_stats()
		return
	_expire_pings()
	_ping_clock += delta
	if _ping_clock >= PING_INTERVAL:
		_ping_clock = 0.0
		_ping_seq += 1
		_pings[_ping_seq] = _now_ms()
		for id in peers:
			_ping.rpc_id(id, _ping_seq)

@rpc("any_peer", "unreliable")
func _ping(seq: int) -> void:
	_pong.rpc_id(multiplayer.get_remote_sender_id(), seq)

@rpc("any_peer", "unreliable")
func _pong(seq: int) -> void:
	if not _pings.has(seq):
		return
	var rtt := _now_ms() - float(_pings[seq])
	_pings.erase(seq)
	if rtt_ms < 0.0:
		rtt_ms = rtt
	else:
		rtt_ms += (rtt - rtt_ms) * 0.2
	if _last_rtt >= 0.0:
		jitter_ms += (absf(rtt - _last_rtt) - jitter_ms) / 8.0
	_last_rtt = rtt
	_push_result(1)

func _expire_pings() -> void:
	var now := _now_ms()
	for seq in _pings.keys():
		if now - float(_pings[seq]) > PING_TIMEOUT_MS:
			_pings.erase(seq)
			_push_result(0)

func _push_result(ok: int) -> void:
	_results.append(ok)
	if _results.size() > 20:
		_results.pop_front()
	loss_pct = 100.0 * float(_results.count(0)) / float(_results.size())
	stats_updated.emit()

func _reset_stats() -> void:
	rtt_ms = -1.0
	jitter_ms = 0.0
	loss_pct = 0.0
	_last_rtt = -1.0
	_ping_clock = 0.0
	_pings.clear()
	_results.clear()
	stats_updated.emit()

func _now_ms() -> float:
	return Time.get_ticks_usec() / 1000.0

# Texto para a tela de diagnóstico (tocar no ping, durante a partida).
# Obs.: os candidatos são os que foram COLETADOS, não necessariamente o
# caminho em uso (o Godot não expõe o par ICE escolhido).
func stats_text() -> String:
	var r: String = "--" if rtt_ms < 0.0 else "%d ms" % int(round(rtt_ms))
	return "Ping: %s (jitter %d ms)\nPerda: %d%%\nTURN: %s\nCandidatos local: host=%d srflx=%d relay=%d\nCandidatos rival: host=%d srflx=%d relay=%d" % [
		r, int(round(jitter_ms)), int(round(loss_pct)),
		turn_in_use if turn_in_use != "" else "-",
		_cand_local.get("host", 0), _cand_local.get("srflx", 0), _cand_local.get("relay", 0),
		_cand_remote.get("host", 0), _cand_remote.get("srflx", 0), _cand_remote.get("relay", 0)]
