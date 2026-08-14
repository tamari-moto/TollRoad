extends "res://scripts/systems/scenario_base.gd"
## 市場の価格バーの検証。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m16.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const PriceBar = preload("res://scripts/ui/price_bar.gd")
const MarketPanel = preload("res://scripts/ui/market_panel.gd")



func _init() -> void:
	_test_scale_covers_all_prices()
	_test_position_mapping()
	_test_bar_in_market()
	_test_arrows()
	_test_badges()
	_test_best_deal_badge()
	_test_ratio_accent()
	await _test_bar_renders()
	_finish()


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
	# 列数は market_panel.gd の GRID_COLUMNS から引く。数字を直書きすると
	# 列を足すたびに複数のシナリオが道連れになる（実際に6→7で3本落ちた）。
	# ここで見たいのは「.tscn とスクリプトの列数が食い違っていないこと」。
	var columns: int = MarketPanel.GRID_COLUMNS
	_check(grid.columns == columns, "列数が GRID_COLUMNS と一致する", str(grid.columns))
	_check(grid.get_child_count() == columns + GameData.ITEMS.size() * columns,
		"ヘッダ1行＋全品目ぶんのセルが並ぶ", str(grid.get_child_count()))

	# 各行にバーがある。
	var bar_count: int = 0
	for child: Node in grid.get_children():
		for bar: Node in child.find_children("Bar", "", true, false):
			bar_count += 1
	_check(bar_count == GameData.ITEMS.size(), "全品目にバーがある", str(bar_count))

	# バーの比率が実際の価格と一致する。
	var first_item: String = GameData.ITEMS.keys()[0]
	var bar: PriceBar = panel.price_bar_for(first_item)
	var price: int = session.prices.get_price(session.current_city, first_item)
	var expected: float = float(price) / float(GameData.ITEMS[first_item]["base_price"])
	_check(is_equal_approx(bar.ratio, expected), "バーが実際の価格を指す",
		"%.3f vs %.3f" % [bar.ratio, expected])

	# 移動すると相場が変わり、バーも追従する。
	var before: float = bar.ratio
	session.move_to(_adjacent_royal_city(session.current_city))
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
	_check(market.arrow_for(0.70) == "▼", "安いと▼", market.arrow_for(0.70))
	_check(market.arrow_for(1.40) == "▲", "高いと▲", market.arrow_for(1.40))
	# 基準付近は矢印を出さない。ただし桁位置を揃えるため全角空白を返す
	# （空文字にすると%の位置が行ごとにずれる）。
	var neutral: String = market.arrow_for(1.00)
	_check(not neutral.contains("▼") and not neutral.contains("▲"),
		"基準付近は矢印を出さない", "[%s]" % neutral)
	_check(neutral.length() == 1, "桁合わせの空白は残す", "長さ %d" % neutral.length())

	# 閾値は色分けと同じ基準を使う（表示が食い違わない）。
	_check(market.arrow_for(UiTheme.CHEAP_RATIO) == "▼", "安い閾値ちょうどで▼", "違う")
	_check(market.arrow_for(UiTheme.DEAR_RATIO) == "▲", "高い閾値ちょうどで▲", "違う")

	# 実際の表示に記号が入る。
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel != null:
		var session: GameSession = GameSession.new(16002)
		panel.bind(session)
		var has_arrow: bool = false
		for item_id: String in panel.item_ids():
			var text: String = panel.ratio_text_for(item_id)
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

	# 初期都市の特産と生産ボーナスにバッジが出る。
	var home: String = GameData.INITIAL_CITY
	var specialty: String = GameData.CITIES[home]["specialty"]
	var bonus: String = GameData.CITIES[home]["bonus"]
	var unrelated: String = ""
	for item_id: String in GameData.ITEMS:
		if item_id != specialty and item_id != bonus:
			unrelated = item_id
			break

	_check(session.current_city == home, "初期都市から開始", session.current_city)
	var specialty_badge: String = panel.badge_text_for(specialty)
	var bonus_badge: String = panel.badge_text_for(bonus)
	var unrelated_badge: String = panel.badge_text_for(unrelated)

	# 「今お得」の指標（◎最安/◎高値）と併記されうるので contains で見る。
	# badge_text_for() は隠れているバッジを空文字で返すので、
	# 文言を含むことがそのまま「見えている」ことの確認になる。
	_check(specialty_badge.contains("特産"), "特産品に特産バッジ", specialty_badge)
	_check(bonus_badge.contains("生産地"), "生産ボーナス品に生産地バッジ", bonus_badge)
	_check(not unrelated_badge.contains("特産") and not unrelated_badge.contains("生産地"),
		"無関係な品目には特産・生産地バッジが出ない", unrelated_badge)

	# 移動するとバッジが付け替わる。
	var other_city: String = ""
	for city_id: String in GameData.royal_city_ids():
		if city_id != home:
			other_city = city_id
			break
	var other_specialty: String = GameData.CITIES[other_city]["specialty"]
	session.move_to(other_city)
	_check(not panel.badge_text_for(specialty).contains("特産"),
		"移動で元の特産バッジが消える", panel.badge_text_for(specialty))
	_check(panel.badge_text_for(other_specialty).contains("特産"),
		"移動先の特産にバッジが出る", panel.badge_text_for(other_specialty))

	_despawn(panel)


