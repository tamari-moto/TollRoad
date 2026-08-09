extends PanelContainer
## 大陸図。5つの王国都市を円周に、カーレオンを中央に配置した地図。
##
## 環状の王道は実線、カーレオンへの黒ゾーンは破線で結ぶ。位置関係を
## そのまま画面にすることで、「中央へ渡るには黒ゾーンを通るしかない」
## という構造が一目で分かる。
##
## 都市の選択は SubViewportContainer 上のクリックをレイキャストで
## 3D の柱と判定する（Button は使わない）。クリック可能領域が常に
## 地図領域自身の矩形内に収まるため、周囲のパネルへはみ出さない。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
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

## クリック判定の半径（3D空間の単位）。都市の柱（半径0.55・高さ1.5、
## map_view_3d.gd 参照）より一回り大きく取り、狙いやすくする。
const PICK_RADIUS: float = 1.3
## この距離（px）以上動かしてから離したらカメラ操作とみなし、
## 都市の選択はしない。
const CLICK_TOLERANCE: float = 6.0

var _session: GameSession
var _map_area: Control
var _viewport: SubViewport
var _world: MapView3D
var _camera: MapCamera
var _dragging: bool = false
var _press_point: Vector2 = Vector2.ZERO
## city_id -> 見た目だけを担当する Control（ピンと都市名）。
var _nodes: Dictionary = {}
var _confirm: ConfirmationDialog
var _pending_city: String = ""
var _tooltip: PanelContainer
var _tooltip_label: Label
## ホバー中の都市。無ければ空文字列。
var _hovered_city: String = ""


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"day_advanced": _on_day_advanced,
		"silver_changed": _on_silver_changed,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if not _nodes.is_empty():
		return
	_map_area = UiUtil.find_node(self, "CityList")
	if _map_area == null:
		return
	_map_area.custom_minimum_size = Vector2(0, MAP_MIN_HEIGHT)
	# 見た目のはみ出しに対する最後の防衛線。クリック判定は
	# SubViewportContainer 側にしか無いので、操作性には影響しない。
	_map_area.clip_contents = true
	_map_area.resized.connect(layout_nodes)

	_build_viewport()

	var ordered: Array[String] = GameData.royal_city_ids()
	ordered.append(GameData.CAERLEON)
	for city_id: String in ordered:
		_map_area.add_child(_build_node(city_id))

	_build_tooltip()

	_confirm = ConfirmationDialog.new()
	_confirm.title = "移動の確認"
	_confirm.ok_button_text = "移動する"
	_confirm.cancel_button_text = "やめる"
	_confirm.confirmed.connect(_on_confirmed)
	add_child(_confirm)

	layout_nodes()


## 3D の地図を SubViewport に描き、地図領域いっぱいに敷く。
## 都市の当たり判定・ドラッグ・ホイールもこの上でまとめて拾う。
func _build_viewport() -> void:
	var container := SubViewportContainer.new()
	container.name = "MapViewport"
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.anchor_right = 1.0
	container.anchor_bottom = 1.0
	container.offset_right = 0.0
	container.offset_bottom = 0.0
	# 3D の上でドラッグ・ホイール・クリックを拾う。
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_map_input)
	container.mouse_exited.connect(_on_map_mouse_exited)
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


## ホバー中の都市を示すツールチップ。マウス追従で位置と文言を差し替える。
## 地図領域の最後の子として足し、常に一番上に描く。
func _build_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.name = "MapTooltip"
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override("panel", UiTheme.make_panel_style())
	_tooltip.visible = false

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 4)

	_tooltip_label = Label.new()
	_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_label.add_theme_font_size_override("font_size", 13)
	margin.add_child(_tooltip_label)
	_tooltip.add_child(margin)

	_map_area.add_child(_tooltip)


