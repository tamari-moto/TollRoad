extends "res://scripts/systems/scenario_base.gd"
## セーブ/ロードの検証。状態の往復・乱数系列の継続・相場の保存。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m18.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const SaveManager = preload("res://scripts/systems/save_manager.gd")

## 検査専用のパス。SaveManager.SAVE_PATH は絶対に使わないこと
## （シナリオを流すたびにプレイヤーのセーブが消える）。
const TEST_PATH: String = "user://scenario_m18_tmp.json"


func _init() -> void:
	_test_round_trip()
	_test_value_types()
	_test_rng_continuity()
	_test_prices_preserved()
	_test_missing_keys()
	_test_unknown_ids()
	_test_file_io()
	_test_version_mismatch()
	_test_corrupt_file()
	_finish()


## 全フィールドが埋まった状態を作る。往復の検査に使う。
## rest だけでは cargo も warehouse も memo も埋まらないので、実際に遊ぶ。
func _play_a_while(rng_seed: int) -> GameSession:
	var s: GameSession = GameSession.new(rng_seed)
	s.buy("ore", 6)
	s.craft("sword", 1)
	s.move_to("bridgewatch")
	s.buy("stone", 4)
	s.upgrade_island()
	for i: int in 5:
		s.rest()
	s.move_to("martlock")
	s.sell("stone", 2)
	return s


func _restore_from(data: Dictionary) -> GameSession:
	var restored: GameSession = GameSession.new(0)
	restored.from_dict(data)
	return restored


func _test_round_trip() -> void:
	print("--- 状態の往復 ---")
	var original: GameSession = _play_a_while(18001)
	var restored: GameSession = _restore_from(original.to_dict())

	_check(restored.day == original.day, "日付が戻る",
		"%d / %d" % [restored.day, original.day])
	_check(restored.silver == original.silver, "シルバーが戻る",
		"%d / %d" % [restored.silver, original.silver])
	_check(restored.current_city == original.current_city, "現在地が戻る",
		restored.current_city)
	_check(restored.mount == original.mount, "騎乗が戻る", restored.mount)
	_check(restored.island_level == original.island_level, "島レベルが戻る",
		str(restored.island_level))

	# 積荷と倉庫はキー集合と各値まで見る。
	_check(restored.cargo.size() == original.cargo.size(), "積荷の品目数が戻る",
		"%d / %d" % [restored.cargo.size(), original.cargo.size()])
	var cargo_ok: bool = true
	for item_id: String in original.cargo:
		if restored.cargo_count(item_id) != original.cargo_count(item_id):
			cargo_ok = false
	_check(cargo_ok, "積荷の個数が全品目で一致する", "違う品目がある")
	_check(original.cargo.size() > 0, "そもそも積荷がある状態で試している",
		str(original.cargo.size()))

	var warehouse_ok: bool = true
	for item_id: String in original.warehouse:
		if restored.warehouse_count(item_id) != original.warehouse_count(item_id):
			warehouse_ok = false
	_check(warehouse_ok, "島倉庫が全品目で一致する", "違う品目がある")
	_check(original.warehouse_total() > 0, "そもそも倉庫に中身がある状態で試している",
		str(original.warehouse_total()))

	# 相場メモは都市ごとの記録日と価格まで。
	var memo_ok: bool = true
	for city_id: String in original.memo:
		if restored.memo_age(city_id) != original.memo_age(city_id):
			memo_ok = false
		for item_id: String in GameData.ITEMS:
			if restored.memo_price(city_id, item_id) != original.memo_price(city_id, item_id):
				memo_ok = false
	_check(memo_ok, "相場メモが記録日と価格まで一致する", "違う記録がある")
	_check(original.memo.size() >= 2, "複数都市の記録がある状態で試している",
		str(original.memo.size()))

	# 航海日誌。
	_check(restored.log_entries.size() == original.log_entries.size(),
		"日誌の件数が戻る",
		"%d / %d" % [restored.log_entries.size(), original.log_entries.size()])
	var log_ok: bool = true
	for i: int in original.log_entries.size():
		if i < restored.log_entries.size() and restored.log_entries[i] != original.log_entries[i]:
			log_ok = false
	_check(log_ok, "日誌の各行が一致する", "違う行がある")
	# 復元処理そのものが日誌へ書き足していないこと。
	_check(restored.log_entries.size() == original.log_entries.size(),
		"復元で日誌が増えない", str(restored.log_entries.size()))

	# 相場は全都市×全品目を個別に見る。== 一発だと落ちた時に場所が分からない。
	var price_mismatch: String = ""
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			var a: int = original.prices.get_price(city_id, item_id)
			var b: int = restored.prices.get_price(city_id, item_id)
			if a != b and price_mismatch == "":
				price_mismatch = "%s の %s が %d / %d" % [city_id, item_id, b, a]
	_check(price_mismatch == "", "全都市×全品目の価格が一致する（54項目）",
		price_mismatch)

	# 派生値も一致する。
	_check(restored.net_worth() == original.net_worth(), "純資産が一致する",
		"%d / %d" % [restored.net_worth(), original.net_worth()])
	_check(restored.rank() == original.rank(), "ランクが一致する", restored.rank())
	_check(restored.capacity() == original.capacity(), "積載量が一致する",
		str(restored.capacity()))
	_check(restored.free_capacity() == original.free_capacity(), "空き容量が一致する",
		str(restored.free_capacity()))


