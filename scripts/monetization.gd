extends Node
## Autoload "Monetization": anúncios do AdMob (intersticial entre partidas, abertura do app, banner nos menus)
## + compra "Remover anúncios".
##
## Registro: Project Settings > Autoload > monetization.gd, nome "Monetization".
##
## O resto do jogo usa só estas funções:
##   Monetization.on_match_finished()   -> uma partida terminou (conta e já deixa um anúncio carregado)
##   await Monetization.show_if_due()   -> ao SAIR depois da partida: mostra o anúncio se estiver na hora
##   Monetization.buy_remove_ads()      -> botão "Remover anúncios" do menu (compra única na Google Play)
##   Monetization.set_banner_wanted("menu", true)  -> mostra/esconde o banner do rodapé (aparece se alguém o quer)
##   Monetization.banner_reserved_height(vp)      -> altura a deixar livre no rodapé (unidades da tela do jogo)
##   Monetization.startup_needed() + await Monetization.run_startup()  -> loading + anúncio de abertura do app
##
## Fluxo: consentimento (UMP) -> inicia o SDK -> carrega um anúncio -> mostra quando as regras deixam.
## Só roda no Android. No PC/editor tudo vira "não faz nada" e o jogo segue normal.
## Quem comprou "Remover anúncios" nunca passa por isso (nem pelo pedido de consentimento).

signal ads_removed_changed(removed: bool)
signal store_changed                       # preço carregado da Google Play
signal purchase_busy_changed(busy: bool)   # compra em andamento (o menu desativa o botão)
signal purchase_message(text: String)      # texto para mostrar ao jogador
signal _closed   # interno: o anúncio fechou (ou falhou ao abrir)
signal _app_open_closed   # interno: o anúncio de abertura fechou (ou falhou ao abrir)

# --- IDs ---
# Debug (Godot com depuração) SEMPRE usa o bloco de teste do Google: nunca mostra anúncio real
# (clicar nos próprios anúncios reais pode suspender a conta do AdMob).
# Intersticial: fim de partida (AdMob: "fim-partida")
const INTERSTITIAL_ID_TEST := "ca-app-pub-3940256099942544/1033173712"
const INTERSTITIAL_ID_PROD := "ca-app-pub-8119130352737496/4232687147"
# Banner do rodapé: menu inicial e menu do avatar (AdMob: "banner-menu")
const BANNER_ID_TEST := "ca-app-pub-3940256099942544/6300978111"
const BANNER_ID_PROD := "ca-app-pub-8119130352737496/6583693325"
# Abertura do app (AdMob: "abertura-app"; o bloco precisa ser do formato "Abertura de app")
const APP_OPEN_ID_TEST := "ca-app-pub-3940256099942544/9257395921"
const APP_OPEN_ID_PROD := "ca-app-pub-8119130352737496/6935047115"

# --- Regras de exibição ---
const FREE_MATCHES := 0                #2 as primeiras partidas do jogador não têm anúncio
const MATCHES_BETWEEN_ADS := 0         #3 depois, no máximo 1 anúncio a cada 3 partidas...
const MIN_SECONDS_BETWEEN_ADS := 0   #180 ...e com pelo menos 3 minutos entre eles
const AD_MAX_AGE_SECONDS := 50 * 60    # anúncio carregado vence em ~1h: descarta e carrega outro
const SHOW_SAFETY_TIMEOUT := 120.0     # se o anúncio nunca avisar que fechou, segue o jogo
const RETRY_SECONDS := 45.0            # nova tentativa se o carregamento falhar
const MAX_LOAD_FAILS := 3              # depois disso espera a próxima partida para tentar de novo

# --- Banner do rodapé ---
const BANNER_HEIGHT_DP := 50.0         # AdSize.BANNER = 320 x 50 dp
const BANNER_MARGIN_DP := 6.0          # folga entre o conteúdo do menu e o banner
const BANNER_RETRY_SECONDS := 60.0     # nova tentativa se o banner não carregar

