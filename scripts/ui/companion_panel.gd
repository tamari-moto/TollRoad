extends PanelContainer
## ギルド仲間。同時に同行できるのは1人のみ。切り替えは無料・即時（日数を消費しない）。

const GameData = preload("res://scripts/systems/game_data.gd")
const GameSession = preload("res://scripts/systems/game_session.gd")
const UiUtil = preload("res://scripts/ui/ui_util.gd")

const BUTTON_MIN_SIZE: Vector2 = Vector2(0, 44)

var _session: GameSession
var _list: VBoxContainer
var _buttons: Dictionary = {}
var _none_button: Button


func bind(session: GameSession) -> void:
	UiUtil.rebind(_session, session, {
		"companion_changed": _on_companion_changed,
	})
	_session = session
	_build()
	refresh()


func _build() -> void:
	if not _buttons.is_empty():
		return
	_list = UiUtil.find_node(self, "CompanionList")
	if _list == null:
		return

	_none_button = Button.new()
	_none_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_none_button.custom_minimum_size = BUTTON_MIN_SIZE
	_none_button.tooltip_text = "誰も同行しない。効果は無いが制約も無い"
	_none_button.pressed.connect(_on_companion_pressed.bind(GameData.COMPANION_NONE))
	_list.add_child(_none_button)

	for companion_id: String in GameData.COMPANION_ORDER:
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = BUTTON_MIN_SIZE
		button.pressed.connect(_on_companion_pressed.bind(companion_id))
		_list.add_child(button)
		_buttons[companion_id] = button


func refresh() -> void:
	if _session == null:
		return
	_build()
	if _list == null:
		return

	if is_instance_valid(_none_button):
		var solo: bool = _session.active_companion == GameData.COMPANION_NONE
		_none_button.text = "一人旅（同行者なし）%s" % ["・選択中" if solo else ""]
		_none_button.disabled = solo

	for companion_id: String in _buttons:
		var button: Button = _buttons[companion_id]
		if not is_instance_valid(button):
			continue
		var data: Dictionary = GameData.COMPANIONS[companion_id]
		var active: bool = _session.active_companion == companion_id
		button.text = "%s — %s%s" % [data["name"], data["role"], "・選択中" if active else ""]
		button.tooltip_text = data["desc"]
		button.disabled = active


func _on_companion_pressed(companion_id: String) -> void:
	_session.set_companion(companion_id)


func _on_companion_changed(_companion_id: String) -> void:
	refresh()