## JSON を通すと数値が float になる。int で戻ることを歯止めとして見る。
func _test_value_types() -> void:
	print("--- 型（JSON の float 化に対する歯止め） ---")
	var original: GameSession = _play_a_while(18002)
	# 実際に JSON を通してから戻す。ここが本番と同じ経路。
	var text: String = JSON.stringify(original.to_dict())
	var parsed: Variant = JSON.parse_string(text)
	_check(parsed is Dictionary, "JSON として往復できる", str(typeof(parsed)))
	if not (parsed is Dictionary):
		return
	var restored: GameSession = _restore_from(parsed as Dictionary)

	_check(typeof(restored.day) == TYPE_INT, "day が int で戻る",
		type_string(typeof(restored.day)))
	_check(typeof(restored.silver) == TYPE_INT, "silver が int で戻る",
		type_string(typeof(restored.silver)))
	_check(typeof(restored.island_level) == TYPE_INT, "island_level が int で戻る",
		type_string(typeof(restored.island_level)))

	var cargo_item: String = restored.cargo.keys()[0] if restored.cargo.size() > 0 else ""
	if cargo_item != "":
		_check(typeof(restored.cargo[cargo_item]) == TYPE_INT, "積荷の個数が int で戻る",
			type_string(typeof(restored.cargo[cargo_item])))
	_check(typeof(restored.prices.get_price("martlock", "ore")) == TYPE_INT,
		"価格が int で戻る",
		type_string(typeof(restored.prices.prices["martlock"]["ore"])))

	# JSON を通しても値そのものが変わらないこと。
	_check(restored.silver == original.silver, "JSON 経由でもシルバーが一致",
		"%d / %d" % [restored.silver, original.silver])
	_check(restored.net_worth() == original.net_worth(), "JSON 経由でも純資産が一致",
		"%d / %d" % [restored.net_worth(), original.net_worth()])