# --- Abertura do app (loading + anúncio) ---
const APP_OPEN_SKIP_FIRST_LAUNCH := false   # na 1ª vez que o jogo abre: sem loading e sem anúncio
const STARTUP_MIN_SECONDS := 1.5           # o loading nunca "pisca": fica pelo menos isso na tela
const STARTUP_AD_WAIT_SECONDS := 5.0       # depois do consentimento, espera até isso o anúncio carregar
const STARTUP_HARD_CAP_SECONDS := 30.0     # trava de segurança: nunca prende o jogador no loading
const PREVIEW_LOADING_IN_EDITOR := false   # true = mostra o loading (sem anúncio) no PC para ajustar o visual

const SAVE_PATH := "user://monetization.cfg"

# --- Compra "Remover anúncios" (Google Play Billing) ---
# O ID precisa ser IGUAL ao "ID do produto" criado no Play Console (não dá para mudar depois).
const REMOVE_ADS_PRODUCT_ID := "remove_ads"
const BILLING_WAIT_SECONDS := 4.0      # espera a Play dizer se a conta já comprou, antes do pedido de consentimento
const BUY_TIMEOUT_SECONDS := 15.0      # se a Play não responder ao tocar no botão, libera o botão de novo

# Códigos da biblioteca do Google Play Billing (valores fixos do Google)
const BR_OK := 0
const BR_USER_CANCELED := 1
const BR_ITEM_ALREADY_OWNED := 7
const PS_PURCHASED := 1
const PS_PENDING := 2

var ads_removed := false               # comprou "Remover anúncios"
var matches_total := 0                 # partidas terminadas (para o período sem anúncio)
var matches_since_ad := 0
var last_ad_unix := 0.0

var _supported := false                # Android com o plugin de anúncios
var _consent_done := false
var _can_request_ads := false          # consentimento resolvido: NÃO_EXIGIDO ou OBTIDO
var _sdk_started := false
var _sdk_ready := false

var _ad: InterstitialAd = null         # anúncio carregado, esperando a hora
var _ad_loaded_unix := 0.0
var _loading := false
var _load_fails := 0
var _showing := false
var _showing_ad: InterstitialAd = null

var _load_cb := InterstitialAdLoadCallback.new()
var _content_cb := FullScreenContentCallback.new()

var remove_ads_price := ""             # ex.: "R$ 9,90" (vem da Play, já na moeda do jogador)
var purchase_busy := false

var _billing: BillingClient = null
var _billing_ready := false
var _product_loaded := false
var _buy_when_ready := false
var _buy_attempt := 0
var _consent_started := false

var launches := 0                      # quantas vezes o jogo abriu
var startup_pending := true            # loading + anúncio de abertura rodam UMA vez por abertura do app

var _app_open_ad: AppOpenAd = null
var _app_open_loading := false
var _app_open_resolved := false        # carregou, falhou ou desistimos: o loading pode seguir
var _startup_done := false
var _showing_app_open := false
var _app_open_load_cb := AppOpenAdLoadCallback.new()
var _app_open_content_cb := FullScreenContentCallback.new()

var _banner: AdView = null
var _banner_wants := {}                # quem quer o banner agora, ex.: {"menu": true, "pause": false}
var _banner_fails := 0


func _ready() -> void:
	_load_state()
	launches += 1
	_save_state()
	_supported = OS.get_name() == "Android"
	_load_cb.on_ad_loaded = _on_ad_loaded
	_load_cb.on_ad_failed_to_load = _on_ad_failed_to_load
	_content_cb.on_ad_dismissed_full_screen_content = _on_ad_closed
	_content_cb.on_ad_failed_to_show_full_screen_content = _on_ad_show_failed
	_app_open_load_cb.on_ad_loaded = _on_app_open_loaded
	_app_open_load_cb.on_ad_failed_to_load = _on_app_open_failed
	_app_open_content_cb.on_ad_dismissed_full_screen_content = _on_app_open_closed
	_app_open_content_cb.on_ad_failed_to_show_full_screen_content = _on_app_open_show_failed
	if _supported:
		_start_billing.call_deferred()   # confere o que a conta já comprou (restaura / detecta reembolso)
		if not ads_removed:
			# Dá um instante para a Play dizer se esta conta já comprou (reinstalou, trocou de aparelho)
			# antes de pedir consentimento, para quem já pagou não ver o formulário à toa.
			get_tree().create_timer(BILLING_WAIT_SECONDS).timeout.connect(_begin_consent_if_needed)


