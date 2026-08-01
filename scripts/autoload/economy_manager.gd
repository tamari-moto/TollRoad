extends Node
## 経済シミュレーションの中核ロジックを管理するオートロード。
## 価格変動、需要と供給、資金管理などをここに実装していく。

signal gold_changed(new_amount: int)
signal price_updated(item_id: String, new_price: int)

var gold: int = 1000
var item_prices: Dictionary = {}


func add_gold(amount: int) -> void:
	gold += amount
	gold_changed.emit(gold)


func spend_gold(amount: int) -> bool:
	if amount > gold:
		return false
	gold -= amount
	gold_changed.emit(gold)
	return true


func set_price(item_id: String, price: int) -> void:
	item_prices[item_id] = price
	price_updated.emit(item_id, price)
