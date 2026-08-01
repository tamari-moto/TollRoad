extends Node
## ゲーム全体の状態を管理するオートロード。
## セーブ/ロード、現在の日付・ターン管理などをここに集約する。

signal day_advanced(day: int)

var current_day: int = 1
var player_name: String = "Player"


func advance_day() -> void:
	current_day += 1
	day_advanced.emit(current_day)
