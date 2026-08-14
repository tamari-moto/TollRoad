extends "res://scripts/systems/scenario_base.gd"
## 街のステータス画面（デバッグパネルの第3ビュー、五角形レーダー）の検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m29.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const MarketTable = preload("res://scripts/systems/market_table.gd")
const DebugPanel = preload("res://scripts/ui/debug_panel.gd")
const CityRadarChart = preload("res://scripts/ui/city_radar_chart.gd")


func _init() -> void:
	_test_configure_outside_tree()
	_test_axes_are_five_base_resources()
	_test_status_view_all_cities()
	_test_ratio_matches_production()
	_test_view_switch_toggles_visibility()
	_finish()


## ツリーに入れなくても set_data() だけで完全に構築できること。
func _test_configure_outside_tree() -> void:
	print("--- ツリー外での構築 ---")
	var chart: CityRadarChart = CityRadarChart.new()
	chart.set_data("アイアンホロウ", "ironhollow", {"ore": 44})
	_check(chart.city_name() == "アイアンホロウ", "set_data()だけで都市名が反映される",
		chart.city_name())
	_check(chart.raw_value_for("ore") == 44, "set_data()だけで生産量が反映される",
		str(chart.raw_value_for("ore")))


## 頂点はスケッチ通り基礎5資源（鉱石/木材/繊維/皮/石材）の5つで、
## それ以外の資源（石炭・羊毛・水晶・粘土）や装備は含まない。
func _test_axes_are_five_base_resources() -> void:
	print("--- 頂点の顔ぶれ ---")
	var chart: CityRadarChart = CityRadarChart.new()
	var axes: Array = chart.axis_ids()
	_check(axes.size() == 5, "頂点は5個", str(axes.size()))
	for item_id: String in ["ore", "wood", "fiber", "hide", "stone"]:
		_check(axes.has(item_id), "%sが頂点に含まれる" % item_id, str(axes))
	for item_id: String in ["coal", "wool", "quartz", "clay", "sword"]:
		_check(not axes.has(item_id), "%sは頂点に含まれない" % item_id, str(axes))


## 全10都市で STATUS ビューへ切り替え、生産量が MarketTable と一致すること。
func _test_status_view_all_cities() -> void:
	print("--- 全都市での街のステータス ---")
	var session: GameSession = GameSession.new(1)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	panel.show_status_view()
	for city_id: String in GameData.CITIES:
		panel.select_city(city_id)
		var chart: CityRadarChart = panel.radar_chart()
		for item_id: String in CityRadarChart.AXES:
			var expected: int = MarketTable.production_of(city_id, item_id)
			_check(chart.raw_value_for(item_id) == expected,
				"%s @ %s の生産量がMarketTableと一致" % [item_id, city_id],
				"%d (期待 %d)" % [chart.raw_value_for(item_id), expected])


## 正規化比率（満点=GameData.PRODUCTION_SPECIALTY）は0〜1に収まり、
## 特産地（distance 0）でちょうど1.0になる。
func _test_ratio_matches_production() -> void:
	print("--- 正規化比率 ---")
	var session: GameSession = GameSession.new(2)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)
	panel.show_status_view()
	for city_id: String in GameData.CITIES:
		panel.select_city(city_id)
		var chart: CityRadarChart = panel.radar_chart()
		for item_id: String in CityRadarChart.AXES:
			var ratio: float = chart.ratio_for(item_id)
			_check(ratio >= 0.0 and ratio <= 1.0,
				"%s @ %s の比率は0〜1" % [item_id, city_id], str(ratio))
			if GameData.city_for_specialty(item_id) == city_id:
				_check(ratio == 1.0, "特産地(%s)の%sは満点" % [city_id, item_id], str(ratio))


## ビューを切り替えると、表・チャートの表示/非表示が排他的に切り替わる。
func _test_view_switch_toggles_visibility() -> void:
	print("--- 表示の排他切り替え ---")
	var session: GameSession = GameSession.new(3)
	var panel: DebugPanel = DebugPanel.new()
	panel.bind(session)

	panel.show_by_city_view()
	_check(not panel.radar_chart().visible, "都市→品目ビューではチャートが非表示",
		str(panel.radar_chart().visible))

	panel.show_status_view()
	_check(panel.radar_chart().visible, "街のステータスビューではチャートが表示",
		str(panel.radar_chart().visible))

	panel.show_by_item_view()
	_check(not panel.radar_chart().visible, "品目→都市ビューに戻るとチャートが非表示",
		str(panel.radar_chart().visible))
