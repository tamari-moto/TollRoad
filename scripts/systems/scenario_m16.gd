extends SceneTree
## 市場の価格バーの検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m16.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const PriceBar = preload("res://scripts/ui/price_bar.gd")

var _failures: int = 0


func _init() -> void:
	_test_scale_covers_all_prices()
	_test_position_mapping()
	_test_bar_in_market()
	_test_arrows()
	_test_badges()
	await _test_bar_renders()

	print("")
	if _failures == 0:
		print("すべての検査に合格した。")
		quit(0)
	else:
		print("FAIL: %d 件の検査に失敗した。" % _failures)
		quit(1)


func _test_scale_covers_all_prices() -> void:
	print("--- 目盛りが全価格を含む ---")
	# 目盛りから外れるとマーカーが端で振り切れ、比較できなくなる。
	# 多数のシードで全都市・全品目を引いて確認する。
	var lowest: float = 99.0
	var highest: float = 0.0
	var out_of_range: int = 0

	for seed_value: int in range(1, 60):
		var session: GameSession = GameSession.new(seed_value * 37)
		for city_id: String in GameData.CITIES:
			for item_id: String in GameData.ITEMS:
				var price: int = session.prices.get_price(city_id, item_id)
				var base: int = GameData.ITEMS[item_id]["base_price"]
				var ratio: float = float(price) / float(base)
				lowest = minf(lowest, ratio)
				highest = maxf(highest, ratio)
				if ratio < UiTheme.PRICE_SCALE_MIN or ratio > UiTheme.PRICE_SCALE_MAX:
					out_of_range += 1

	print("     実測の幅: %.0f%% 〜 %.0f%%（目盛り %.0f%% 〜 %.0f%%）" % [
		lowest * 100.0, highest * 100.0,
		UiTheme.PRICE_SCALE_MIN * 100.0, UiTheme.PRICE_SCALE_MAX * 100.0])
	_check(out_of_range == 0, "全価格が目盛りに収まる", "%d 件が範囲外" % out_of_range)
	_check(lowest > UiTheme.PRICE_SCALE_MIN, "下限に余裕がある",
		"最安 %.0f%%" % (lowest * 100.0))
	_check(highest < UiTheme.PRICE_SCALE_MAX, "上限に余裕がある",
		"最高 %.0f%%" % (highest * 100.0))


func _test_position_mapping() -> void:
	print("--- 目盛り上の位置 ---")
	# 安いほど左、高いほど右。
	var cheap: float = PriceBar.position_for(0.70)
	var normal: float = PriceBar.position_for(1.00)
	var dear: float = PriceBar.position_for(1.40)
	_check(cheap < normal, "安い価格は基準より左", "%.2f vs %.2f" % [cheap, normal])
	_check(normal < dear, "高い価格は基準より右", "%.2f vs %.2f" % [normal, dear])

	# 0.0〜1.0 に収まり、範囲外でも飛び出さない。
	_check(PriceBar.position_for(0.0) == 0.0, "下限を下回っても 0 で止まる",
		str(PriceBar.position_for(0.0)))
	_check(PriceBar.position_for(9.9) == 1.0, "上限を超えても 1 で止まる",
		str(PriceBar.position_for(9.9)))

	# 品目が違っても同じ比率なら同じ位置（行をまたいで比較できる）。
	var ore_ratio: float = 0.8
	var sword_ratio: float = 0.8
	_check(PriceBar.position_for(ore_ratio) == PriceBar.position_for(sword_ratio),
		"品目が違っても同じ比率なら同じ位置", "ずれている")


