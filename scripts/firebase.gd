extends Node
## Autoload "Firebase": login anônimo + Realtime Database via REST.
## Todas as funções db_* são assíncronas: use `await`.
## Retorno dos db_*: {"ok": bool, "code": int, "data": Variant, "error": String}

# A chave NÃO fica mais no código: vem de firebase_config.cfg (fora do git, veja .gitignore).
# Copie firebase_config.example.cfg para firebase_config.cfg e preencha.
const CONFIG_PATH := "res://firebase_config.cfg"
var API_KEY := ""
var _android_package := ""   # opcionais: usados se a chave for restrita a "Apps Android"
var _android_cert := ""
const DB_URL := "https://airhockey-ae632-default-rtdb.firebaseio.com"

# Use como valor para o servidor gravar a hora dele: {"ts": Firebase.SERVER_TS}
const SERVER_TS := {".sv": "timestamp"}

var JSON_HEADERS := PackedStringArray(["Content-Type: application/json"])
var FORM_HEADERS := PackedStringArray(["Content-Type: application/x-www-form-urlencoded"])

signal signed_in(uid: String)
signal sign_in_failed(reason: String)
signal _auth_done(ok: bool)

var uid := ""
var id_token := ""
# Para testar 2 instâncias no mesmo PC, rode com --profile=A e --profile=B
# (cada perfil guarda a própria conta anônima, então tem UID próprio).
var profile := "default"

var _refresh_token := ""
var _expires_at := 0.0
var _signing_in := false
var _watch_seq := 0
var _watchers := {}
var poll_ok := 0
var poll_err := 0
var last_poll_error := ""

var _persist := true

func _ready() -> void:
	_load_config()
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	print("Firebase: argumentos recebidos = ", args)  # para diagnóstico
	for arg in args:
		if arg.begins_with("--profile="):
			profile = arg.get_slice("=", 1)
	# Rodando pelo editor sem perfil: conta descartável por execução
	if profile == "default" and OS.has_feature("editor"):
		_persist = false

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		push_error("Firebase: falta %s (copie firebase_config.example.cfg e preencha a chave)." % CONFIG_PATH)
		return
	API_KEY = str(cfg.get_value("firebase", "api_key", ""))
	_android_package = str(cfg.get_value("firebase", "android_package", ""))
	_android_cert = str(cfg.get_value("firebase", "android_cert_sha1", "")).replace(":", "")

# Se a chave for restrita a um app Android, o Google exige estes dois cabeçalhos nas chamadas de login
func _auth_headers(base: PackedStringArray) -> PackedStringArray:
	var h: PackedStringArray = base.duplicate()
	if _android_package != "" and _android_cert != "":
		h.append("X-Android-Package: " + _android_package)
		h.append("X-Android-Cert: " + _android_cert)
	return h

func is_signed_in() -> bool:
	return uid != ""

# ---------------------------------------------------------------- login

## Faz login anônimo (reaproveita a conta salva no aparelho). Retorna true/false.
func sign_in() -> bool:
	if API_KEY == "":
		sign_in_failed.emit("chave do Firebase não configurada")
		return false
	if _signing_in:
		return await _auth_done
	if is_signed_in() and not _token_expiring():
		return true
	_signing_in = true
	var ok: bool = await _do_sign_in()
	_signing_in = false
	_auth_done.emit(ok)
	if ok:
		signed_in.emit(uid)
	return ok

func _do_sign_in() -> bool:
	if _refresh_token == "":
		_refresh_token = _load_refresh_token()
	if _refresh_token != "":
		if await _refresh():
			return true
		if is_signed_in():
			return false  # sessão ativa: não troca de UID no meio da partida

	var res: Dictionary = await _http(
		HTTPClient.METHOD_POST,
		"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" + API_KEY,
		JSON.stringify({"returnSecureToken": true}),
		_auth_headers(JSON_HEADERS))
	if not res.ok:
		push_error("Firebase login falhou: %s" % res.error)
		sign_in_failed.emit(res.error)
		return false
	var d: Dictionary = res.data
	_apply_session(d.idToken, d.refreshToken, d.expiresIn, d.localId)
	return true

func _refresh() -> bool:
	var res: Dictionary = await _http(
		HTTPClient.METHOD_POST,
		"https://securetoken.googleapis.com/v1/token?key=" + API_KEY,
		"grant_type=refresh_token&refresh_token=" + _refresh_token.uri_encode(),
		_auth_headers(FORM_HEADERS))
	if not res.ok:
		return false
	var d: Dictionary = res.data
	_apply_session(d.id_token, d.refresh_token, d.expires_in, d.user_id)
	return true

func _apply_session(token: String, refresh: String, expires_in: String, user_id: String) -> void:
	id_token = token
	_refresh_token = refresh
	uid = user_id
	_expires_at = Time.get_unix_time_from_system() + float(expires_in)
	_save_refresh_token(refresh)

