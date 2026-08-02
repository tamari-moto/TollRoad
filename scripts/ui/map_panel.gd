extends PanelContainer
## 大陸図。5つの王国都市を円周に、カーレオンを中央に配置した地図。
##
## 環状の王道は実線、カーレオンへの黒ゾーンは破線で結ぶ。位置関係を
## そのまま画面にすることで、「中央へ渡るには黒ゾーンを通るしかない」
## という構造が一目で分かる。
##
## 各ノードは押せるボタンで、日数・費用・襲撃率をラベルに併記する。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const MapRoutes = preload("res://scripts/ui/map_routes.gd")
const MapGround = preload("res://scripts/ui/map_ground.gd")
const MapPin = preload("res://scripts/ui/map_pin.gd")
const MapView3D = preload("res://scripts/ui/map_view_3d.gd")
const MapCamera = preload("res://scripts/ui/map_camera.gd")

signal move_requested(city_id: String)

const COLOR_CURRENT := UiTheme.FOCUS
const COLOR_DANGER := UiTheme.WARN

## 地図領域の最小の高さ。円周配置が潰れない大きさを確保する。
const MAP_MIN_HEIGHT: int = 300
## 都市ノード1つの大きさ。ピンと都市名が収まる高さを取る。
const NODE_SIZE := Vector2(104, 96)
## 円周の半径を領域の短辺に対してどれだけ取るか。
## 斜め見下ろしで縦が潰れるぶん、横は大きめに取る。
const RADIUS_RATIO: float = 0.40

var _session: GameSession
var _map_area: Control
var _viewport: SubViewport
var _world: MapView3D
var _camera: MapCamera
var _dragging: bool = false
var _buttons: Dictionary = {}
var _confirm: ConfirmationDialog
var _pending_city: String = ""


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"day_advanced": _on_day_advanced,
		"silver_changed": _on_silver_changed,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if not _buttons.is_empty():
		return
	_map_area = UiUtil.find_node(self, "CityList")
	if _map_area == null:
		return
	_map_area.custom_minimum_size = Vector2(0, MAP_MIN_HEIGHT)
	_map_area.resized.connect(_layout_nodes)

	_build_viewport()

	var ordered: Array[String] = GameData.royal_city_ids()
	ordered.append(GameData.CAERLEON)
	for city_id: String in ordered:
		_map_area.add_child(_build_node(city_id))

	_confirm = ConfirmationDialog.new()
	_confirm.title = "移動の確認"
	_confirm.ok_button_text = "移動する"
	_confirm.cancel_button_text = "やめる"
	_confirm.confirmed.connect(_on_confirmed)
	add_child(_confirm)

	_layout_nodes()


## 3D の地図を SubViewport に描き、地図領域いっぱいに敷く。
## 都市ボタンはこの上に重ねるので、ここには入れない。
func _build_viewport() -> void:
	var container := SubViewportContainer.new()
	container.name = "MapViewport"
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.anchor_right = 1.0
	container.anchor_bottom = 1.0
	container.offset_right = 0.0
	container.offset_bottom = 0.0
	# 3D の上でドラッグとホイールを拾う。
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_map_input)
	_map_area.add_child(container)

	_viewport = SubViewport.new()
	_viewport.name = "MapSubViewport"
	# 本編の 2D 世界を映さないよう、独自の 3D 世界を持たせる。
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	_world = MapView3D.new()
	_world.name = "World"
	_viewport.add_child(_world)

	_camera = MapCamera.new()
	_camera.name = "MapCamera"
	_viewport.add_child(_camera)


## 地図の上でのマウス操作。左ドラッグで回し、ホイールで寄る。
## SubViewportContainer の中でだけ拾うので、外のタブには影響しない。
func _on_map_input(event: InputEvent) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return

	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom_by(-MapCamera.ZOOM_STEP)
			_update_button_positions()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom_by(MapCamera.ZOOM_STEP)
			_update_button_positions()
		return

	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _dragging:
		_camera.rotate_by(
			-motion.relative.x * MapCamera.YAW_SPEED,
			motion.relative.y * MapCamera.PITCH_SPEED)
		_update_button_positions()