# ---------------------------------------------------------------- API para o jogo

## Uma partida terminou (cada aparelho conta a sua). Deixa o próximo anúncio carregando.
func on_match_finished() -> void:
	matches_total += 1
	matches_since_ad += 1
	_save_state()
	_load_fails = 0
	_load_ad()

## Chame ao SAIR depois de uma partida terminada. Se estiver na hora, mostra o anúncio e só
## volta quando ele fechar; se não, volta na hora.
func show_if_due() -> void:
	if not is_due():
		return
	_showing = true
	_showing_ad = _ad
	_ad = null
	matches_since_ad = 0
	last_ad_unix = Time.get_unix_time_from_system()
	_save_state()
	get_tree().create_timer(SHOW_SAFETY_TIMEOUT).timeout.connect(_on_show_timeout)
	_showing_ad.show()
	await _closed

## Já pode mostrar? (regras de frequência + anúncio carregado e válido)
func is_due() -> bool:
	if not _supported or ads_removed or not _can_request_ads or _showing or _showing_app_open:
		return false
	if _ad == null:
		return false
	if Time.get_unix_time_from_system() - _ad_loaded_unix > AD_MAX_AGE_SECONDS:
		_discard_ad()
		return false
	if matches_total <= FREE_MATCHES or matches_since_ad < MATCHES_BETWEEN_ADS:
		return false
	return Time.get_unix_time_from_system() - last_ad_unix >= MIN_SECONDS_BETWEEN_ADS

## Liga/desliga o "anúncios removidos". Chamado pela compra, pela restauração e pelo reembolso.
func set_ads_removed(value: bool) -> void:
	if value == ads_removed:
		return
	ads_removed = value
	_save_state()
	if value:
		_discard_ad()
		_discard_app_open()
	elif _supported:
		# reembolso: volta a ter anúncios
		if _consent_done and _can_request_ads:
			_start_sdk()
		else:
			_begin_consent_if_needed()
	_sync_banner()
	ads_removed_changed.emit(value)

## Formulário "Opções de privacidade" (obrigatório só em alguns países, como na Europa).
func show_privacy_options() -> void:
	if _supported:
		UserMessagingPlatform.show_privacy_options_form(_on_privacy_options_closed)

func privacy_options_required() -> bool:
	if not _supported:
		return false
	return UserMessagingPlatform.consent_information.get_privacy_options_requirement_status() \
			== ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED


# ---------------------------------------------------------------- consentimento (UMP)

#func _begin_consent_if_needed() -> void:
#	if _consent_started or ads_removed or not _supported:
#		return
#	_consent_started = true
#	_start_consent()

func _begin_consent_if_needed() -> void:
	# TESTE LOCAL: Pula a checagem do UMP e inicializa o AdMob direto no Brasil
	_consent_done = true
	_can_request_ads = true
	_start_sdk()

func _start_consent() -> void:
	if _consent_done or _sdk_started:
		return
	var request := ConsentRequestParameters.new()
	request.tag_for_under_age_of_consent = false
	UserMessagingPlatform.consent_information.update(request, _on_consent_info_ok, _on_consent_info_failed)

func _on_consent_info_ok() -> void:
	if UserMessagingPlatform.consent_information.get_is_consent_form_available():
		UserMessagingPlatform.load_consent_form(_on_form_loaded, _on_form_load_failed)
	else:
		_finish_consent()