## 地図の上でのマウス操作。左ドラッグで回し、ホイールで寄る。
## 動かした距離が小さいまま離した左クリックは都市の選択として扱う。
## SubViewportContainer の中でだけ拾うので、外のタブには影響しない。
func _on_map_input(event: InputEvent) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return

	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_dragging = true
				_press_point = button.position
			else:
				_dragging = false
				if button.position.distance_to(_press_point) <= CLICK_TOLERANCE:
					var city_id: String = pick_city_at(button.position)
					if city_id != "":
						select_city(city_id)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom_by(-MapCamera.ZOOM_STEP)
			_update_button_positions()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom_by(MapCamera.ZOOM_STEP)
			_update_button_positions()
		return

	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		if _dragging:
			_camera.rotate_by(
				-motion.relative.x * MapCamera.YAW_SPEED,
				motion.relative.y * MapCamera.PITCH_SPEED)
			_update_button_positions()
			_set_hovered_city("")
		else:
			_set_hovered_city(pick_city_at(motion.position))


func _on_map_mouse_exited() -> void:
	_set_hovered_city("")


## ホバー中の都市を切り替え、ツールチップの表示を更新する。
func _set_hovered_city(city_id: String) -> void:
	if city_id == _hovered_city:
		return
	_hovered_city = city_id
	if city_id == "" or _session == null:
		_tooltip.visible = false
		return
	_tooltip_label.text = tooltip_text_for(city_id)
	_tooltip.visible = true
	_position_tooltip(city_id)


## ツールチップを都市の投影位置の近くへ置く。地図領域の内側に収める。
func _position_tooltip(city_id: String) -> void:
	if _map_area == null or not is_instance_valid(_tooltip):
		return
	var anchor: Vector2 = screen_position_for(city_id) + Vector2(0.0, -NODE_SIZE.y * 0.5 - 8.0)
	var tooltip_size: Vector2 = _tooltip.size
	var max_pos: Vector2 = _map_area.size - tooltip_size
	_tooltip.position = Vector2(
		clampf(anchor.x - tooltip_size.x * 0.5, 0.0, maxf(max_pos.x, 0.0)),
		clampf(anchor.y - tooltip_size.y, 0.0, maxf(max_pos.y, 0.0)))


## 紋章とラベルを持つ都市ノード。クリックは受けず見た目だけを担当する
## （入力は SubViewportContainer 側のレイキャストで判定する）。
func _build_node(city_id: String) -> Control:
	var node := Control.new()
	node.name = city_id
	node.custom_minimum_size = NODE_SIZE
	node.size = NODE_SIZE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 枠と軸を描くピン。中身より先に足して背面に置く。
	var pin: MapPin = MapPin.new()
	pin.name = "Pin"
	pin.set_anchors_preset(Control.PRESET_FULL_RECT)
	pin.anchor_right = 1.0
	pin.anchor_bottom = 1.0
	pin.offset_right = 0.0
	pin.offset_bottom = 0.0
	pin.danger = city_id == GameData.CAERLEON
	node.add_child(pin)

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

	node.add_child(column)
	_nodes[city_id] = node
	return node


## 3D の都市座標を画面へ投影し、その位置にノードを置く。
##
## クリック判定は SubViewportContainer 側のレイキャストで行うため、
## ここは見た目（ピンとラベル）の追従だけを担当する。カメラを動かすと
## ここが呼ばれてノードが追従する。
##
## 公開しているのは、ツリー外では _map_area.resized が飛ばず、
## --script の検査から配置を確定させる手段が他にないため
## （テストのための抜け道ではなく、実行環境の制約に対する入口）。
func layout_nodes() -> void:
	if _map_area == null or _nodes.is_empty():
		return
	var area: Vector2 = _map_area.size
	if area.x <= 0.0 or area.y <= 0.0:
		return
	# SubViewport の大きさは SubViewportContainer の stretch が合わせるので
	# ここでは触らない（触ると警告になる）。
	_update_button_positions()


## カメラが現在地へ寄っている間、2D のノードは 3D の投影で置いているため
## 毎フレーム引き直さないと取り残される。
func _process(_delta: float) -> void:
	if not is_instance_valid(_camera):
		return
	if _camera.is_settled():
		return
	_update_button_positions()


func _update_button_positions() -> void:
	if _world == null or _camera == null:
		return
	if not is_instance_valid(_world) or not is_instance_valid(_camera):
		return

	var screen_positions: Dictionary = {}
	for city_id: String in _world.positions:
		var screen: Vector2 = screen_position_for(city_id)
		screen_positions[city_id] = screen
		_place(city_id, screen)

	_sort_by_depth(screen_positions)
	if is_instance_valid(_tooltip):
		_map_area.move_child(_tooltip, _map_area.get_child_count() - 1)
	if _hovered_city != "":
		_position_tooltip(_hovered_city)