## 紋章とラベルを持つ都市ノード。ボタン自体が押下対象。
func _build_node(city_id: String) -> Button:
	var button := Button.new()
	button.name = city_id
	button.custom_minimum_size = NODE_SIZE
	button.size = NODE_SIZE
	button.clip_text = false
	# 背景を消して地形の上に直接ピンが立って見えるようにする。
	# flat だけでは押下時やフォーカス時の枠が残るため、状態ごとに
	# 空のスタイルを与える。
	button.flat = true
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	button.pressed.connect(_on_city_pressed.bind(city_id))

	# 枠と軸を描くピン。中身より先に足して背面に置く。
	var pin: MapPin = MapPin.new()
	pin.name = "Pin"
	pin.set_anchors_preset(Control.PRESET_FULL_RECT)
	pin.anchor_right = 1.0
	pin.anchor_bottom = 1.0
	pin.offset_right = 0.0
	pin.offset_bottom = 0.0
	pin.danger = city_id == GameData.CAERLEON
	button.add_child(pin)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.offset_right = 0.0
	column.offset_bottom = 0.0
	column.add_theme_constant_override("separation", 0)

	# 紋章を菱形の枠の中に収める。枠の中心に合わせて上に寄せる。
	var crest: Texture2D = UiIcons.city_texture(city_id)
	if crest != null:
		var icon := TextureRect.new()
		icon.texture = crest
		icon.custom_minimum_size = Vector2(26, 26)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(icon)

	# 軸のぶんの余白。ピンが地面に立って見えるようにする。
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, MapPin.STEM_LENGTH + 6)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(spacer)

	var note := Label.new()
	note.name = "Note"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 11)
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(note)

	button.add_child(column)
	_buttons[city_id] = button
	return button


## 3D の都市座標を画面へ投影し、その位置にボタンを置く。
##
## ボタンを 3D 化せず 2D のまま重ねるのは、クリック判定・disabled・
## ツールチップという既存の仕組みをそのまま使うため。カメラを動かすと
## ここが呼ばれてボタンが追従する。
func _layout_nodes() -> void:
	if _map_area == null or _buttons.is_empty():
		return
	var area: Vector2 = _map_area.size
	if area.x <= 0.0 or area.y <= 0.0:
		return
	if is_instance_valid(_viewport):
		_viewport.size = Vector2i(area)
	_update_button_positions()


## 各ボタンを 3D 座標の投影先へ動かす。
func _update_button_positions() -> void:
	if _world == null or _camera == null:
		return
	if not is_instance_valid(_world) or not is_instance_valid(_camera):
		return

	var screen_positions: Dictionary = {}
	for city_id: String in _world.positions:
		var world_point: Vector3 = _world.positions[city_id]
		# 柱の頭あたりを狙う。地面すれすれだとラベルが埋もれる。
		world_point.y += MapView3D.CITY_HEIGHT
		var screen: Vector2 = _camera.unproject_position(world_point)
		screen_positions[city_id] = screen
		_place(city_id, screen)

	_sort_by_depth(screen_positions)


## 奥（Y が小さい）の都市を先に描き、手前が上に重なるようにする。
## 奥行きの感覚はこの重なり順から生まれる。
func _sort_by_depth(positions: Dictionary) -> void:
	var ordered: Array[String] = []
	for city_id: String in positions:
		if _buttons.has(city_id):
			ordered.append(city_id)
	ordered.sort_custom(func(a: String, b: String) -> bool:
		return positions[a].y < positions[b].y)

	for city_id: String in ordered:
		var button: Button = _buttons[city_id]
		if is_instance_valid(button):
			_map_area.move_child(button, _map_area.get_child_count() - 1)


func _place(city_id: String, point: Vector2) -> void:
	var button: Button = _buttons.get(city_id)
	if is_instance_valid(button):
		button.position = point - NODE_SIZE * 0.5