func _on_consent_info_failed(error: FormError) -> void:
	push_warning("[Ads] Consentimento: %s" % error.message)
	_finish_consent()

func _on_form_loaded(form: ConsentForm) -> void:
	var status := UserMessagingPlatform.consent_information.get_consent_status()
	if status == ConsentInformation.ConsentStatus.REQUIRED:
		form.show(_on_form_dismissed)
	else:
		_finish_consent()

func _on_form_load_failed(error: FormError) -> void:
	push_warning("[Ads] Formulário de consentimento: %s" % error.message)
	_finish_consent()

func _on_form_dismissed(_error: FormError) -> void:
	_finish_consent()

func _on_privacy_options_closed(_error: FormError) -> void:
	_finish_consent()

# Só pede anúncios se o consentimento não é exigido ou já foi dado. Se não deu para saber
# (sem internet, por exemplo), não pede anúncio nesta sessão: é o lado seguro.
func _finish_consent() -> void:
	_consent_done = true
	var status := UserMessagingPlatform.consent_information.get_consent_status()
	_can_request_ads = status == ConsentInformation.ConsentStatus.NOT_REQUIRED \
			or status == ConsentInformation.ConsentStatus.OBTAINED
	if _can_request_ads and not ads_removed:
		_start_sdk()
	else:
		_app_open_resolved = true   # sem anúncio de abertura: o loading não precisa esperar


# ---------------------------------------------------------------- SDK e anúncio

func _start_sdk() -> void:
	if _sdk_started:
		_load_ad()
		return
	_sdk_started = true
	var listener := OnInitializationCompleteListener.new()
	listener.on_initialization_complete = _on_sdk_ready
	MobileAds.initialize(listener)

func _on_sdk_ready(_status: InitializationStatus) -> void:
	_sdk_ready = true
	_load_app_open()   # o loading está esperando por este
	_load_ad()
	_sync_banner()

func _unit_id() -> String:
	return _pick_id(INTERSTITIAL_ID_TEST, INTERSTITIAL_ID_PROD)

# Debug SEMPRE usa o bloco de teste do Google (clicar nos próprios anúncios reais pode suspender a conta).
func _pick_id(test_id: String, prod_id: String) -> String:
	if OS.is_debug_build() or prod_id == "":
		if not OS.is_debug_build():
			push_warning("[Ads] ID de produção vazio: usando o bloco de TESTE.")
		return test_id
	return prod_id

func _load_ad() -> void:
	if not _sdk_ready or not _can_request_ads or ads_removed:
		return
	if _loading or _ad != null or _showing:
		return
	_loading = true
	InterstitialAdLoader.new().load(_unit_id(), AdRequest.new(), _load_cb)

func _on_ad_loaded(ad: InterstitialAd) -> void:
	_loading = false
	_load_fails = 0
	if ads_removed:
		ad.destroy()
		return
	ad.full_screen_content_callback = _content_cb
	_ad = ad
	_ad_loaded_unix = Time.get_unix_time_from_system()

func _on_ad_failed_to_load(error: LoadAdError) -> void:
	_loading = false
	_load_fails += 1
	push_warning("[Ads] Falha ao carregar: %s" % error.message)
	if _load_fails < MAX_LOAD_FAILS:
		get_tree().create_timer(RETRY_SECONDS).timeout.connect(_load_ad)

func _on_ad_closed() -> void:
	_finish_show()

func _on_ad_show_failed(error: AdError) -> void:
	push_warning("[Ads] Falha ao mostrar: %s" % error.message)
	_finish_show()

func _on_show_timeout() -> void:
	if _showing:
		_finish_show()

func _finish_show() -> void:
	if not _showing:
		return
	_showing = false
	if _showing_ad != null:
		_showing_ad.destroy()
		_showing_ad = null
	_closed.emit()
	_load_ad()   # já deixa o próximo carregando

func _discard_ad() -> void:
	if _ad != null:
		_ad.destroy()
		_ad = null


