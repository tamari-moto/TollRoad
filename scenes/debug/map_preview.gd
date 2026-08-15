extends Node3D
## 大陸図（3D）だけを単独で起動して見るための確認用シーン。F6 で実行する。
##
## 本編では大陸図は SubViewport の中に own_world_3d = true で作られるため、
## エディタの 3D ビューポートからは原理的に見えない（別ワールドであり、かつ
## ノードは実行時に new() で組まれるので .tscn には存在しない）。ここは
## SubViewport を挟まず MapView3D をメインの世界に直接置くので、走らせれば
## 地形・都市・街道をそのまま見て回れる。
##
## 絵作り（フォグ・グロウ・トゥーン）を見比べるためのもので、ゲームの状態は
## 持たない。GameSession を作らないため、都市の選択・隊商・現在地の強調と
## いったセッション由来の表示は出ない。そこまで要るなら本編を起動すること。
##
## @tool は付けない。_build() はばね緩和300反復と地形メッシュの生成を含み、
## エディタ内で走らせると重いうえ、落ちたときにエディタごと巻き添えになる。

const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")

## 本編の map_panel.gd と同じ操作感にするための、クリックとドラッグの境目。
const DRAG_THRESHOLD: float = 4.0

var _world: MapView3D
var _camera: MapCamera
var _dragging: bool = false


func _init() -> void:
	_build()


func _ready() -> void:
	_build()


## _init() と _ready() の両方から呼ぶ（CLAUDE.md 参照）。二度組まないよう
## 先頭で弾く。
func _build() -> void:
	if _world != null:
		return

	_world = MapView3D.new()
	_world.name = "World"
	add_child(_world)

	_camera = MapCamera.new()
	_camera.name = "MapCamera"
	add_child(_camera)


## 本編の操作（map_panel.gd の _on_map_input）に合わせてある。左ドラッグで
## 回し、ホイールで寄る。都市の選択はセッションを持たないので扱わない。
func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = button.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					_camera.zoom_by(-MapCamera.ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_camera.zoom_by(MapCamera.ZOOM_STEP)
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		_camera.rotate_by(
			-motion.relative.x * MapCamera.YAW_SPEED,
			motion.relative.y * MapCamera.PITCH_SPEED)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key((event as InputEventKey).keycode)


## F4 は本編（main.gd）と同じトゥーンの切り替え。R は視点を戻す。
func _on_key(keycode: Key) -> void:
	match keycode:
		KEY_F4:
			_world.toggle_toon()
			print("トゥーン表示: %s" % ("入" if _world.is_toon_enabled() else "切"))
		KEY_R:
			_camera.reset_view()


## 検査から中身を確かめられるようにしておく。
func world() -> MapView3D:
	return _world


func camera() -> MapCamera:
	return _camera
