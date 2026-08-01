extends Node2D


func _ready() -> void:
	print("EconomySim start. Day: %d, Gold: %d" % [GameState.current_day, EconomyManager.gold])