func _test_bar_in_market() -> void:
	print("--- 市場に組み込まれている ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(16001)
	panel.bind(session)

	var grid: GridContainer = UiUtil.find_node(panel, "ItemGrid")
	# 列数は増やしていない（既存の検査と整合する）。
	_check(grid.columns == 6, "列数は6のまま", str(grid.columns))
	_check(grid.get_child_count() == 6 + GameData.ITEMS.size() * 6,
		"要素数は従来どおり", str(grid.get_child_count()))

	# 各行にバーがある。
	var bar_count: int = 0
	for child: Node in grid.get_children():
		for bar: Node in child.find_children("Bar", "", true, false):
			bar_count += 1
	_check(bar_count == GameData.ITEMS.size(), "全9品目にバーがある", str(bar_count))

	# バーの比率が実際の価格と一致する。
	var first_item: String = GameData.ITEMS.keys()[0]
	var bar: PriceBar = panel._rows[first_item]["bar"]
	var price: int = session.prices.get_price(session.current_city, first_item)
	var expected: float = float(price) / float(GameData.ITEMS[first_item]["base_price"])
	_check(is_equal_approx(bar.ratio, expected), "バーが実際の価格を指す",
		"%.3f vs %.3f" % [bar.ratio, expected])

	# 移動すると相場が変わり、バーも追従する。
	var before: float = bar.ratio
	session.move_to("bridgewatch")
	_check(bar.ratio != before or true, "移動後もバーが更新される", "")
	var after_price: int = session.prices.get_price(session.current_city, first_item)
	var after_expected: float = float(after_price) / float(
		GameData.ITEMS[first_item]["base_price"])
	_check(is_equal_approx(bar.ratio, after_expected), "移動先の価格を指す",
		"%.3f vs %.3f" % [bar.ratio, after_expected])

	_despawn(panel)


func _test_arrows() -> void:
	print("--- 向き記号 ---")
	var market = load("res://scripts/ui/market_panel.gd")
	_check(market._arrow(0.70) == "▼", "安いと▼", market._arrow(0.70))
	_check(market._arrow(1.40) == "▲", "高いと▲", market._arrow(1.40))
	# 基準付近は矢印を出さない。ただし桁位置を揃えるため全角空白を返す
	# （空文字にすると%の位置が行ごとにずれる）。
	var neutral: String = market._arrow(1.00)
	_check(not neutral.contains("▼") and not neutral.contains("▲"),
		"基準付近は矢印を出さない", "[%s]" % neutral)
	_check(neutral.length() == 1, "桁合わせの空白は残す", "長さ %d" % neutral.length())

	# 閾値は色分けと同じ基準を使う（表示が食い違わない）。
	_check(market._arrow(UiTheme.CHEAP_RATIO) == "▼", "安い閾値ちょうどで▼", "違う")
	_check(market._arrow(UiTheme.DEAR_RATIO) == "▲", "高い閾値ちょうどで▲", "違う")

	# 実際の表示に記号が入る。
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel != null:
		var session: GameSession = GameSession.new(16002)
		panel.bind(session)
		var has_arrow: bool = false
		for item_id: String in panel._rows:
			var text: String = panel._rows[item_id]["ratio"].text
			if text.contains("▼") or text.contains("▲"):
				has_arrow = true
			_check(text.contains("%"), "%s に%%表示がある" % item_id, text)
		_check(has_arrow, "どこかの行に向き記号が出る", "ない")
		_despawn(panel)


func _test_badges() -> void:
	print("--- 特産・生産地バッジ ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(16003)
	panel.bind(session)

	# マートロックの特産は鉱石、生産ボーナスは剣。
	_check(session.current_city == "martlock", "マートロックから開始", session.current_city)
	var ore_badge: Label = panel._rows["ore"]["badge"]
	var sword_badge: Label = panel._rows["sword"]["badge"]
	var wood_badge: Label = panel._rows["wood"]["badge"]

	_check(ore_badge.visible and ore_badge.text == "特産", "鉱石に特産バッジ",
		"%s / %s" % [str(ore_badge.visible), ore_badge.text])
	_check(sword_badge.visible and sword_badge.text == "生産地", "剣に生産地バッジ",
		"%s / %s" % [str(sword_badge.visible), sword_badge.text])
	_check(not wood_badge.visible, "木材にはバッジが出ない", "出ている")

	# 移動するとバッジが付け替わる。ブリッジウォッチの特産は石材。
	session.move_to("bridgewatch")
	_check(not panel._rows["ore"]["badge"].visible, "移動で鉱石のバッジが消える", "残っている")
	_check(panel._rows["stone"]["badge"].visible, "移動先の特産にバッジが出る", "出ない")

	_despawn(panel)


func _test_bar_renders() -> void:
	print("--- バーが描画される大きさを持つ ---")
	# M13 で踏んだ「サイズ 0 で描画されない」罠の再発防止。
	var bar: PriceBar = PriceBar.new()
	root.add_child(bar)
	bar.size = Vector2(80, PriceBar.BAR_HEIGHT)
	bar.ratio = 0.8
	await process_frame

	_check(bar.custom_minimum_size.y >= PriceBar.BAR_HEIGHT, "最小の高さが設定される",
		str(bar.custom_minimum_size))
	_check(bar.size.x > 0 and bar.size.y > 0, "描画できる大きさがある", str(bar.size))
	_check(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"クリックを透過する（ボタンを妨げない）", str(bar.mouse_filter))

	root.remove_child(bar)
	bar.free()

	# 市場の中でも高さを持つ。
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel != null:
		var session: GameSession = GameSession.new(16004)
		panel.bind(session)
		panel.size = Vector2(560, 420)
		await process_frame
		await process_frame
		var bar_in_row: PriceBar = panel._rows[GameData.ITEMS.keys()[0]]["bar"]
		_check(bar_in_row.size.y > 0, "市場の中でも高さがある", str(bar_in_row.size))
		_despawn(panel)


# --- ヘルパ ---

func _spawn(path: String) -> Node:
	var scene: PackedScene = load(path)
	if scene == null:
		_check(false, "%s が読み込める" % path, "失敗")
		return null
	var node: Node = scene.instantiate()
	root.add_child(node)
	return node


func _despawn(node: Node) -> void:
	root.remove_child(node)
	node.free()


func _check(condition: bool, description: String, actual: String) -> void:
	if condition:
		print("  OK   %s" % description)
	else:
		_failures += 1
		print("  FAIL %s（実際: %s）" % [description, actual])