## 都市の3D座標（柱の頭あたり）を画面座標へ投影する。
## ラベルの追従・ツールチップの位置決め・当たり判定の検査に共用する。
func screen_position_for(city_id: String) -> Vector2:
	var world_point: Vector3 = _world.positions[city_id]
	# 柱の頭あたりを狙う。地面すれすれだとラベルが埋もれる。
	world_point.y += MapView3D.CITY_HEIGHT
	return _camera.unproject_position(world_point)


## クリック/ホバー位置が当たる都市を返す。3D 空間でレイと各都市の柱の
## 中心との最短距離を比べ、PICK_RADIUS 以内でカメラに最も近いものを選ぶ。
## ノードの重なり順に頼らない、純粋な幾何判定なので --script からも
## そのまま呼べる。
func pick_city_at(local_point: Vector2) -> String:
	if _camera == null or _world == null:
		return ""
	if not is_instance_valid(_camera) or not is_instance_valid(_world):
		return ""

	var origin: Vector3 = _camera.project_ray_origin(local_point)
	var direction: Vector3 = _camera.project_ray_normal(local_point)

	var best_city: String = ""
	var best_t: float = INF
	for city_id: String in _world.positions:
		var pillar_center: Vector3 = _world.positions[city_id] \
			+ Vector3(0.0, MapView3D.CITY_HEIGHT * 0.5, 0.0)
		var t: float = (pillar_center - origin).dot(direction)
		if t < 0.0:
			continue
		var closest: Vector3 = origin + direction * t
		if closest.distance_to(pillar_center) > PICK_RADIUS:
			continue
		if t < best_t:
			best_t = t
			best_city = city_id
	return best_city


## 奥（Y が小さい）の都市を先に描き、手前が上に重なるようにする。
## 奥行きの感覚はこの重なり順から生まれる（見た目だけの話。当たり判定は
## pick_city_at のレイキャストが持つので影響しない）。
func _sort_by_depth(positions: Dictionary) -> void:
	var ordered: Array[String] = []
	for city_id: String in positions:
		if _nodes.has(city_id):
			ordered.append(city_id)
	ordered.sort_custom(func(a: String, b: String) -> bool:
		return positions[a].y < positions[b].y)

	for city_id: String in ordered:
		var node: Control = _nodes[city_id]
		if is_instance_valid(node):
			_map_area.move_child(node, _map_area.get_child_count() - 1)


func _place(city_id: String, point: Vector2) -> void:
	var node: Control = _nodes.get(city_id)
	if is_instance_valid(node):
		node.position = point - NODE_SIZE * 0.5


# --- 都市ノードを外から見る入口 ---
#
# 検査（scenario_m6.gd, scenario_m11.gd）が見た目を確かめるために使う。
# _nodes の辞書をそのまま公開すると内部表現が契約になるため、
# 用途ごとの関数を通す。


## その都市の見た目のノード。無ければ null。
func node_for(city_id: String) -> Control:
	var node: Control = _nodes.get(city_id)
	return node if is_instance_valid(node) else null


## 並んでいる都市ノードの数。
func node_count() -> int:
	return _nodes.size()


## 並んでいる都市のID。
func city_ids() -> Array[String]:
	var ids: Array[String] = []
	for city_id: String in _nodes:
		ids.append(city_id)
	return ids


## その都市のノードに出ている補足文（現在地／移動日数・費用・襲撃率）。
## 無ければ空文字。
func note_text_for(city_id: String) -> String:
	var node: Control = node_for(city_id)
	if node == null:
		return ""
	var note: Label = node.find_child("Note", true, false) as Label
	if note == null or not is_instance_valid(note):
		return ""
	return note.text


## その都市のノードに入っている紋章の数。
func crest_count_for(city_id: String) -> int:
	var node: Control = node_for(city_id)
	if node == null:
		return 0
	return node.find_children("*", "TextureRect", true, false).size()


## 3D の世界。都市の座標や地形を検査から確かめるための入口。
func world() -> MapView3D:
	return _world if is_instance_valid(_world) else null


