extends Node

const PORT := 7777
const MAX_PLAYERS := 8

signal status_changed(text: String)
signal hosted

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		status_changed.emit("Erro ao hospedar: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Hospedando na porta %d (seu ID: %d)" % [PORT, multiplayer.get_unique_id()])
	hosted.emit()

func join(ip: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		status_changed.emit("Erro ao conectar: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Conectando a %s..." % ip)

func _on_peer_connected(id: int) -> void:
	status_changed.emit("Jogador %d entrou" % id)

func _on_peer_disconnected(id: int) -> void:
	status_changed.emit("Jogador %d saiu" % id)

func _on_connected_to_server() -> void:
	status_changed.emit("Conectado! Seu ID: %d" % multiplayer.get_unique_id())

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	status_changed.emit("Falha na conexão")

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	status_changed.emit("Servidor desconectou")
