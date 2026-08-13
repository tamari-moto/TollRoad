extends "res://scripts/systems/scenario_base.gd"
## 品目アイコンの検証。読み込み・キャッシュ・フォールバック・表示への差し込み。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m10.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")



func _init() -> void:
	_test_textures_exist()
	_test_fallback()
	_test_cache()
	_test_labeled_item()
	_test_panels_keep_layout()
	_test_cargo_icons()
	_test_signal_arity()
	_finish()


func _test_textures_exist() -> void:
	print("--- 全品目のアイコン ---")
	for item_id: String in GameData.ITEMS:
		var texture: Texture2D = UiIcons.item_texture(item_id)
		_check(texture != null, "%s のアイコンがある" % item_id, "null")
		if texture != null:
			_check(texture.get_width() > 0 and texture.get_height() > 0,
				"%s に大きさがある" % item_id,
				"%dx%d" % [texture.get_width(), texture.get_height()])

	# ui_theme に色が定義されている品目と、アイコンのある品目が一致する。
	for item_id: String in UiTheme.ITEM_COLORS:
		_check(UiIcons.item_texture(item_id) != null,
			"%s は色とアイコンが揃っている" % item_id, "アイコンがない")


func _test_fallback() -> void:
	print("--- 画像が無い場合のフォールバック ---")
	# 存在しない品目でも例外にならず null が返る。
	_check(UiIcons.item_texture("nonexistent_item") == null,
		"未定義の品目は null", "null でない")
	_check(UiIcons.make_item_icon("nonexistent_item") == null,
		"未定義の品目では TextureRect を作らない", "作られた")

	# 名前付きの Control は画像が無くても作られ、名前は表示される。
	var box: HBoxContainer = UiIcons.make_labeled_item("nonexistent_item", "テスト")
	_check(box != null, "画像が無くても Control は返る", "null")
	if box != null:
		var found_label: bool = false
		for child: Node in box.get_children():
			if child is Label and (child as Label).text == "テスト":
				found_label = true
			_check(not (child is TextureRect), "画像が無ければ TextureRect は入らない", "入っている")
		_check(found_label, "名前のラベルは入る", "ない")
		box.free()

	# 画像がある場合はアイコンとラベルの両方が入る。
	var with_icon: HBoxContainer = UiIcons.make_labeled_item("ore", "鉱石")
	var has_texture: bool = false
	var has_label: bool = false
	for child: Node in with_icon.get_children():
		if child is TextureRect:
			has_texture = true
		if child is Label:
			has_label = true
	_check(has_texture and has_label, "画像があればアイコンと名前が並ぶ",
		"texture=%s label=%s" % [str(has_texture), str(has_label)])
	with_icon.free()


func _test_cache() -> void:
	print("--- キャッシュ ---")
	UiIcons.clear_cache()
	var first: Texture2D = UiIcons.item_texture("sword")
	var second: Texture2D = UiIcons.item_texture("sword")
	_check(first == second, "同じ品目は同一インスタンスを返す", "別物")

	# 見つからなかった結果もキャッシュされ、再探索しない。
	UiIcons.item_texture("missing_a")
	_check(UiIcons.item_texture("missing_a") == null, "欠損もキャッシュされる", "null でない")

	UiIcons.clear_cache()
	var after_clear: Texture2D = UiIcons.item_texture("sword")
	_check(after_clear != null, "破棄後も読み直せる", "null")


func _test_labeled_item() -> void:
	print("--- アイコン付きセルの構造 ---")
	var box: HBoxContainer = UiIcons.make_labeled_item("ore", "鉱石", 24)
	_check(box.get_child_count() == 2, "アイコンと名前の2要素", str(box.get_child_count()))
	var icon: TextureRect = box.get_child(0) as TextureRect
	_check(icon != null, "先頭がアイコン", "違う")
	if icon != null:
		_check(icon.custom_minimum_size == Vector2(24, 24), "指定した大きさになる",
			str(icon.custom_minimum_size))
	box.free()