func refresh() -> void:
	if _session == null or _buttons.is_empty():
		return
	# 3D 側の都市にも現在地を伝える（柱の色が変わる）。
	if is_instance_valid(_world):
		_world.set_current_city(_session.current_city)

	var over: bool = _session.is_over()
	for city_id: String in _buttons:
		var button: Button = _buttons[city_id]
		if not is_instance_valid(button):
			continue
		_refresh_node(button, city_id, over)
	_update_button_positions()


func _refresh_node(button: Button, city_id: String, over: bool) -> void:
	var city_name: String = GameData.CITIES[city_id]["name"]
	var note: Label = button.find_child("Note", true, false)

	# ピンの見た目を状態に合わせる。
	var pin: MapPin = button.find_child("Pin", true, false)
	if pin != null:
		pin.is_current = city_id == _session.current_city
		pin.danger = city_id == GameData.CAERLEON
		# 都市名の下に線を引く。ラベルの位置に合わせる。
		if note != null and note.size.x > 0.0:
			pin.underline_y = note.position.y - 2.0
			pin.underline_width = minf(note.size.x, NODE_SIZE.x - 8.0)

	if city_id == _session.current_city:
		button.text = ""
		button.tooltip_text = "%s（現在地）" % city_name
		button.disabled = true
		# 現在地は押せないが、居場所を示すので薄くしない。
		button.modulate.a = 1.0
		if note != null:
			note.text = "%s\n現在地" % city_name
			note.add_theme_color_override("font_color", COLOR_CURRENT)
		return

	var route: Dictionary = _session.route_to(city_id)
	if route.is_empty():
		button.text = ""
		button.tooltip_text = city_name
		button.disabled = true
		if note != null:
			note.text = city_name
			note.remove_theme_color_override("font_color")
		return

	var detail: String = "%d日 / %d" % [route["days"], route["cost"]]
	if route["raid_chance"] > 0.0:
		detail += "\n襲撃%d%%" % int(round(route["raid_chance"] * 100.0))

	# 検査や読み上げのため、テキスト情報はツールチップにも持たせる。
	button.text = ""
	button.tooltip_text = "%s　%s" % [city_name, detail.replace("\n", " / ")]
	button.disabled = over or not _session.can_move_to(city_id)
	# 背景を消しているぶん、行けない都市は文字を薄くして見分ける。
	button.modulate.a = 0.45 if button.disabled else 1.0

	if note != null:
		note.text = "%s\n%s" % [city_name, detail]
		if route["raid_chance"] > 0.0:
			note.add_theme_color_override("font_color", COLOR_DANGER)
		else:
			note.remove_theme_color_override("font_color")


func _on_city_pressed(city_id: String) -> void:
	var route: Dictionary = _session.route_to(city_id)
	if route.is_empty():
		return
	_pending_city = city_id

	var lines: PackedStringArray = []
	lines.append("%s へ移動しますか？" % GameData.CITIES[city_id]["name"])
	lines.append("")
	lines.append("日数: %d日　費用: %s シルバー" % [route["days"], UiUtil.format_number(route["cost"])])
	if route["raid_chance"] > 0.0:
		lines.append("")
		lines.append("黒ゾーンを通ります。%d%% の確率で襲撃され、" % int(round(route["raid_chance"] * 100.0)))
		lines.append("積荷を全て失います（シルバーと島倉庫は無事）。")
		if _session.cargo_weight() > 0:
			lines.append("現在の積荷: %d / %d" % [_session.cargo_weight(), _session.capacity()])

	_confirm.dialog_text = "\n".join(lines)
	# ツリー外（--script のハーネス）では表示できない。文面だけ整えて返す。
	if _confirm.is_inside_tree():
		_confirm.popup_centered()


func _on_confirmed() -> void:
	if _pending_city == "":
		return
	move_requested.emit(_pending_city)
	_session.move_to(_pending_city)
	_pending_city = ""
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()


func _on_silver_changed(_amount: int) -> void:
	refresh()