## 保存した続きから進めると、元と同じ乱数系列をたどる。
func _test_rng_continuity() -> void:
	print("--- 乱数系列の継続 ---")
	# 労働者も乱数を消費するので、島を上げた状態で試す。
	var original: GameSession = _play_a_while(18003)
	_check(original.worker_count() > 0, "労働者がいる状態で試している",
		str(original.worker_count()))

	var data: Dictionary = original.to_dict()

	# 元をさらに10日進め、日ごとの相場と倉庫を記録する。
	var series: Array[String] = []
	for i: int in 10:
		original.rest()
		series.append("%d|%d|%d" % [
			original.prices.get_price("caerleon", "sword"),
			original.prices.get_price("martlock", "ore"),
			original.warehouse_total()])

	# 復元した側も同じだけ進める。
	var restored: GameSession = _restore_from(data)
	var restored_series: Array[String] = []
	for i: int in 10:
		restored.rest()
		restored_series.append("%d|%d|%d" % [
			restored.prices.get_price("caerleon", "sword"),
			restored.prices.get_price("martlock", "ore"),
			restored.warehouse_total()])

	var first_gap: String = ""
	for i: int in series.size():
		if series[i] != restored_series[i] and first_gap == "":
			first_gap = "%d日目: %s / %s" % [i + 1, restored_series[i], series[i]]
	_check(first_gap == "", "10日ぶんの相場と倉庫が日ごとに一致する", first_gap)

	# state を保存しないと系列がずれること（この検査が意味を持つことの裏取り）。
	var broken: Dictionary = data.duplicate(true)
	broken["rng"]["state"] = broken["rng"]["seed"]
	var broken_session: GameSession = _restore_from(broken)
	var broken_series: Array[String] = []
	for i: int in 10:
		broken_session.rest()
		broken_series.append("%d|%d|%d" % [
			broken_session.prices.get_price("caerleon", "sword"),
			broken_session.prices.get_price("martlock", "ore"),
			broken_session.warehouse_total()])
	_check(broken_series != series,
		"state を捨てると系列がずれる（state の保存が必要な根拠）",
		"ずれなかった")

	# 64bit の state が **JSON を通しても** そのまま往復する。
	#
	# 辞書のまま比べても意味がない（メモリ上では数値でも欠けない）。
	# 精度が落ちるのは JSON の double を経由するときなので、必ず
	# stringify/parse を挟んで確かめる。実測で、数値のまま保存すると
	# 4857946085375722947 -> 4857946085375722496 に化ける。
	var state_text: String = str(data["rng"]["state"])
	var via_json: Variant = JSON.parse_string(JSON.stringify(data))
	var json_state: String = str((via_json as Dictionary)["rng"]["state"])
	_check(json_state == state_text,
		"RNG の state が JSON を通しても 64bit のまま往復する",
		"%s / %s" % [json_state, state_text])

	# JSON を通した後でも、続きの系列が元と一致する。
	var json_session: GameSession = _restore_from(via_json as Dictionary)
	var json_series: Array[String] = []
	for i: int in 10:
		json_session.rest()
		json_series.append("%d|%d|%d" % [
			json_session.prices.get_price("caerleon", "sword"),
			json_session.prices.get_price("martlock", "ore"),
			json_session.warehouse_total()])
	_check(json_series == series, "JSON を通しても10日ぶんの系列が一致する",
		"ずれた")


## 当日の相場は保存が要る。reroll() では再現できない。
func _test_prices_preserved() -> void:
	print("--- 当日の相場 ---")
	var original: GameSession = _play_a_while(18004)
	var today: Dictionary = {}
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			today["%s/%s" % [city_id, item_id]] = original.prices.get_price(city_id, item_id)

	var restored: GameSession = _restore_from(original.to_dict())

	# 復元直後は当日の相場のまま（勝手に引き直されていない）。
	var changed: int = 0
	for key: String in today:
		var parts: PackedStringArray = key.split("/")
		if restored.prices.get_price(parts[0], parts[1]) != today[key]:
			changed += 1
	_check(changed == 0, "復元直後は当日の相場のまま", "%d 項目が違う" % changed)

	# 1日進めれば相場は動く（凍りついていない）。
	restored.rest()
	var moved: int = 0
	for key: String in today:
		var parts: PackedStringArray = key.split("/")
		if restored.prices.get_price(parts[0], parts[1]) != today[key]:
			moved += 1
	_check(moved > 0, "復元後も1日進めば相場が動く", "1項目も動かない")


