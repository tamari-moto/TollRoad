extends "res://scripts/systems/scenario_base.gd"
## デバッグモード（市場データのグラフ表示）の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m26.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const DebugPanel = preload("res://scripts/ui/debug_panel.gd")


func _init() -> void:
	_test_configure_outside_tree()
	_test_by_item_view_all_items()
	_test_by_city_view_all_cities()
	_test_rare_item_zero_stock_cap()
	_test_toggle_visible()
	_test_production_consumption_text()
	_test_price_text()
	_finish()


## ツリーに入れなくても bind() だけで完全に構築できること。
## --script のハーネスでは _ready() が走らないため、_configure() が
## _init()/bind() 経由でも完走する必要がある。
func _test_configure_outside_tree() -> void:
	print("--- ツリー外での構築 ---")
	var session: GameSession = GameSession.new(1)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	_check(panel.row_count() > 0, "bind() だけで行が構築される", str(panel.row_count()))
	_check(not panel.visible, "初期状態は非表示", str(panel.visible))


## 品目→全都市ビュー：19品目すべてで、都市の数ぶん行ができる。
func _test_by_item_view_all_items() -> void:
	print("--- 品目→全都市ビュー ---")
	var session: GameSession = GameSession.new(2)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	panel.show_by_item_view()
	var city_count: int = GameData.CITIES.size()
	for item_id: String in GameData.ITEMS:
		panel.select_item(item_id)
		_check(panel.row_count() == city_count,
			"%s を選ぶと都市数ぶん(%d)の行になる" % [item_id, city_count],
			str(panel.row_count()))


## 都市→全品目ビュー：10都市すべてで、品目の数ぶん行ができる。
func _test_by_city_view_all_cities() -> void:
	print("--- 都市→全品目ビュー ---")
	var session: GameSession = GameSession.new(3)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	panel.show_by_city_view()
	var item_count: int = GameData.ITEMS.size()
	for city_id: String in GameData.CITIES:
		panel.select_city(city_id)
		_check(panel.row_count() == item_count,
			"%s を選ぶと品目数ぶん(%d)の行になる" % [city_id, item_count],
			str(panel.row_count()))


## レア品（生産0）は在庫上限も常に0。ゼロ除算せず ratio() が 0.0 になること。
func _test_rare_item_zero_stock_cap() -> void:
	print("--- レア品の在庫バー ---")
	var session: GameSession = GameSession.new(4)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	panel.show_by_item_view()
	for item_id: String in ["sunstone", "ancient_relic"]:
		panel.select_item(item_id)
		for city_id: String in GameData.CITIES:
			var ratio: float = panel.stock_bar_for(city_id).ratio()
			_check(ratio == 0.0 and not is_nan(ratio),
				"%s @ %s の在庫バーは0（生産0のため）" % [item_id, city_id], str(ratio))


func _test_toggle_visible() -> void:
	print("--- 表示切り替え ---")
	var session: GameSession = GameSession.new(5)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	_check(not panel.visible, "初期状態は非表示", str(panel.visible))
	panel.toggle_visible()
	_check(panel.visible, "1回目のtoggleで表示される", str(panel.visible))
	panel.toggle_visible()
	_check(not panel.visible, "2回目のtoggleで非表示に戻る", str(panel.visible))


## 生産・消費の表示が MarketTable の実値と一致すること（アイアンホロウ×鉱石）。
func _test_production_consumption_text() -> void:
	print("--- 生産/消費の表示 ---")
	var session: GameSession = GameSession.new(6)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)

	var city_id: String = "ironhollow"
	var item_id: String = "ore"
	var expected: String = "生産%d/日・消費%d/日" % [
		MarketTable.production_of(city_id, item_id),
		MarketTable.consumption_of(city_id, item_id)]

	panel.show_by_city_view()
	panel.select_city(city_id)
	_check(panel.production_text_for(item_id) == expected,
		"都市→品目ビューでの表示がMarketTableと一致", panel.production_text_for(item_id))

	panel.show_by_item_view()
	panel.select_item(item_id)
	_check(panel.production_text_for(city_id) == expected,
		"品目→都市ビューでの表示がMarketTableと一致", panel.production_text_for(city_id))


## 買値・売値の表示が PriceTable の実値と一致すること。
func _test_price_text() -> void:
	print("--- 買値/売値の表示 ---")
	var session: GameSession = GameSession.new(7)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)

	var city_id: String = "ironhollow"
	var item_id: String = "ore"
	var expected: String = "買%s / 売%s" % [
		UiUtil.format_number(session.prices.buy_price(city_id, item_id)),
		UiUtil.format_number(session.prices.sell_price(city_id, item_id))]

	panel.show_by_city_view()
	panel.select_city(city_id)
	_check(panel.price_text_for(item_id) == expected,
		"都市→品目ビューでの買値/売値がPriceTableと一致", panel.price_text_for(item_id))

	panel.show_by_item_view()
	panel.select_item(item_id)
	_check(panel.price_text_for(city_id) == expected,
		"品目→都市ビューでの買値/売値がPriceTableと一致", panel.price_text_for(city_id))