# ---------------------------------------------------------------- abertura do app (loading + anúncio)
# O menu mostra a tela de loading e chama run_startup(): ela espera o consentimento e o anúncio de
# abertura carregarem (com limites de tempo), mostra o anúncio e só então devolve o controle.

func startup_needed() -> bool:
	if not startup_pending or ads_removed:
		return false
	if not _supported:
		return OS.is_debug_build() and PREVIEW_LOADING_IN_EDITOR
	return _app_open_allowed()

func _app_open_allowed() -> bool:
	return _supported and not ads_removed and not _startup_done \
			and not (APP_OPEN_SKIP_FIRST_LAUNCH and launches <= 1)

## Use com await. Volta quando o loading pode sair (anúncio fechou, falhou ou o tempo acabou).
func run_startup() -> void:
	startup_pending = false
	var t0 := Time.get_ticks_msec()
	var consent_ms := -1
	while true:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		var elapsed := (now - t0) / 1000.0
		if ads_removed or elapsed >= STARTUP_HARD_CAP_SECONDS:
			break
		if not _supported:
			if elapsed >= STARTUP_MIN_SECONDS:
				break
			continue
		if _consent_done and consent_ms < 0:
			consent_ms = now
		# o tempo de espera do anúncio só conta depois do consentimento (o formulário pode demorar)
		if not _app_open_resolved and consent_ms >= 0 \
				and (now - consent_ms) / 1000.0 >= STARTUP_AD_WAIT_SECONDS:
			_app_open_resolved = true   # demorou demais: abre o menu sem anúncio
		if _app_open_resolved and elapsed >= STARTUP_MIN_SECONDS:
			break
	_startup_done = true
	if _app_open_ad != null and not ads_removed:
		await _show_app_open()
	else:
		_discard_app_open()

func _load_app_open() -> void:
	if not _app_open_allowed() or _app_open_loading or _app_open_ad != null or _app_open_resolved:
		return
	_app_open_loading = true
	AppOpenAdLoader.new().load(_pick_id(APP_OPEN_ID_TEST, APP_OPEN_ID_PROD), AdRequest.new(), _app_open_load_cb)

func _on_app_open_loaded(ad: AppOpenAd) -> void:
	_app_open_loading = false
	_app_open_resolved = true
	if ads_removed or _startup_done:
		ad.destroy()   # chegou tarde (o loading já saiu) ou a pessoa comprou
		return
	ad.full_screen_content_callback = _app_open_content_cb
	_app_open_ad = ad

func _on_app_open_failed(error: LoadAdError) -> void:
	_app_open_loading = false
	_app_open_resolved = true
	push_warning("[Ads] Abertura: falha ao carregar: %s" % error.message)

func _show_app_open() -> void:
	_showing_app_open = true
	last_ad_unix = Time.get_unix_time_from_system()   # conta como último anúncio: o intersticial espera
	_save_state()
	get_tree().create_timer(SHOW_SAFETY_TIMEOUT).timeout.connect(_on_app_open_timeout)
	_app_open_ad.show()
	await _app_open_closed

func _on_app_open_closed() -> void:
	_finish_app_open()

func _on_app_open_show_failed(error: AdError) -> void:
	push_warning("[Ads] Abertura: falha ao mostrar: %s" % error.message)
	_finish_app_open()

func _on_app_open_timeout() -> void:
	if _showing_app_open:
		_finish_app_open()

func _finish_app_open() -> void:
	if not _showing_app_open:
		return
	_showing_app_open = false
	_discard_app_open()
	_app_open_closed.emit()
	_load_ad()

func _discard_app_open() -> void:
	if _app_open_ad != null:
		_app_open_ad.destroy()
		_app_open_ad = null


# ---------------------------------------------------------------- banner do rodapé
# O banner é uma view nativa por cima do jogo (não é um nó do Godot). Só aparece enquanto alguém o "quer":
# o menu inicial ("menu") e o menu do avatar durante a partida ("pause"). Nunca com a partida rolando sem
# menu aberto: um toque perdido no rodapé viraria clique acidental (o AdMob pune isso).

