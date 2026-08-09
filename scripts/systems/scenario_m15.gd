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
	_finish()


func _all_kinds() -> Array:
	return [Sfx.Kind.BUY, Sfx.Kind.SELL, Sfx.Kind.CRAFT, Sfx.Kind.UPGRADE,
		Sfx.Kind.DAY, Sfx.Kind.TRAVEL, Sfx.Kind.RAID]


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


func _test_log_mapping() -> void:
	print("--- 航海日誌から音を選ぶ ---")
	# 実際のログ文面が意図した音に対応するか。
	# main.gd の _play_for_log と同じ判定をここで確かめる。
	var session: GameSession = GameSession.new(15001)

	# 各行動を実行し、ログに想定の語が含まれることを確認する。
	session.buy("ore", 4)
	session.craft("sword", session.max_craftable("sword"))
	var craft_logged: bool = false
	for entry: String in session.log_entries:
		if entry.contains("製作"):
			craft_logged = true
	_check(craft_logged, "製作がログに残る", "残らない")

	var rest_session: GameSession = GameSession.new(15002)
	rest_session.rest()
	var rest_logged: bool = false
	for entry: String in rest_session.log_entries:
		if entry.contains("休息"):
			rest_logged = true
	_check(rest_logged, "休息がログに残る", "残らない")

	var move_session: GameSession = GameSession.new(15003)
	move_session.move_to("bridgewatch")
	var move_logged: bool = false
	for entry: String in move_session.log_entries:
		if entry.contains("移動"):
			move_logged = true
	_check(move_logged, "移動がログに残る", "残らない")

	var island: GameSession = GameSession.new(15004)
	island.silver = 1000000
	island.upgrade_island()
	var upgrade_logged: bool = false
	for entry: String in island.log_entries:
		if entry.contains("拡張"):
			upgrade_logged = true
	_check(upgrade_logged, "拡張がログに残る", "残らない")

	# 襲撃のログ。
	var raided: bool = false
	for seed_value: int in range(1, 300):
		var s: GameSession = GameSession.new(seed_value)
		s.buy("ore", 5)
		if s.cargo_count("ore") == 0:
			continue
		s.move_to("caerleon")
		if s.cargo.is_empty():
			for entry: String in s.log_entries:
				if entry.contains("襲撃"):
					raided = true
			break
	_check(raided, "襲撃がログに残る", "残らない")

	# 売買のログは「購入」「売却」を含むが、音はボタン側で鳴らす。
	# ここでは日誌側の判定に引っかからないことを確認する。
	var trade: GameSession = GameSession.new(15005)
	trade.buy("ore", 1)
	var buy_entry: String = ""
	for entry: String in trade.log_entries:
		if entry.contains("購入"):
			buy_entry = entry
	_check(buy_entry != "", "購入がログに残る", "残らない")
	# 「購入」を含むが「購入した」ではないため、拡張音とは区別される。
	_check(not buy_entry.contains("購入した"),
		"品目の購入と騎乗の購入が区別される", buy_entry)