## 地図を映しているカメラ。
func camera() -> MapCamera:
	return _camera if is_instance_valid(_camera) else null


## 3D を描いている SubViewport。
func viewport() -> SubViewport:
	return _viewport if is_instance_valid(_viewport) else null


## カメラを動かした後にピンを投影位置へ追従させる。
##
## 通常は入力処理から呼ばれる。検査がカメラを直接動かしたときも
## これを呼ばないとピンが古い位置に残る。
func update_node_positions() -> void:
	_update_button_positions()


func refresh() -> void:
	if _session == null or _nodes.is_empty():
		return
	# 3D 側の都市にも現在地を伝える（柱の色が変わる）。
	if is_instance_valid(_world):
		_world.set_current_city(_session.current_city)
		# カメラの周回もその都市を中心に据える。
		if is_instance_valid(_camera) and _world.positions.has(_session.current_city):
			_camera.focus_on(_world.positions[_session.current_city])

	for city_id: String in _nodes:
		var node: Control = _nodes[city_id]
		if not is_instance_valid(node):
			continue
		_refresh_node(node, city_id)
	_update_button_positions()

	# ホバー中に相場や資金が変わっても、ツールチップの文言を古いままにしない。
	if _hovered_city != "":
		_tooltip_label.text = tooltip_text_for(_hovered_city)


func _refresh_node(node: Control, city_id: String) -> void:
	var city_name: String = GameData.CITIES[city_id]["name"]
	var note: Label = node.find_child("Note", true, false)

	# ピンの見た目を状態に合わせる。
	var pin: MapPin = node.find_child("Pin", true, false)
	if pin != null:
		pin.is_current = city_id == _session.current_city
		pin.danger = city_id == GameData.CAERLEON
		# 都市名の下に線を引く。ラベルの位置に合わせる。
		if note != null and note.size.x > 0.0:
			pin.underline_y = note.position.y - 2.0
			pin.underline_width = minf(note.size.x, NODE_SIZE.x - 8.0)

	if city_id == _session.current_city:
		node.modulate.a = 1.0
		if note != null:
			note.text = "%s\n現在地" % city_name
			note.add_theme_color_override("font_color", COLOR_CURRENT)
		return

	var route: Dictionary = _session.route_to(city_id)
	if route.is_empty():
		node.modulate.a = 1.0
		if note != null:
			note.text = city_name
			note.remove_theme_color_override("font_color")
		return

	var detail: String = _route_detail(route)
	# 背景を持たないぶん、行けない都市は文字を薄くして見分ける。
	node.modulate.a = 1.0 if is_selectable(city_id) else 0.45

	if note != null:
		note.text = "%s\n%s" % [city_name, detail]
		if route["raid_chance"] > 0.0:
			note.add_theme_color_override("font_color", COLOR_DANGER)
		else:
			note.remove_theme_color_override("font_color")


## 日数・費用・襲撃率の説明文（複数行）。Note ラベルとツールチップで共用する。
func _route_detail(route: Dictionary) -> String:
	var detail: String = "%d日 / %d" % [route["days"], route["cost"]]
	if route["raid_chance"] > 0.0:
		detail += "\n襲撃%d%%" % int(round(route["raid_chance"] * 100.0))
	return detail


## ホバー時に表示する説明文。Note ラベルと同じ内容を1行にまとめたもの。
func tooltip_text_for(city_id: String) -> String:
	var city_name: String = GameData.CITIES[city_id]["name"]
	if city_id == _session.current_city:
		return "%s（現在地）" % city_name
	var route: Dictionary = _session.route_to(city_id)
	if route.is_empty():
		return city_name
	return "%s　%s" % [city_name, _route_detail(route).replace("\n", " / ")]


## その都市へ今クリックで移動できるか。ホバー表示の選択可否と
## select_city() の入口ガードの両方がこれを参照する単一の判定源。
func is_selectable(city_id: String) -> bool:
	if _session == null:
		return false
	if city_id == _session.current_city:
		return false
	if _session.is_over():
		return false
	return _session.can_move_to(city_id)


## 都市を選ぶ。クリック判定（pick_city_at）からも検査からも同じ経路で
## 呼べるよう公開している。
func select_city(city_id: String) -> void:
	if not is_selectable(city_id):
		return
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
