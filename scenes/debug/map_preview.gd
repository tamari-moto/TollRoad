extends Node3D
## 大陸図（3D）だけを単独で起動して見るための確認用シーン。F6 で実行する。
##
## 本編では大陸図は SubViewport の中に own_world_3d = true で作られるため、
## エディタの 3D ビューポートからは原理的に見えない（別ワールドであり、かつ
## ノードは実行時に new() で組まれるので .tscn には存在しない）。ここは
## SubViewport を挟まず MapView3D をメインの世界に直接置くので、走らせれば
## 地形・都市・街道をそのまま見て回れる。
##
## 視点は FPS 操作（WASD ＋ マウスルック）。本編の周回カメラでは中心から
## 一定の距離までしか寄れず、都市の足元や街道の起伏を間近で見られなかった。
## ここは絵作りを確かめる場なので、地表を歩ける方を採っている。
##
## 絵作りを見るためのもので、ゲームの状態は持たない。GameSession を作らない
## ため、都市の選択・隊商・現在地の強調といったセッション由来の表示は出ない。
## そこまで要るなら本編を起動すること。
##
## @tool は付けない。_build() はばね緩和300反復と地形メッシュの生成を含み、
## エディタ内で走らせると重いうえ、落ちたときにエディタごと巻き添えになる。

const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const PreviewCamera = preload("res://scenes/debug/map_preview_camera.gd")

var _world: MapView3D
var _camera: PreviewCamera
## マウスを掴んでいるか。掴んでいる間だけ視線が動く。
var _captured: bool = false


func _init() -> void:
	_build()


func _ready() -> void:
	_build()
	# ツリーに入ってからでないとマウスモードを触れない。起動直後から
	# 視点を回せるよう掴んでおく（外すのは Esc）。
	_set_captured(true)


## _init() と _ready() の両方から呼ぶ（CLAUDE.md 参照）。二度組まないよう
## 先頭で弾く。
func _build() -> void:
	if _world != null:
		return

	_world = MapView3D.new()
	_world.name = "World"
	add_child(_world)

	_camera = PreviewCamera.new()
	_camera.name = "PreviewCamera"
	add_child(_camera)
	# 地表の高さを引けるようにしてから、足元へ吸着させる。
	_camera.bind_world(_world)


## マウスは掴んで視線に使う。Esc で放し、クリックで掴み直す。
## 掴んでいる間はカーソルが消えるので、ウィンドウ外へ出られなくなる。
func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return

	if event is InputEventMouseMotion and _captured:
		var motion := event as InputEventMouseMotion
		_camera.look_by(
			-motion.relative.x * PreviewCamera.LOOK_SENSITIVITY,
			-motion.relative.y * PreviewCamera.LOOK_SENSITIVITY)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and not _captured:
			_set_captured(true)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key((event as InputEventKey).keycode)


func _on_key(keycode: Key) -> void:
	match keycode:
		KEY_ESCAPE:
			_set_captured(false)
		KEY_F:
			_camera.toggle_walking()
			print("移動: %s" % ("歩く" if _camera.walking else "飛ぶ"))
		KEY_F4:
			_world.toggle_toon()
			print("トゥーン表示: %s" % ("入" if _world.is_toon_enabled() else "切"))
		KEY_R:
			_camera.reset_view()


func _set_captured(value: bool) -> void:
	_captured = value
	# ツリー外（--script のハーネス）では触れない。
	if not is_inside_tree():
		return
	Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if value
		else Input.MOUSE_MODE_VISIBLE)


## 検査から中身を確かめられるようにしておく。
func world() -> MapView3D:
	return _world


func camera() -> PreviewCamera:
	return _camera
