extends RefCounted
## 品目アイコンの読み込み。
##
## **画像が無くても壊れないこと**を前提に設計している。ファイルが欠けていれば
## null を返し、呼び出し側は TextureRect を足さないだけでレイアウトは崩れない。
## リポジトリから画像が失われた状態（クローン失敗など）でも、名前だけで
## 全画面が機能する。
##
## ui_util.gd / ui_theme.gd と同じ定数クラスの形にしてあるので、--script の
## ハーネスからも参照できる。

const ITEM_ICON_DIR: String = "res://assets/sprites/items"
const CITY_ICON_DIR: String = "res://assets/sprites/cities"
const MOUNT_ICON_DIR: String = "res://assets/sprites/mounts"
const ISLAND_ICON_DIR: String = "res://assets/sprites/island"

## 一覧に並べる際の推奨サイズ。
const LIST_ICON_SIZE: int = 20
## 騎乗の図（横長）。
const MOUNT_ICON_SIZE := Vector2(56, 42)
## 島の図（横長）。
const ISLAND_ICON_SIZE := Vector2(96, 64)

## "種別/id" -> Texture2D。見つからなかった場合も記録し、再探索を避ける。
static var _cache: Dictionary = {}


## 品目のアイコン。存在しなければ null。
static func item_texture(item_id: String) -> Texture2D:
	return _texture(ITEM_ICON_DIR, item_id)


## 都市の紋章。存在しなければ null。
static func city_texture(city_id: String) -> Texture2D:
	return _texture(CITY_ICON_DIR, city_id)


## 騎乗の図。存在しなければ null。
static func mount_texture(mount_id: String) -> Texture2D:
	return _texture(MOUNT_ICON_DIR, mount_id)


## 島の図。レベルに対応する画像を返す。存在しなければ null。
static func island_texture(level: int) -> Texture2D:
	return _texture(ISLAND_ICON_DIR, "island_%d" % level)


static func _texture(dir: String, id: String) -> Texture2D:
	var key: String = "%s/%s" % [dir, id]
	if _cache.has(key):
		return _cache[key]

	var path: String = "%s/%s.svg" % [dir, id]
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	_cache[key] = texture
	return texture


## アイコンを表示する TextureRect。画像が無ければ null を返す。
## 呼び出し側は null チェックして、無ければ何も足さない。
static func make_item_icon(item_id: String, size: int = LIST_ICON_SIZE) -> TextureRect:
	var texture: Texture2D = item_texture(item_id)
	if texture == null:
		return null
	var rect := TextureRect.new()
	rect.texture = texture
	rect.custom_minimum_size = Vector2(size, size)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return rect


## 「アイコン＋名前」を1つの Control にまとめる。
## GridContainer の列数を変えずにアイコンを足せるようにするためのもの。
## 画像が無ければ名前だけの Label 相当になる。
static func make_labeled_item(item_id: String, text: String,
		size: int = LIST_ICON_SIZE) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var icon: TextureRect = make_item_icon(item_id, size)
	if icon != null:
		box.add_child(icon)

	var label := Label.new()
	label.text = text
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(label)
	return box


## テスト用にキャッシュを破棄する。画像を差し替えた際にも使える。
static func clear_cache() -> void:
	_cache.clear()