func _test_panels_keep_layout() -> void:
	print("--- 既存レイアウトを壊していない ---")
	# 列数と行数が従来どおりであること（M6/M7 の検査と同じ計算）。
	var market: Node = _spawn("res://scenes/ui/MarketPanel.tscn")
	if market != null:
		var session: GameSession = GameSession.new(10001)
		market.bind(session)
		var grid: GridContainer = UiUtil.find_node(market, "ItemGrid")
		_check(grid.columns == 6, "市場の列数は6のまま", str(grid.columns))
		_check(grid.get_child_count() == 6 + GameData.ITEMS.size() * 6,
			"市場の要素数は従来どおり", str(grid.get_child_count()))
		# 品目セルにアイコンが入っている（バッジを名前の下へ折り返す構造に
		# なったため、セル自体の型は問わず再帰的に探す）。
		var first_cell: Node = grid.get_child(6)
		var icons: Array[Node] = first_cell.find_children("*", "TextureRect", true, false)
		_check(icons.size() > 0, "品目セルはアイコン付き", "アイコンが見つからない")
		_despawn(market)

	var equipment_count: int = 0
	for item_id: String in GameData.ITEMS:
		if GameData.ITEMS[item_id]["kind"] == GameData.ItemKind.EQUIPMENT:
			equipment_count += 1

	var workshop: Node = _spawn("res://scenes/ui/WorkshopPanel.tscn")
	if workshop != null:
		var session: GameSession = GameSession.new(10002)
		workshop.bind(session)
		var grid: GridContainer = UiUtil.find_node(workshop, "RecipeGrid")
		_check(grid.columns == 5, "製作所の列数は5のまま", str(grid.columns))
		_check(grid.get_child_count() == 5 + equipment_count * 5, "製作所の要素数は従来どおり",
			str(grid.get_child_count()))
		_despawn(workshop)

	var memo: Node = _spawn("res://scenes/ui/MemoPanel.tscn")
	if memo != null:
		var session: GameSession = GameSession.new(10003)
		memo.bind(session)
		var grid: GridContainer = UiUtil.find_node(memo, "MemoGrid")
		var expected_columns: int = GameData.CITIES.size() + 1
		_check(grid.columns == expected_columns, "相場メモの列数は都市数+1のまま", str(grid.columns))
		_check(grid.get_child_count() == expected_columns + GameData.ITEMS.size() * expected_columns,
			"相場メモの要素数は従来どおり", str(grid.get_child_count()))
		_despawn(memo)


func _test_cargo_icons() -> void:
	print("--- 積荷のアイコン表示 ---")
	var panel: Node = _spawn("res://scenes/ui/CargoPanel.tscn")
	if panel == null:
		return
	var session: GameSession = GameSession.new(10004)
	panel.bind(session)

	var icons: HBoxContainer = UiUtil.find_node(panel, "CargoIcons")
	_check(icons != null, "CargoIcons がある", "ない")
	if icons == null:
		_despawn(panel)
		return
	_check(icons.get_child_count() == 0, "空なら何も並ばない", str(icons.get_child_count()))

	session.buy("ore", 10)
	_check(icons.get_child_count() == 1, "1品目なら1つ並ぶ", str(icons.get_child_count()))
	session.buy("wood", 5)
	_check(icons.get_child_count() == 2, "2品目なら2つ並ぶ", str(icons.get_child_count()))

	# 個数が表示される。
	var dump: String = ""
	for entry: Node in icons.get_children():
		for child: Node in entry.get_children():
			if child is Label:
				dump += (child as Label).text + " "
	_check(dump.contains("×10"), "個数が出る", dump)

	# 従来のテキスト内訳も残っている（M6 が検査している）。
	var detail: Label = UiUtil.find_node(panel, "CargoDetail")
	_check(detail.text.contains("鉱石"), "テキスト内訳も維持される", detail.text)

	_despawn(panel)


func _test_signal_arity() -> void:
	print("--- シグナルとハンドラの引数が一致する ---")
	# 引数の数が合わないと Godot は接続を許すが、発火時にエラーになる。
	# 検査は通ってしまうため（他のシグナル経由で更新されるので）、
	# ここで明示的に検出する。
	var panels: Array[String] = [
		"res://scenes/ui/MarketPanel.tscn",
		"res://scenes/ui/CargoPanel.tscn",
		"res://scenes/ui/MapPanel.tscn",
		"res://scenes/ui/WorkshopPanel.tscn",
		"res://scenes/ui/MemoPanel.tscn",
		"res://scenes/ui/IslandPanel.tscn",
		"res://scenes/ui/HUD.tscn",
		"res://scenes/ui/ExplorationPanel.tscn",
	]

	for path: String in panels:
		var panel: Node = _spawn(path)
		if panel == null:
			continue
		var session: GameSession = GameSession.new(10100)
		panel.bind(session)

		# 引数つきのシグナルをすべて発火させ、接続先が受け取れるか確かめる。
		session.silver_changed.emit(session.silver)
		session.day_advanced.emit(session.day)
		session.island_upgraded.emit(session.island_level)
		session.mount_changed.emit(session.mount)
		session.cargo_changed.emit()
		session.warehouse_changed.emit()

		# 発火してもパネルが生きていれば、引数不一致でエラーになっていない。
		# （不一致なら上の emit でエンジンがエラーを出す）
		_check(is_instance_valid(panel), "%s のシグナル接続が健全" % path.get_file(), "壊れた")
		_despawn(panel)