func set_banner_wanted(source: String, wanted: bool) -> void:
	_banner_wants[source] = wanted
	_sync_banner()

func banner_enabled() -> bool:
	return (_supported or OS.is_debug_build()) and not ads_removed

## Altura a deixar livre no rodapé, em unidades da tela do jogo (0 se não há banner).
func banner_reserved_height(vp: Viewport) -> float:
	if not banner_enabled():
		return 0.0
	var win_h := float(DisplayServer.window_get_size().y)
	if not _supported or win_h <= 0.0:
		return BANNER_HEIGHT_DP + BANNER_MARGIN_DP   # PC: só para você ver o espaço no layout
	var density := DisplayServer.screen_get_dpi() / 160.0     # dp -> pixels
	var scale := vp.get_visible_rect().size.y / win_h          # pixels -> unidades do jogo
	return (BANNER_HEIGHT_DP + BANNER_MARGIN_DP) * density * scale

func _banner_should_show() -> bool:
	for source in _banner_wants:
		if _banner_wants[source]:
			return true
	return false

func _sync_banner() -> void:
	if not _supported:
		return
	if ads_removed:
		_destroy_banner()
		return
	if not _banner_should_show():
		if _banner != null:
			_banner.hide()
		return
	if not _sdk_ready or not _can_request_ads:
		return   # quando o SDK ficar pronto, _on_sdk_ready chama de novo
	if _banner == null:
		_create_banner()
	else:
		_banner.show()

func _create_banner() -> void:
	var pos = _bottom_position()
	if pos == null:
		push_warning("[Ads] Banner: não achei a posição BOTTOM do plugin. Veja _bottom_position().")
		return
	_banner_fails = 0
	_banner = AdView.new(_pick_id(BANNER_ID_TEST, BANNER_ID_PROD), AdSize.BANNER, pos)
	_banner.ad_listener.on_ad_loaded = _on_banner_loaded
	_banner.ad_listener.on_ad_failed_to_load = _on_banner_failed
	_banner.load_ad(AdRequest.new())

# A API do plugin mudou entre versões: as antigas usam o enum AdPosition.Values.BOTTOM, as novas
# AdPosition.BOTTOM. Procura dos dois jeitos para não dar erro de leitura do script em nenhuma delas.
# Se o banner não aparecer e o Logcat reclamar daqui, troque o corpo por UMA das linhas:
#     return AdPosition.Values.BOTTOM     (versões antigas)
#     return AdPosition.BOTTOM            (versões novas)
func _bottom_position() -> Variant:
	for c in ProjectSettings.get_global_class_list():
		if c["class"] != "AdPosition":
			continue
		var sc: Script = load(c["path"])
		var consts: Dictionary = sc.get_script_constant_map()
		if consts.has("Values"):
			return consts["Values"]["BOTTOM"]
		if consts.has("BOTTOM"):
			return consts["BOTTOM"]
		return sc.get("BOTTOM")
	return null

func _on_banner_loaded() -> void:
	_banner_fails = 0

func _on_banner_failed(error: LoadAdError) -> void:
	_banner_fails += 1
	push_warning("[Ads] Banner: falha ao carregar: %s" % error.message)
	if _banner_fails < MAX_LOAD_FAILS:
		get_tree().create_timer(BANNER_RETRY_SECONDS).timeout.connect(_retry_banner)

func _retry_banner() -> void:
	if _banner != null:
		_banner.load_ad(AdRequest.new())

func _destroy_banner() -> void:
	if _banner != null:
		_banner.destroy()
		_banner = null


# ---------------------------------------------------------------- compra "Remover anúncios"
# Compra ÚNICA (não é assinatura). A fonte da verdade é a Google Play: a cada abertura o jogo pergunta
# o que a conta já comprou. Reinstalou ou trocou de aparelho = restaura sozinho; reembolso = volta a ter anúncio.

