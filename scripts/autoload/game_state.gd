extends Node
## 現在プレイ中のセッションを保持するオートロード。
##
## ゲームのルールそのものは scripts/systems/game_session.gd にあり、ここは
## その入れ物と、UI からの共通の入口を提供するだけに留める。
## ロジックを autoload に置かないのは、--script のハーネスが autoload を
## 初期化しないため（詳細は CLAUDE.md）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

signal session_started(session: GameSession)

var session: GameSession


func _ready() -> void:
	start_new_game()


## 新しいプレイを開始する。seed を指定すると再現可能になる。
func start_new_game(rng_seed: int = 0) -> void:
	if rng_seed == 0:
		rng_seed = randi()
	session = GameSession.new(rng_seed)
	session_started.emit(session)


func current_day() -> int:
	return session.day if session else 1


func total_days() -> int:
	return GameData.TOTAL_DAYS
