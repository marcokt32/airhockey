extends Node

func _ready() -> void:
	var pc := WebRTCPeerConnection.new()
	var err := pc.initialize({"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]})
	print("WebRTC init: ", error_string(err))  # esperado: OK