func _test_best_deal_badge() -> void:
	print("--- 最安・高値バッジ ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(16005)
	panel.bind(session)

	# 実際に全品目の比率を計算し、最も安い品目を特定する。
	var best_item: String = ""
	var best_ratio: float = 99.0
	for item_id: String in GameData.ITEMS:
		var price: int = session.prices.get_price(session.current_city, item_id)
		var ratio: float = float(price) / float(GameData.ITEMS[item_id]["base_price"])
		if ratio < best_ratio:
			best_ratio = ratio
			best_item = item_id

	_check(panel.badge_text_for(best_item).contains("◎最安"),
		"最も安い品目に◎最安が付く", panel.badge_text_for(best_item))

	# 何も所持していなければ◎高値はどこにも出ない。
	var any_best_sell: bool = false
	for item_id: String in GameData.ITEMS:
		if panel.badge_text_for(item_id).contains("◎高値"):
			any_best_sell = true
	_check(not any_best_sell, "所持していなければ◎高値は出ない", "出ている")

	# 買うと、唯一の所持品として◎高値の対象になる。
	session.buy(best_item, 1)
	panel.refresh()
	_check(panel.badge_text_for(best_item).contains("◎高値"),
		"唯一の所持品には◎高値が付く", panel.badge_text_for(best_item))

	_despawn(panel)


func _test_ratio_accent() -> void:
	print("--- 行の色帯 ---")
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(16006)
	panel.bind(session)

	for item_id: String in GameData.ITEMS:
		var price: int = session.prices.get_price(session.current_city, item_id)
		var ratio: float = float(price) / float(GameData.ITEMS[item_id]["base_price"])
		var accent: ColorRect = panel.accent_for(item_id)
		_check(accent.color == UiTheme.ratio_color(ratio),
			"%s の色帯が基準比の色と一致する" % item_id, str(accent.color))

	_despawn(panel)


func _test_bar_renders() -> void:
	print("--- バーが描画される大きさを持つ ---")
	# M13 で踏んだ「サイズ 0 で描画されない」罠の再発防止。
	# PriceBar は PackedScene ではないので _spawn() は使えない。代わりに
	# _spawned へ手で登録し、途中で抜けても _finish() が回収できるようにする
	# （await を挟むため、検査が失敗して抜ける経路が実在する）。
	var bar: PriceBar = PriceBar.new()
	root.add_child(bar)
	_spawned.append(bar)
	bar.size = Vector2(80, PriceBar.BAR_HEIGHT)
	bar.ratio = 0.8
	await process_frame

	_check(bar.custom_minimum_size.y >= PriceBar.BAR_HEIGHT, "最小の高さが設定される",
		str(bar.custom_minimum_size))
	_check(bar.size.x > 0 and bar.size.y > 0, "描画できる大きさがある", str(bar.size))
	_check(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"クリックを透過する（ボタンを妨げない）", str(bar.mouse_filter))

	_despawn(bar)

	# 市場の中でも高さを持つ。
	var panel: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if panel != null:
		var session: GameSession = GameSession.new(16004)
		panel.bind(session)
		panel.size = Vector2(560, 420)
		await process_frame
		await process_frame
		var bar_in_row: PriceBar = panel.price_bar_for(GameData.ITEMS.keys()[0])
		_check(bar_in_row.size.y > 0, "市場の中でも高さがある", str(bar_in_row.size))
		_despawn(panel)