## 欠けたキーは既定値のまま残る。
func _test_missing_keys() -> void:
	print("--- 欠損キー ---")
	var full: Dictionary = _play_a_while(18005).to_dict()

	var without_silver: Dictionary = full.duplicate(true)
	without_silver.erase("silver")
	_check(_restore_from(without_silver).silver == GameData.INITIAL_SILVER,
		"silver が無ければ初期値", str(_restore_from(without_silver).silver))

	var without_mount: Dictionary = full.duplicate(true)
	without_mount.erase("mount")
	_check(_restore_from(without_mount).mount == GameData.INITIAL_MOUNT,
		"mount が無ければ初期値", _restore_from(without_mount).mount)

	var without_cargo: Dictionary = full.duplicate(true)
	without_cargo.erase("cargo")
	_check(_restore_from(without_cargo).cargo.is_empty(), "cargo が無ければ空", "空でない")

	var without_log: Dictionary = full.duplicate(true)
	without_log.erase("log_entries")
	_check(_restore_from(without_log).log_entries.is_empty(), "日誌が無ければ空", "空でない")

	# 相場が欠けても get_price() が落ちない形に埋まっていること。
	var without_prices: Dictionary = full.duplicate(true)
	without_prices.erase("prices")
	var no_prices: GameSession = _restore_from(without_prices)
	var filled: bool = true
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if no_prices.prices.get_price(city_id, item_id) <= 0:
				filled = false
	_check(filled, "prices が無ければ引き直して全項目が埋まる", "欠けている")


## 知らない品目・都市が混ざっていても壊れない。
func _test_unknown_ids() -> void:
	print("--- 未知のID ---")
	var full: Dictionary = _play_a_while(18006).to_dict()

	var with_unknown: Dictionary = full.duplicate(true)
	with_unknown["cargo"]["unobtainium"] = 5
	with_unknown["future_field"] = 42
	var restored: GameSession = _restore_from(with_unknown)
	_check(not restored.cargo.has("unobtainium"), "未知の品目は積荷に入らない", "入った")
	_check(restored.cargo_count("ore") == int(full["cargo"].get("ore", 0)),
		"既知の品目はそのまま残る", str(restored.cargo_count("ore")))

	var with_unknown_city: Dictionary = full.duplicate(true)
	with_unknown_city["memo"]["atlantis"] = {"day": 1, "prices": {}}
	_check(not _restore_from(with_unknown_city).has_memo("atlantis"),
		"未知の都市はメモに入らない", "入った")

	# 都市が1つ欠けた相場は部分補完せず引き直す。
	var partial: Dictionary = full.duplicate(true)
	partial["prices"].erase("caerleon")
	var rerolled: GameSession = _restore_from(partial)
	var all_filled: bool = true
	for city_id: String in GameData.CITIES:
		for item_id: String in GameData.ITEMS:
			if rerolled.prices.get_price(city_id, item_id) <= 0:
				all_filled = false
	_check(all_filled, "相場が欠けていれば全体を引き直す", "欠けたまま")


## 実ファイルを通した往復。専用パスを使い、最後に必ず消す。
func _test_file_io() -> void:
	print("--- ファイルの往復 ---")
	# 前回の残骸があれば片付けてから始める。
	SaveManager.delete_save(TEST_PATH)
	_check(not SaveManager.has_save(TEST_PATH), "はじめはセーブが無い", "残っている")

	var original: GameSession = _play_a_while(18007)
	_check(SaveManager.save_game(original, TEST_PATH), "保存できる", "失敗した")
	_check(SaveManager.has_save(TEST_PATH), "保存するとセーブが出来る", "無い")

	var loaded: GameSession = SaveManager.load_game(TEST_PATH)
	_check(loaded != null, "読み込める", SaveManager.last_error())
	if loaded != null:
		_check(SaveManager.last_error() == "", "成功時の理由は空",
			SaveManager.last_error())
		_check(loaded.day == original.day, "日付が戻る",
			"%d / %d" % [loaded.day, original.day])
		_check(loaded.silver == original.silver, "シルバーが戻る",
			"%d / %d" % [loaded.silver, original.silver])
		_check(loaded.current_city == original.current_city, "現在地が戻る",
			loaded.current_city)
		_check(loaded.net_worth() == original.net_worth(), "純資産が戻る",
			"%d / %d" % [loaded.net_worth(), original.net_worth()])

		# ファイル経由でも乱数系列が続く。ここが本番と同じ経路。
		var a: Array[String] = []
		var b: Array[String] = []
		for i: int in 8:
			original.rest()
			a.append(str(original.prices.get_price("caerleon", "sword")))
			loaded.rest()
			b.append(str(loaded.prices.get_price("caerleon", "sword")))
		_check(a == b, "ファイル経由でも乱数系列が続く", "ずれた")

	_check(SaveManager.delete_save(TEST_PATH), "消せる", "失敗した")
	_check(not SaveManager.has_save(TEST_PATH), "消すと無くなる", "残っている")


