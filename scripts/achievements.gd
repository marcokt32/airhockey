class_name Achievements
extends RefCounted
## Catálogo das conquistas (Google Play Games) + constantes do rastreio.
## Cole o ID de cada conquista (criada no Play Console) no lugar de PLACEHOLDER.
## Enquanto o ID for PLACEHOLDER, a conquista é ganha e guardada no aparelho,
## mas nada é enviado ao Google (nada quebra).
##
## No Play Console, as marcadas "incremental" são do tipo Incremental com o nº de passos indicado;
## as marcadas "oculta" devem ser criadas com o estado inicial "Oculta".

const PLACEHOLDER := "COLOQUE_O_ID"

# ---------------------------------------------------------------- ajustes de regra
const FAST_GOAL_SECONDS := 5.0     # Relâmpago: gol até X s depois do saque
const ROCKET_SPEED := 600.0        # Foguete: velocidade do disco no gol (px/s)
const RICOCHET_BOUNCES := 3        # Ricochet: batidas na parede antes do gol
const BLOWOUT_DIFF := 5            # De lavada / Quebrou o sistema
const COMEBACK_DEFICIT := 3        # Time da virada: gols atrás em algum momento
const HAT_TRICK_RUN := 3           # Hat-trick: gols seguidos sem sofrer
const NIGHT_OWL_UNTIL_HOUR := 5    # Coruja: partida terminada entre 0h e esta hora
const ELITE_MIN_MATCHES := 30      # Taxa de elite: partidas válidas mínimas...
const ELITE_RATE := 70.0           # ...e taxa de vitórias (%)
const MY_CUSTOMER_WINS := 2        # Meu freguês: vitórias contra o mesmo jogador
const RIVALS_KEPT := 50            # quantos rivais lembrar (Meu freguês)

# ---------------------------------------------------------------- gol -> mensagem de rede
# O puck calcula as flags no servidor; o main.gd as manda DENTRO do int que o RPC _goal_fx já
# recebia (lado de quem marcou). Versões antigas do jogo ignoram esse valor, então continuam compatíveis.
const GOAL_FAST := 1               # gol rápido (Relâmpago)
const GOAL_ROCKET := 2             # disco muito veloz (Foguete)
const GOAL_OWN := 4                # gol contra (o último toque foi de quem sofreu o gol)
const GOAL_BOUNCE_SHIFT := 3       # bits 3..6 = batidas na parede desde o último toque (0..15)
const BOUNCE_CAP := 15

static func encode_goal(scorer_side: int, info: int) -> int:
	return scorer_side | (info << 1)

static func goal_scorer(code: int) -> int:
	return code & 1

static func goal_info(code: int) -> int:
	return code >> 1

static func goal_bounces(info: int) -> int:
	return (info >> GOAL_BOUNCE_SHIFT) & BOUNCE_CAP

