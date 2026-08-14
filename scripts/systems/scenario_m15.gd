extends "res://scripts/systems/scenario_base.gd"
## 効果音の検証。
##
## 音そのものの良し悪しは検査できないが、波形が正しく生成されるか、
## 行動に対して意図した音が選ばれるかは確かめられる。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_m15.gd

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const Sfx = preload("res://scripts/ui/sfx.gd")



func _init() -> void:
	_test_streams_generated()
	_test_stream_quality()
	_test_cache()
	_test_playback()
	_test_log_mapping()
	_test_restored_log_fallback()
	_finish()


func _all_kinds() -> Array:
	return [Sfx.Kind.BUY, Sfx.Kind.SELL, Sfx.Kind.CRAFT, Sfx.Kind.UPGRADE,
		Sfx.Kind.DAY, Sfx.Kind.TRAVEL, Sfx.Kind.RAID, Sfx.Kind.EXPLORE]


func _test_streams_generated() -> void:
	print("--- 波形の生成 ---")
	for kind: int in _all_kinds():
		var stream: AudioStreamWAV = Sfx.stream_for(kind)
		_check(stream != null, "種別%d の音が作れる" % kind, "null")
		if stream == null:
			continue
		_check(stream.data.size() > 0, "種別%d に波形データがある" % kind, "空")
		_check(stream.mix_rate == Sfx.SAMPLE_RATE, "種別%d のサンプリングレート" % kind,
			str(stream.mix_rate))

	# 全種別に音量が定義されている。
	for kind: int in _all_kinds():
		_check(Sfx.VOLUMES.has(kind), "種別%d に音量が定義されている" % kind, "ない")


func _test_stream_quality() -> void:
	print("--- 波形の中身 ---")
	# 無音になっていない（振幅がある）。
	for kind: int in _all_kinds():
		var stream: AudioStreamWAV = Sfx.stream_for(kind)
		if stream == null:
			continue
		var peak: int = 0
		var samples: int = stream.data.size() / 2
		for i: int in mini(samples, 4000):
			peak = maxi(peak, absi(stream.data.decode_s16(i * 2)))
		_check(peak > 1000, "種別%d が無音でない" % kind, "振幅 %d" % peak)

	# 頻度の高い音ほど控えめ。毎日鳴る日送りが売買より小さいこと。
	_check(Sfx.VOLUMES[Sfx.Kind.DAY] < Sfx.VOLUMES[Sfx.Kind.BUY],
		"日送りは売買より静か",
		"%.0f vs %.0f" % [Sfx.VOLUMES[Sfx.Kind.DAY], Sfx.VOLUMES[Sfx.Kind.BUY]])
	# 襲撃は最も重い事象なので最も大きい。
	var loudest: float = -99.0
	for kind: int in _all_kinds():
		loudest = maxf(loudest, Sfx.VOLUMES[kind])
	_check(Sfx.VOLUMES[Sfx.Kind.RAID] == loudest, "襲撃が最も大きい",
		"%.0f / 最大 %.0f" % [Sfx.VOLUMES[Sfx.Kind.RAID], loudest])

	# 襲撃は長く、日送りは短い（重さが長さに出ている）。
	var raid: AudioStreamWAV = Sfx.stream_for(Sfx.Kind.RAID)
	var day: AudioStreamWAV = Sfx.stream_for(Sfx.Kind.DAY)
	if raid != null and day != null:
		_check(raid.data.size() > day.data.size() * 2,
			"襲撃は日送りより長い",
			"%d vs %d" % [raid.data.size(), day.data.size()])


func _test_cache() -> void:
	print("--- キャッシュ ---")
	var first: AudioStreamWAV = Sfx.stream_for(Sfx.Kind.BUY)
	var second: AudioStreamWAV = Sfx.stream_for(Sfx.Kind.BUY)
	_check(first == second, "同じ種別は作り直さない", "別インスタンス")

	# 種別ごとに別の音。
	var buy: AudioStreamWAV = Sfx.stream_for(Sfx.Kind.BUY)
	var sell: AudioStreamWAV = Sfx.stream_for(Sfx.Kind.SELL)
	_check(buy != sell, "購入と売却は別の音", "同じ")
	_check(buy.data != sell.data, "波形も異なる", "同一データ")


func _test_playback() -> void:
	print("--- 再生 ---")
	var sfx: Node = Sfx.new()
	root.add_child(sfx)

	_check(sfx.voice_count() == Sfx.VOICE_COUNT, "再生機が用意される",
		str(sfx.voice_count()))

	# 連打しても落ちない（再生機を使い回す）。
	for i: int in Sfx.VOICE_COUNT * 3:
		sfx.play(Sfx.Kind.BUY)
	_check(sfx.voice_count() == Sfx.VOICE_COUNT, "連打しても再生機は増えない",
		str(sfx.voice_count()))

	# 消音できる。
	sfx.set_muted(true)
	_check(sfx.is_muted(), "消音できる", "できない")
	sfx.play(Sfx.Kind.RAID)
	sfx.set_muted(false)
	_check(not sfx.is_muted(), "解除できる", "できない")

	# ツリー外でも落ちない。
	var orphan: Node = Sfx.new()
	orphan.play(Sfx.Kind.BUY)
	_check(true, "ツリー外で鳴らしても落ちない", "")
	orphan.free()

	root.remove_child(sfx)
	sfx.free()