## O menu deve mostrar o botão? (no PC/editor só em debug, para você ver o layout)
func can_offer_remove_ads() -> bool:
	return (_supported or OS.is_debug_build()) and not ads_removed

## Botão "Remover anúncios": abre a tela de pagamento da Google Play.
func buy_remove_ads() -> void:
	if ads_removed or purchase_busy:
		return
	if not _supported:
		purchase_message.emit("Compras só funcionam no Android (teste num aparelho).")
		return
	if _billing == null:
		purchase_message.emit("Compras indisponíveis neste aparelho.")
		return
	_set_busy(true)
	if _billing_ready and _product_loaded:
		_launch_purchase()
		return
	_buy_when_ready = true   # abre a compra assim que a conexão e o produto estiverem prontos
	_buy_attempt += 1
	get_tree().create_timer(BUY_TIMEOUT_SECONDS).timeout.connect(_on_buy_timeout.bind(_buy_attempt))
	if _billing_ready:
		_query_product()
	else:
		_billing.start_connection()

func _start_billing() -> void:
	_billing = BillingClient.new()
	_bind("connected", _on_billing_connected)
	_bind("disconnected", _on_billing_disconnected)
	_bind("connect_error", _on_billing_connect_error)
	_bind("query_product_details_response", _on_product_details)
	_bind("query_purchases_response", _on_query_purchases_response)
	_bind("on_purchase_updated", _on_purchase_updated)
	_bind("on_purchases_updated", _on_purchase_updated)   # nome usado em algumas versões do plugin
	_bind("acknowledge_purchase_response", _on_acknowledge_response)
	_billing.start_connection()

# Conecta só se o plugin tiver esse sinal (os nomes variam um pouco entre versões)
func _bind(signal_name: StringName, callback: Callable) -> void:
	if _billing.has_signal(signal_name):
		_billing.connect(signal_name, callback)

func _on_billing_connected() -> void:
	_billing_ready = true
	_billing.query_purchases(BillingClient.ProductType.INAPP)
	_query_product()

func _on_billing_disconnected() -> void:
	_billing_ready = false
	_product_loaded = false

func _on_billing_connect_error(code: int, message: String) -> void:
	_billing_ready = false
	push_warning("[Billing] Conexão falhou (%d): %s" % [code, message])
	_begin_consent_if_needed()
	if _buy_when_ready:
		_finish_purchase("Não foi possível falar com a Google Play. Tente novamente.")

func _query_product() -> void:
	_billing.query_product_details([REMOVE_ADS_PRODUCT_ID], BillingClient.ProductType.INAPP)

func _on_product_details(result: Dictionary) -> void:
	if int(result.get("response_code", -1)) == BR_OK:
		for d in result.get("product_details", []):
			if str(d.get("product_id", "")) == REMOVE_ADS_PRODUCT_ID:
				_product_loaded = true
				remove_ads_price = _price_of(d)
	else:
		push_warning("[Billing] Consulta do produto falhou: %s" % str(result.get("debug_message", "")))
	store_changed.emit()
	if not _buy_when_ready:
		return
	_buy_when_ready = false
	if ads_removed:
		_finish_purchase("")
	elif _product_loaded:
		_launch_purchase()
	else:
		_finish_purchase("Produto não encontrado na Google Play.")

func _price_of(details: Dictionary) -> String:
	var offer = details.get("one_time_purchase_offer_details", null)
	if offer is Dictionary:
		return str(offer.get("formatted_price", ""))
	return str(details.get("formatted_price", ""))

func _launch_purchase() -> void:
	var r: Dictionary = _billing.purchase(REMOVE_ADS_PRODUCT_ID)
	if int(r.get("response_code", -1)) != BR_OK:
		push_warning("[Billing] Não abriu a compra: %s" % str(r.get("debug_message", "")))
		_finish_purchase("Não foi possível abrir a compra.")
	# se abriu, o resultado chega em _on_purchase_updated

func _on_buy_timeout(attempt: int) -> void:
	if attempt == _buy_attempt and purchase_busy and _buy_when_ready:
		_finish_purchase("Sem resposta da Google Play. Tente novamente.")

