extends RefCounted
## セーブ/ロード。ファイル入出力と版の整合をここに集約する。
##
## autoload には置かない。--script のハーネスから load() + 静的呼び出しで
## そのまま検証できる形を保つ（scenario_m18.gd）。
## 状態そのものの写し取りは GameSession.to_dict() / from_dict() が持つ。
##
## 形式は JSON。状態が int/String/Dictionary/Array[String] だけで出来ており
## JSON の型と一致するうえ、中身を目で追えるのでバグ調査で効く。
##
## **path は必ず引数で受ける。** シナリオが専用のパスを使えるようにして、
## プレイヤーの実セーブを壊さずに検査できるようにするため。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")

## セーブデータの版。GameSession の状態の**意味**が変わったときに上げる。
## 品目や都市を足しただけなら上げない（欠損キーの補完で吸収できる）。
const SAVE_VERSION: int = 1

## これより古い版は読まない。
## **移行を書いたときはここを上げない**（上げると古いセーブが読めなくなり、
## せっかく書いた移行が死ぬ）。上げるのは移行を捨てるときだけ。
const MIN_SUPPORTED_VERSION: int = 1

const SAVE_PATH: String = "user://savegame.json"

## 直前の load_game() が失敗した理由。成功時は空文字。
static var _last_error: String = ""


## 保存する。書けたら true。
static func save_game(session: GameSession, path: String = SAVE_PATH) -> bool:
	if session == null:
		return false
	var data: Dictionary = session.to_dict()
	data["version"] = SAVE_VERSION

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		# user:// が書けない環境（権限など）では null が返る。
		return false
	# インデントを入れておく。数KB増えるだけで、中身を目で追えるようになる。
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


## 読み込む。成功したら復元済みの GameSession、失敗したら null。
## 失敗の理由は last_error() で取れる。
static func load_game(path: String = SAVE_PATH) -> GameSession:
	_last_error = ""

	if not FileAccess.file_exists(path):
		_last_error = "セーブデータが見つからない。"
		return null

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_last_error = "セーブデータを開けない（エラー %d）。" % FileAccess.get_open_error()
		return null
	var text: String = file.get_as_text()
	file.close()

	# 壊れた JSON でも例外は投げられない（GDScript に例外はない）。
	# 必ず戻り値で判断すること。
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_last_error = "セーブデータが壊れている。"
		return null

	var data: Dictionary = parsed as Dictionary
	var version: int = int(data.get("version", 0))
	if version < MIN_SUPPORTED_VERSION:
		_last_error = "このセーブデータは古すぎる（版 %d、対応は %d 以上）。" % [
			version, MIN_SUPPORTED_VERSION]
		return null
	if version > SAVE_VERSION:
		# 新しい版で意味が変わったキーを旧解釈で読むと、静かに壊れた状態で
		# 遊ぶことになる。推測で読まない。
		_last_error = "このセーブデータは新しい版のもの（版 %d、このゲームは %d まで）。" % [
			version, SAVE_VERSION]
		return null

	# 現在地が分からないと積荷も移動費も前提が崩れる。黙って直さず断る。
	var city: String = str(data.get("current_city", ""))
	if city != "" and not GameData.CITIES.has(city):
		_last_error = "知らない都市が記録されている（%s）。" % city
		return null

	var session: GameSession = GameSession.new(0)
	session.from_dict(_migrate(data))
	_clamp_ranges(session)
	return session


## セーブが存在するか。UI の「続きから」を出すかの判断に使う。
static func has_save(path: String = SAVE_PATH) -> bool:
	return FileAccess.file_exists(path)


## セーブを消す。新規開始時や、壊れたセーブを掴んだときに使う。
static func delete_save(path: String = SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	# user:// をそのまま渡す。globalize_path() は書き出したビルドで
	# user:// を解決しないことがあり、変換を挟む利点が無い。
	return DirAccess.remove_absolute(path) == OK


## 直前の load_game() が失敗した理由。成功時は空文字。
static func last_error() -> String:
	return _last_error


## 版の差を吸収する。今は版1しかないので素通し。
## 意味の変わるキーを入れたらここに変換を書く。
static func _migrate(data: Dictionary) -> Dictionary:
	return data


## 範囲から外れた値を丸める。都市と違い、これらは黙って直しても
## プレイヤーの前提を壊さない。
static func _clamp_ranges(session: GameSession) -> void:
	session.island_level = clampi(
		session.island_level, 0, GameData.ISLAND_LEVELS.size() - 1)
	if not GameData.MOUNTS.has(session.mount):
		session.mount = GameData.INITIAL_MOUNT