## 版が合わないセーブは読まない。
func _test_version_mismatch() -> void:
	print("--- 版の不一致 ---")
	var data: Dictionary = _play_a_while(18008).to_dict()

	# 新しすぎる版は推測で読まない。
	data["version"] = SaveManager.SAVE_VERSION + 1
	_write_json(data)
	_check(SaveManager.load_game(TEST_PATH) == null, "新しすぎる版は読まない", "読めた")
	_check(SaveManager.last_error() != "", "理由が残る", "空のまま")

	# 古すぎる版も読まない。
	data["version"] = SaveManager.MIN_SUPPORTED_VERSION - 1
	_write_json(data)
	_check(SaveManager.load_game(TEST_PATH) == null, "古すぎる版は読まない", "読めた")
	_check(SaveManager.last_error() != "", "理由が残る", "空のまま")

	# version キーが無いものは版0扱いで拒否。
	data.erase("version")
	_write_json(data)
	_check(SaveManager.load_game(TEST_PATH) == null, "版が無ければ読まない", "読めた")

	# 現在の版なら読める。
	data["version"] = SaveManager.SAVE_VERSION
	_write_json(data)
	_check(SaveManager.load_game(TEST_PATH) != null, "現在の版なら読める",
		SaveManager.last_error())

	# 知らない都市は黙って直さず断る（積荷と移動費の前提が崩れるため）。
	data["current_city"] = "atlantis"
	_write_json(data)
	_check(SaveManager.load_game(TEST_PATH) == null, "知らない都市なら読まない", "読めた")

	# 島レベルと騎乗は範囲の問題なので丸めて読む。
	data["current_city"] = "martlock"
	data["island_level"] = 99
	data["mount"] = "dragon"
	_write_json(data)
	var clamped: GameSession = SaveManager.load_game(TEST_PATH)
	_check(clamped != null, "範囲外の値でも読める", SaveManager.last_error())
	if clamped != null:
		_check(clamped.island_level == GameData.ISLAND_LEVELS.size() - 1,
			"島レベルは最大に丸められる", str(clamped.island_level))
		_check(clamped.mount == GameData.INITIAL_MOUNT, "未知の騎乗は初期値に戻る",
			clamped.mount)
		_check(clamped.worker_count() > 0, "丸めた後も労働者数が引ける", "落ちる")

	SaveManager.delete_save(TEST_PATH)


## 壊れた入力でも落ちない。ユーザ領域のファイルは編集されうる。
func _test_corrupt_file() -> void:
	print("--- 壊れた入力 ---")
	SaveManager.delete_save(TEST_PATH)
	_check(SaveManager.load_game(TEST_PATH) == null, "存在しないパスは null", "読めた")
	_check(SaveManager.last_error() != "", "理由が残る", "空のまま")

	for broken: String in ["{", "", "[1,2,3]", "not json at all"]:
		_write_text(broken)
		var label: String = broken if broken != "" else "（空）"
		_check(SaveManager.load_game(TEST_PATH) == null,
			"壊れた内容は null: %s" % label, "読めた")
		_check(SaveManager.last_error() != "", "理由が残る: %s" % label, "空のまま")

	SaveManager.delete_save(TEST_PATH)
	_check(not SaveManager.has_save(TEST_PATH), "検査の後始末ができている", "残っている")


func _write_json(data: Dictionary) -> void:
	_write_text(JSON.stringify(data, "\t"))


func _write_text(text: String) -> void:
	var file: FileAccess = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	if file == null:
		_check(false, "検査用のファイルを書ける", "書けない")
		return
	file.store_string(text)
	file.close()
