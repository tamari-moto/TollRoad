extends Node
## 現在プレイ中のセッションを保持するオートロード。
##
## ゲームのルールそのものは scripts/systems/game_session.gd にあり、ここは
## その入れ物と、UI からの共通の入口を提供するだけに留める。
## ロジックを autoload に置かないのは、--script のハーネスが autoload を
## 初期化しないため（詳細は CLAUDE.md）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")

signal session_started(session: GameSession)

var session: GameSession


func _ready() -> void:
	# 起動時のセッションはセーブを消さない。開始画面で「続きから」を
	# 選べるようにするため、この時点ではまだ消せない。
	# 実際に新規で始めると決まった時点（開始ボタン）で消える。
	_use_session(GameSession.new(randi()))


## 新しいプレイを開始する。seed を指定すると再現可能になる。
##
## 古いセーブは消す。残しておくと「新規開始 → 何もせず終了 → 続きから」で
## 前のプレイが復活してしまう。
func start_new_game(rng_seed: int = 0) -> void:
	if rng_seed == 0:
		rng_seed = randi()
	SaveManager.delete_save()
	_use_session(GameSession.new(rng_seed))


## セーブから再開する。読めなければ false（呼び出し側が新規開始を選ぶ）。
func continue_game() -> bool:
	var loaded: GameSession = SaveManager.load_game()
	if loaded == null:
		return false
	_use_session(loaded)
	return true


## 今の状態を保存する。60日を終えた後は保存しない
## （結果画面から終わった状態に戻れても意味がない）。
func save_game() -> bool:
	if session == null or session.is_over():
		return false
	return SaveManager.save_game(session)


## 続きから始められるセーブがあるか。開始画面のボタンの出し分けに使う。
func has_save() -> bool:
	return SaveManager.has_save()


## セッションを差し替え、日送りのたびに自動保存するよう繋ぐ。
func _use_session(new_session: GameSession) -> void:
	if session != null and session.day_advanced.is_connected(_on_day_advanced):
		session.day_advanced.disconnect(_on_day_advanced)
	session = new_session
	session.day_advanced.connect(_on_day_advanced)
	session_started.emit(session)


## 自動保存は日が進んだ時だけ。売買のたびに書くと頻度が高すぎる一方、
## 日送りは1日1回で、失っても直前の取引だけで済む。
##
## 60日を終えたらセーブを**消す**。保存しないだけだと最終日の1つ前の記録が
## 残り、結果を見た後に「続きから」で最終日をやり直せてしまう。
func _on_day_advanced(_day: int) -> void:
	if session != null and session.is_over():
		SaveManager.delete_save()
		return
	save_game()


func current_day() -> int:
	return session.day if session else 1


func total_days() -> int:
	return GameData.TOTAL_DAYS