func _token_expiring() -> bool:
	return Time.get_unix_time_from_system() >= _expires_at - 120.0

func _session_path() -> String:
	return "user://firebase_%s.cfg" % profile.validate_filename()

func _load_refresh_token() -> String:
	if not _persist:
		return ""
	var cfg := ConfigFile.new()
	if cfg.load(_session_path()) != OK:
		return ""
	return cfg.get_value("auth", "refresh_token", "")

func _save_refresh_token(token: String) -> void:
	if not _persist:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "refresh_token", token)
	cfg.save(_session_path())

# ------------------------------------------------------- Realtime Database

func db_get(path: String, query := "") -> Dictionary:
	return await _db(HTTPClient.METHOD_GET, path, "", query)

## Substitui o valor do caminho (PUT).
func db_set(path: String, value: Variant) -> Dictionary:
	return await _db(HTTPClient.METHOD_PUT, path, JSON.stringify(value))

## Cria o valor SÓ se o caminho estiver vazio (escrita condicional por ETag,
## atômica no servidor). Se já existir algo: ok=false e code=412.
func db_create(path: String, value: Variant) -> Dictionary:
	if not await sign_in():
		return {"ok": false, "code": 0, "data": null, "error": "não autenticado"}
	var url := "%s/%s.json?auth=%s" % [DB_URL, path.trim_prefix("/"), id_token]
	var headers: PackedStringArray = JSON_HEADERS.duplicate()
	headers.append("if-match: null_etag")
	return await _http(HTTPClient.METHOD_PUT, url, JSON.stringify(value), headers)

## Mescla campos no caminho sem apagar os outros (PATCH).
func db_update(path: String, fields: Dictionary) -> Dictionary:
	return await _db(HTTPClient.METHOD_PATCH, path, JSON.stringify(fields))

## Cria um filho com chave automática (POST). A chave vem em result.data.name.
func db_push(path: String, value: Variant) -> Dictionary:
	return await _db(HTTPClient.METHOD_POST, path, JSON.stringify(value))

func db_delete(path: String) -> Dictionary:
	return await _db(HTTPClient.METHOD_DELETE, path)

func _db(method: HTTPClient.Method, path: String, body := "", query := "") -> Dictionary:
	if not await sign_in():
		return {"ok": false, "code": 0, "data": null, "error": "não autenticado"}
	var url := "%s/%s.json?auth=%s" % [DB_URL, path.trim_prefix("/"), id_token]
	if query != "":
		url += "&" + query
	return await _http(method, url, body)

# --------------------------------------------------------------- observar

## Consulta o caminho a cada `interval` segundos e chama callback(valor)
## na primeira leitura e sempre que o valor mudar. Retorna um id para unwatch().
## (Versão simples com polling; dá para trocar por streaming SSE depois.)
func watch(path: String, callback: Callable, interval := 0.5) -> int:
	_watch_seq += 1
	var id := _watch_seq
	_watchers[id] = true
	_watch_loop(id, path, callback, interval)
	return id

func unwatch(id: int) -> void:
	_watchers.erase(id)

func _watch_loop(id: int, path: String, callback: Callable, interval: float) -> void:
	var last := ""
	var first := true
	while _watchers.has(id):
		var res: Dictionary = await db_get(path)
		if not _watchers.has(id):
			break
		if not callback.is_valid():
			break  # quem escutava foi destruído
		if res.ok:
			poll_ok += 1
			var s := JSON.stringify(res.data)
			if first or s != last:
				first = false
				last = s
				callback.call(res.data)
		else:
			poll_err += 1
			last_poll_error = res.error
		await get_tree().create_timer(interval).timeout
	_watchers.erase(id)

# ------------------------------------------------------------------- HTTP

func _http(method: HTTPClient.Method, url: String, body := "", headers := PackedStringArray()) -> Dictionary:
	if headers.is_empty():
		headers = JSON_HEADERS
	var req := HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	var err := req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "data": null, "error": "request: %s" % error_string(err)}
	var res: Array = await req.request_completed
	req.queue_free()

	var result: int = res[0]
	var code: int = res[1]
	var text: String = (res[3] as PackedByteArray).get_string_from_utf8()
	var data: Variant = null
	if text != "":
		data = JSON.parse_string(text)

	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	var error_text := ""
	if result != HTTPRequest.RESULT_SUCCESS:
		error_text = "rede (resultado %d)" % result
	elif not ok:
		error_text = "HTTP %d" % code
		if data is Dictionary and data.has("error"):
			var e: Variant = data.error
			if e is Dictionary and e.has("message"):
				error_text = str(e.message)
			else:
				error_text = str(e)
	return {"ok": ok, "code": code, "data": data, "error": error_text}
