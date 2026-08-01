extends Node2D

@onready var _label: Label = $UI/Label


func _ready() -> void:
	var session := GameState.session
	print("TollRoad start. Day: %d/%d, Silver: %d, City: %s" % [
		session.day, GameState.total_days(), session.silver, session.current_city])
	_refresh()
	session.silver_changed.connect(func(_amount: int) -> void: _refresh())
	session.day_advanced.connect(func(_day: int) -> void: _refresh())


func _refresh() -> void:
	var session := GameState.session
	_label.text = "%d日目 / %d日　　シルバー: %d" % [
		session.day, GameState.total_days(), session.silver]
