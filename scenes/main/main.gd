extends Node2D


func _ready() -> void:
	print("TollRoad start. Day: %d, Gold: %d" % [GameState.current_day, EconomyManager.gold])