# Resultado da tela de pagamento (comprou, cancelou, erro...)
func _on_purchase_updated(result: Dictionary) -> void:
	var code := int(result.get("response_code", -1))
	if code == BR_OK:
		for p in result.get("purchases", []):
			_handle_purchase(p, true)
		_finish_purchase("")
	elif code == BR_USER_CANCELED:
		_finish_purchase("Compra cancelada.")
	elif code == BR_ITEM_ALREADY_OWNED:
		_finish_purchase("Você já comprou. Restaurando...")
		_billing.query_purchases(BillingClient.ProductType.INAPP)
	else:
		push_warning("[Billing] Compra falhou (%d): %s" % [code, str(result.get("debug_message", ""))])
		_finish_purchase("A compra não foi concluída.")

# O que a conta já tem (chamado ao abrir o jogo e depois do "você já comprou")
func _on_query_purchases_response(result: Dictionary) -> void:
	if int(result.get("response_code", -1)) == BR_OK:
		var owned := false
		var pending := false
		var was_removed := ads_removed
		for p in result.get("purchases", []):
			if not (REMOVE_ADS_PRODUCT_ID in p.get("product_ids", [])):
				continue
			var st := int(p.get("purchase_state", 0))
			owned = owned or st == PS_PURCHASED
			pending = pending or st == PS_PENDING
			_handle_purchase(p, not was_removed)
		# só reverte se a Play respondeu OK e a compra sumiu (reembolso/estorno)
		if ads_removed and not owned and not pending:
			set_ads_removed(false)
	else:
		push_warning("[Billing] Consulta de compras falhou: %s" % str(result.get("debug_message", "")))
	_begin_consent_if_needed()

func _handle_purchase(p: Dictionary, announce: bool) -> void:
	if not (REMOVE_ADS_PRODUCT_ID in p.get("product_ids", [])):
		return
	var state := int(p.get("purchase_state", 0))
	if state == PS_PURCHASED:
		set_ads_removed(true)
		# Obrigatório: sem "confirmar" em 3 dias a Google devolve o dinheiro e cancela a compra.
		# Se falhar agora, tenta de novo na próxima abertura (a consulta acima passa por aqui).
		if not bool(p.get("is_acknowledged", false)):
			_billing.acknowledge_purchase(str(p.get("purchase_token", "")))
		if announce:
			purchase_message.emit("Anúncios removidos. Obrigado por apoiar o jogo!")
	elif state == PS_PENDING and announce:
		purchase_message.emit("Pagamento pendente. Os anúncios saem assim que for aprovado.")

func _on_acknowledge_response(result: Dictionary) -> void:
	if int(result.get("response_code", -1)) != BR_OK:
		push_warning("[Billing] Confirmação da compra falhou: %s" % str(result.get("debug_message", "")))

func _finish_purchase(message: String) -> void:
	_buy_when_ready = false
	_set_busy(false)
	if message != "":
		purchase_message.emit(message)

func _set_busy(value: bool) -> void:
	if purchase_busy == value:
		return
	purchase_busy = value
	purchase_busy_changed.emit(value)


# ---------------------------------------------------------------- estado no aparelho

func _load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	ads_removed = bool(cfg.get_value("ads", "removed", false))
	matches_total = int(cfg.get_value("ads", "matches_total", 0))
	matches_since_ad = int(cfg.get_value("ads", "matches_since_ad", 0))
	last_ad_unix = float(cfg.get_value("ads", "last_ad_unix", 0.0))
	launches = int(cfg.get_value("ads", "launches", 0))

func _save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("ads", "removed", ads_removed)
	cfg.set_value("ads", "matches_total", matches_total)
	cfg.set_value("ads", "matches_since_ad", matches_since_ad)
	cfg.set_value("ads", "last_ad_unix", last_ad_unix)
	cfg.set_value("ads", "launches", launches)
	cfg.save(SAVE_PATH)