## logged シグナルが受け取った種別を溜める。
var _seen_kinds: Array[int] = []


func _on_logged(_message: String, kind: int) -> void:
	_seen_kinds.append(kind)


## 行動 -> 日誌の種別。**本文の文言ではなく種別そのものを見る。**
##
## かつては main.gd の _play_for_log と同じ文字列判定をこの検査が別に持って
## おり、両方が同時にずれても気づけなかった。GameSession が種別を渡すように
## なったので、行動と種別の対応を直接確かめる。
func _kinds_from(session: GameSession, action: Callable) -> Array[int]:
	_seen_kinds = []
	session.logged.connect(_on_logged)
	action.call()
	session.logged.disconnect(_on_logged)
	return _seen_kinds


func _test_log_mapping() -> void:
	print("--- 航海日誌の行に種別が付く ---")

	var craft_session: GameSession = GameSession.new(15001)
	craft_session.buy("ore", 4)
	var craft_kinds: Array[int] = _kinds_from(craft_session, func() -> void:
		craft_session.craft("sword", craft_session.max_craftable("sword")))
	_check(craft_kinds.has(GameSession.LogKind.CRAFT), "製作が CRAFT で記録される",
		str(craft_kinds))

	var rest_session: GameSession = GameSession.new(15002)
	var rest_kinds: Array[int] = _kinds_from(rest_session, func() -> void:
		rest_session.rest())
	_check(rest_kinds.has(GameSession.LogKind.DAY), "休息が DAY で記録される",
		str(rest_kinds))

	var move_session: GameSession = GameSession.new(15003)
	var destination: String = _adjacent_royal_city(move_session.current_city)
	var move_kinds: Array[int] = _kinds_from(move_session, func() -> void:
		move_session.move_to(destination))
	_check(move_kinds.has(GameSession.LogKind.TRAVEL), "移動が TRAVEL で記録される",
		str(move_kinds))

	var island: GameSession = GameSession.new(15004)
	island.silver = 1000000
	var island_kinds: Array[int] = _kinds_from(island, func() -> void:
		island.upgrade_island())
	_check(island_kinds.has(GameSession.LogKind.UPGRADE), "島の拡張が UPGRADE で記録される",
		str(island_kinds))

	# 騎乗の購入も拡張と同じ音。品目の購入（TRADE）と混ざらないこと。
	var mount_session: GameSession = GameSession.new(15006)
	mount_session.silver = 100000000
	var target_mount: String = ""
	for mount_id: String in GameData.MOUNTS:
		if mount_id != mount_session.mount:
			target_mount = mount_id
			break
	var mount_kinds: Array[int] = _kinds_from(mount_session, func() -> void:
		mount_session.buy_mount(target_mount))
	_check(mount_kinds.has(GameSession.LogKind.UPGRADE), "騎乗の購入が UPGRADE で記録される",
		str(mount_kinds))

	# 襲撃。移動の行に続いて出るので、両方の種別が並ぶ。
	var raid_kinds: Array[int] = []
	for seed_value: int in range(1, 300):
		var s: GameSession = GameSession.new(seed_value)
		s.buy("ore", 5)
		if s.cargo_count("ore") == 0:
			continue
		var target: String = GameData.CAERLEON
		var kinds: Array[int] = _kinds_from(s, func() -> void: s.move_to(target))
		if s.cargo.is_empty():
			raid_kinds = kinds
			break
	_check(raid_kinds.has(GameSession.LogKind.RAID), "襲撃が RAID で記録される",
		str(raid_kinds))

	# 売買は TRADE。音はボタン側で鳴らすため、日誌からは鳴らさない。
	var trade: GameSession = GameSession.new(15005)
	var trade_kinds: Array[int] = _kinds_from(trade, func() -> void:
		trade.buy("ore", 1))
	_check(trade_kinds.has(GameSession.LogKind.TRADE), "品目の購入が TRADE で記録される",
		str(trade_kinds))
	_check(Sfx.sound_for_log_kind(GameSession.LogKind.TRADE) < 0,
		"TRADE では日誌から音を鳴らさない（ボタン側と二重にならない）",
		str(Sfx.sound_for_log_kind(GameSession.LogKind.TRADE)))

	# 同行者の加入・別れ。効果の説明文に「製作」「襲撃」が入る仲間がいるため、
	# 本文任せにすると仲間ごとに違う音が鳴る（かつて実際にそうなっていた）。
	# 全員が同じ種別で記録されることを確かめる。
	for companion_id: String in GameData.COMPANIONS:
		if companion_id == GameData.COMPANION_NONE:
			continue
		var joiner: GameSession = GameSession.new(15008)
		var join_kinds: Array[int] = _kinds_from(joiner, func() -> void:
			joiner.set_companion(companion_id))
		_check(join_kinds.has(GameSession.LogKind.COMPANION_JOINED),
			"%s の加入が COMPANION_JOINED で記録される" % companion_id, str(join_kinds))

	var leaver: GameSession = GameSession.new(15009)
	leaver.set_companion("fina")
	var leave_kinds: Array[int] = _kinds_from(leaver, func() -> void:
		leaver.set_companion(GameData.COMPANION_NONE))
	_check(leave_kinds.has(GameSession.LogKind.COMPANION_LEFT),
		"同行者との別れが COMPANION_LEFT で記録される", str(leave_kinds))

	# 種別 -> 音の対応。鳴らすべき種別に音が割り当たっていること。
	for pair: Array in [
		[GameSession.LogKind.CRAFT, Sfx.Kind.CRAFT],
		[GameSession.LogKind.UPGRADE, Sfx.Kind.UPGRADE],
		[GameSession.LogKind.TRAVEL, Sfx.Kind.TRAVEL],
		[GameSession.LogKind.RAID, Sfx.Kind.RAID],
		[GameSession.LogKind.EXPLORE, Sfx.Kind.EXPLORE],
		[GameSession.LogKind.DAY, Sfx.Kind.DAY],
		[GameSession.LogKind.COMPANION_JOINED, Sfx.Kind.UPGRADE],
		[GameSession.LogKind.COMPANION_LEFT, Sfx.Kind.DAY],
	]:
		_check(Sfx.sound_for_log_kind(pair[0]) == pair[1],
			"種別 %d に音 %d が対応する" % [pair[0], pair[1]],
			str(Sfx.sound_for_log_kind(pair[0])))


