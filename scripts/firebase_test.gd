extends Node
## Script de teste: anexe a um Node numa cena vazia e rode essa cena (F6).
## Pode apagar depois que o Firebase estiver validado.

func _ready() -> void:
	print("== Teste Firebase (perfil: %s) ==" % Firebase.profile)

	var ok: bool = await Firebase.sign_in()
	print("login: ", ok, " | uid: ", Firebase.uid)
	if not ok:
		return

	var path := "tests/%s" % Firebase.uid
	var r: Dictionary = await Firebase.db_set(path, {"hello": "mundo", "ts": Firebase.SERVER_TS})
	print("set: ok=", r.ok, " erro=", r.error)

	r = await Firebase.db_get(path)
	print("get: ", r.data)

	# Vê o que o OUTRO aparelho/instância escreve em tests/shared
	Firebase.watch("tests/shared", func(v): print("tests/shared mudou: ", v))

	# Escreve em tests/shared a cada 3 s
	while true:
		await get_tree().create_timer(3.0).timeout
		await Firebase.db_set("tests/shared", {"from": Firebase.uid, "t": Time.get_ticks_msec()})
