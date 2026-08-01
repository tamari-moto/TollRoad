extends PanelContainer
## 島と装備。島の拡張、島倉庫からの引き取り、騎乗の購入をまとめる。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")

var _session: GameSession
var _island_image: TextureRect
var _island_label: Label
var _upgrade_button: Button
var _warehouse_label: Label
var _withdraw_button: Button
var _mount_list: VBoxContainer
var _mount_buttons: Dictionary = {}


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		# silver_changed は引数を1つ渡すため、専用のハンドラで受ける。
		"silver_changed": _on_silver_changed,
		"warehouse_changed": _on_changed,
		"island_upgraded": _on_island_upgraded,
		"mount_changed": _on_mount_changed,
		"cargo_changed": _on_changed,
		"day_advanced": _on_day_advanced,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if not _mount_buttons.is_empty():
		return
	_island_image = UiUtil.find_node(self, "IslandImage")
	_island_label = UiUtil.find_node(self, "IslandLabel")
	_upgrade_button = UiUtil.find_node(self, "UpgradeButton")
	_warehouse_label = UiUtil.find_node(self, "WarehouseLabel")
	_withdraw_button = UiUtil.find_node(self, "WithdrawButton")
	_mount_list = UiUtil.find_node(self, "MountList")

	if is_instance_valid(_upgrade_button):
		_upgrade_button.pressed.connect(_on_upgrade_pressed)
	if is_instance_valid(_withdraw_button):
		_withdraw_button.pressed.connect(_on_withdraw_pressed)

	if _mount_list == null:
		return
	for mount_id: String in GameData.MOUNTS:
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_on_mount_pressed.bind(mount_id))

		# 騎乗の図をボタンの icon として持たせる。積載の差が絵で伝わる。
		# text は従来どおり設定するので、既存の検査はそのまま通る。
		var art: Texture2D = UiIcons.mount_texture(mount_id)
		if art != null:
			button.icon = art
			button.expand_icon = true
			button.custom_minimum_size = Vector2(0, UiIcons.MOUNT_ICON_SIZE.y)
			button.add_theme_constant_override(
				"icon_max_width", int(UiIcons.MOUNT_ICON_SIZE.x))

		_mount_list.add_child(button)
		_mount_buttons[mount_id] = button


func refresh() -> void:
	if _session == null:
		return
	_build()
	var over: bool = _session.is_over()

	# 島の図はレベルごとに差し替える。拡張の成果が絵で分かるようにする。
	if is_instance_valid(_island_image):
		_island_image.texture = UiIcons.island_texture(_session.island_level)

	if is_instance_valid(_island_label):
		_island_label.text = "島レベル %d　労働者 %d 人（1日 %d 個）" % [
			_session.island_level, _session.worker_count(),
			_session.worker_count() * GameData.RESOURCES_PER_WORKER_PER_DAY]

	if is_instance_valid(_upgrade_button):
		if _session.is_island_max_level():
			_upgrade_button.text = "拡張済み（最大）"
			_upgrade_button.disabled = true
		else:
			var cost: int = _session.island_upgrade_cost()
			var next_workers: int = GameData.ISLAND_LEVELS[_session.island_level + 1]["workers"]
			_upgrade_button.text = "レベル%d へ拡張（%s / 労働者%d人）" % [
				_session.island_level + 1, UiUtil.format_number(cost), next_workers]
			_upgrade_button.disabled = over or _session.silver < cost

	if is_instance_valid(_warehouse_label):
		_warehouse_label.text = "島倉庫: %s" % _warehouse_summary()

	if is_instance_valid(_withdraw_button):
		var takeable: int = _session.max_withdrawable()
		_withdraw_button.text = "引き取る（%d個・1日）" % takeable if takeable > 0 else "引き取る（1日）"
		_withdraw_button.disabled = over or _session.warehouse_total() <= 0 or takeable <= 0
		if _session.warehouse_total() <= 0:
			_withdraw_button.tooltip_text = "島倉庫が空。労働者が資源を運ぶまで待つ"
		elif takeable <= 0:
			_withdraw_button.tooltip_text = "積荷に空きがない"
		else:
			_withdraw_button.tooltip_text = "1日を消費して島倉庫から積載上限まで引き取る"

	for mount_id: String in _mount_buttons:
		var button: Button = _mount_buttons[mount_id]
		if not is_instance_valid(button):
			continue
		var mount: Dictionary = GameData.MOUNTS[mount_id]
		if mount_id == _session.mount:
			button.text = "%s（使用中・積載%d）" % [mount["name"], mount["capacity"]]
			button.disabled = true
		else:
			button.text = "%s　積載%d / %s" % [
				mount["name"], mount["capacity"], UiUtil.format_number(mount["cost"])]
			button.disabled = over or _session.silver < mount["cost"]


func _warehouse_summary() -> String:
	if _session.warehouse.is_empty():
		return "（空）"
	var parts: PackedStringArray = []
	for item_id: String in _session.warehouse:
		parts.append("%s %d" % [GameData.ITEMS[item_id]["name"], _session.warehouse[item_id]])
	return "%s　計 %d 個" % ["　".join(parts), _session.warehouse_total()]


func _on_upgrade_pressed() -> void:
	_session.upgrade_island()


func _on_withdraw_pressed() -> void:
	_session.withdraw_from_warehouse()


func _on_mount_pressed(mount_id: String) -> void:
	_session.buy_mount(mount_id)


func _on_changed() -> void:
	refresh()


func _on_silver_changed(_amount: int) -> void:
	refresh()


func _on_island_upgraded(_level: int) -> void:
	refresh()


func _on_mount_changed(_mount_id: String) -> void:
	refresh()


func _on_day_advanced(_day: int) -> void:
	refresh()