## セーブから復元した行は種別を持たないため、本文から引き直す経路が要る。
## こちらは日本語の文面に依存するので、実際のログ本文で確かめておく。
func _test_restored_log_fallback() -> void:
	print("--- 復元した行は本文から種別を引き直す ---")
	var s: GameSession = GameSession.new(15007)
	s.silver = 100000000
	s.buy("ore", 2)
	s.craft("sword", 1)
	s.rest()
	s.move_to(_adjacent_royal_city(s.current_city))
	s.upgrade_island()

	# 実際に出た本文を、保存・復元後と同じ「文字列だけ」の状態から引き直す。
	var found: Dictionary = {}
	for entry: String in s.log_entries:
		found[Sfx.kind_for_message(entry)] = entry

	for expected: int in [GameSession.LogKind.CRAFT, GameSession.LogKind.DAY,
			GameSession.LogKind.TRAVEL, GameSession.LogKind.UPGRADE]:
		_check(found.has(expected),
			"復元した本文から種別 %d を引き直せる" % expected,
			"引き直せない: %s" % str(found.keys()))

	# 品目の購入は「購入」を含むが「購入した」ではないため UPGRADE にならない。
	# （騎乗の購入とここで分かれる。文面を変えるとこの検査が落ちる）
	var buy_entry: String = ""
	for entry: String in s.log_entries:
		if entry.contains("個購入"):
			buy_entry = entry
	_check(buy_entry != "", "品目の購入がログに残る", "残らない")
	_check(Sfx.kind_for_message(buy_entry) != GameSession.LogKind.UPGRADE,
		"品目の購入が騎乗の購入と混ざらない", buy_entry)

	# 復元した仲間の行も全員が同じ種別に引き直せること。
	# 効果の説明文に「製作」「襲撃」を含む仲間がいるため、判定の順序を
	# 入れ替えるとここが落ちる（旧実装ではガドルフが製作音、ロッコが襲撃音に
	# なっていた）。desc を書き換えたときにも気づけるよう全員を回す。
	for companion_id: String in GameData.COMPANIONS:
		if companion_id == GameData.COMPANION_NONE:
			continue
		var joiner: GameSession = GameSession.new(15010)
		joiner.set_companion(companion_id)
		var join_entry: String = joiner.log_entries[-1]
		_check(Sfx.kind_for_message(join_entry) == GameSession.LogKind.COMPANION_JOINED,
			"復元した %s の加入行が COMPANION_JOINED になる" % companion_id, join_entry)

	var left: GameSession = GameSession.new(15011)
	left.set_companion("fina")
	left.set_companion(GameData.COMPANION_NONE)
	_check(Sfx.kind_for_message(left.log_entries[-1]) == GameSession.LogKind.COMPANION_LEFT,
		"復元した別れの行が COMPANION_LEFT になる", left.log_entries[-1])

	# 襲撃の行は色を変える対象。探索失敗も同様、探索成功は対象外。
	_check(Sfx.is_severe_log_kind(GameSession.LogKind.RAID, "襲撃された。積荷を全て失った。"),
		"襲撃の行は重い事象として扱う", "扱わない")
	_check(Sfx.is_severe_log_kind(GameSession.LogKind.EXPLORE, "ある都市 で探索失敗（罠）。"),
		"探索失敗の行は重い事象として扱う", "扱わない")
	_check(not Sfx.is_severe_log_kind(GameSession.LogKind.EXPLORE, "ある都市 で探索成功（宝）。"),
		"探索成功は重い事象にしない", "重い扱いになっている")