# ---------------------------------------------------------------- IDs (40 conquistas = 1815 pts)
# chave: ID do Play Console   # pontos | nome | como ganhar
const IDS := {
	# Primeiros passos (50)
	"ice_breaker": "CgkIhvHshOkcEAIQAg",     # 10 | Quebre o gelo!     | vença sua 1ª partida contra a CPU
	"rookie": "CgkIhvHshOkcEAIQAw",          # 10 | Estreante          | conclua sua 1ª partida online
	"first_goal": "CgkIhvHshOkcEAIQBA",      # 10 | Primeiro gol       | marque seu 1º gol
	"welcome_arena": "CgkIhvHshOkcEAIQBQ",   # 20 | Bem-vindo à arena  | vença sua 1ª partida online
	# Placar e jogadas (350)
	"blowout": "CgkIhvHshOkcEAIQBg",         # 30 | De lavada          | vença com 5+ gols de vantagem
	"nail_biter": "CgkIhvHshOkcEAIQBw",      # 30 | Jogo acirrado      | vença por 1 gol (7 x 6)
	"comeback": "CgkIhvHshOkcEAIQCA",        # 50 | Time da virada     | vença depois de perder por 3+ gols
	"historic_rout": "CgkIhvHshOkcEAIQCQ",   # 60 | Goleada histórica  | vença por 7 x 0
	"hat_trick": "CgkIhvHshOkcEAIQCg",       # 40 | Hat-trick          | marque 3 gols seguidos sem sofrer
	"lightning": "CgkIhvHshOkcEAIQCw",       # 30 | Relâmpago          | gol até 5 s depois do saque
	"rocket": "CgkIhvHshOkcEAIQDA",          # 40 | Foguete            | gol com o disco a mais de 600 px/s
	"ricochet": "CgkIhvHshOkcEAIQDQ",        # 40 | Ricochet!          | gol com 3+ batidas na parede
	"own_goal": "CgkIhvHshOkcEAIQDg",        # 15 | Vira casaca        | faça um gol contra            (OCULTA)
	"deja_vu": "CgkIhvHshOkcEAIQKQ",         # 15 | Déjà vu            | perca por 7 x 1               (OCULTA)
	# Sequências (185)
	"last_place": "CgkIhvHshOkcEAIQDw",      # 15 | Lanterninha        | perca 5 seguidas              (OCULTA)
	"unbeaten": "CgkIhvHshOkcEAIQEA",        # 50 | Invicto            | vença 5 seguidas
	"unstoppable": "CgkIhvHshOkcEAIQEQ",     # 80 | Imparável          | vença 10 seguidas
	"hyped": "CgkIhvHshOkcEAIQEg",           # 40 | Embalado           | vença 3 online seguidas
	# Volume (500)
	"wins_10": "CgkIhvHshOkcEAIQEw",         # 20 | Pegando o jeito    | 10 vitórias                   (incremental: 10)
	"wins_50": "CgkIhvHshOkcEAIQFA",         # 50 | Veterano           | 50 vitórias                   (incremental: 50)
	"wins_200": "CgkIhvHshOkcEAIQFQ",        # 100| Lenda do gelo      | 200 vitórias                  (incremental: 200)
	"goals_100": "CgkIhvHshOkcEAIQFg",       # 40 | Artilheiro         | 100 gols                      (incremental: 100)
	"goals_500": "CgkIhvHshOkcEAIQFw",       # 80 | Metralhadora       | 500 gols                      (incremental: 500)
	"goals_1000": "CgkIhvHshOkcEAIQGA",      # 100| Canhão             | 1000 gols                     (incremental: 1000)
	"matches_100": "CgkIhvHshOkcEAIQGQ",     # 50 | Maratonista        | 100 partidas concluídas       (incremental: 100)
	"loyal": "CgkIhvHshOkcEAIQGg",           # 40 | Fiel               | jogue em 7 dias diferentes    (incremental: 7)
	"night_owl": "CgkIhvHshOkcEAIQGw",       # 20 | Coruja             | partida entre 0h e 5h         (OCULTA)
	# Contra a CPU (140)
	"hard_win": "CgkIhvHshOkcEAIQHA",        # 50 | Desafio aceito     | vença a CPU no Difícil
	"system_break": "CgkIhvHshOkcEAIQHg",    # 60 | Quebrou o sistema  | vença a CPU no Difícil por 5+ gols
	"dominator": "CgkIhvHshOkcEAIQHQ",       # 30 | Dominador          | vença a CPU nos 3 níveis
	# Online (380)
	"my_customer": "CgkIhvHshOkcEAIQIA",     # 40 | Meu freguês        | vença o mesmo jogador 2 vezes
	"revenge": "CgkIhvHshOkcEAIQIQ",         # 50 | Vingança           | vença a revanche depois de perder
	"ranked_in": "CgkIhvHshOkcEAIQHw",       # 30 | Entrou pro ranking | 10 partidas válidas para o ranking
	"net_king": "CgkIhvHshOkcEAIQIg",        # 60 | Rei da rede        | 25 vitórias online            (incremental: 25)
	"net_legend": "CgkIhvHshOkcEAIQIw",      # 100| Lenda online       | 100 vitórias online           (incremental: 100)
	"elite_rate": "CgkIhvHshOkcEAIQJA",      # 100| Taxa de elite      | 70%+ com 30+ partidas no ranking
	# Nível (210)
	"level_5": "CgkIhvHshOkcEAIQJQ",         # 20 | Nível 5            | chegue ao nível 5
	"level_10": "CgkIhvHshOkcEAIQJg",        # 30 | Nível 10           | chegue ao nível 10
	"level_20": "CgkIhvHshOkcEAIQJw",        # 60 | Nível 20           | chegue ao nível 20
	"level_30": "CgkIhvHshOkcEAIQKA",        # 100| Nível 30           | chegue ao nível 30
}

# Conquistas incrementais: chave -> [variável do PlayGames com o contador, passos para completar]
const INCREMENTAL := {
	"wins_10": ["wins", 10],
	"wins_50": ["wins", 50],
	"wins_200": ["wins", 200],
	"goals_100": ["goals", 100],
	"goals_500": ["goals", 500],
	"goals_1000": ["goals", 1000],
	"matches_100": ["matches", 100],
	"loyal": ["days_played", 7],
	"net_king": ["online_wins", 25],
	"net_legend": ["online_wins", 100],
}

static func has_key(key: String) -> bool:
	return IDS.has(key)

static func id_of(key: String) -> String:
	return str(IDS.get(key, ""))

static func is_valid_id(id: String) -> bool:
	return id != "" and id != PLACEHOLDER
