@tool
## **默认**的对话/提示表现: 一条圆角气泡 + 富文本。
##
## 这不是"唯一形态"——只为了让框架开箱可用。
## 项目想要自己的样子(立绘/打字机/全屏字幕/3D 头顶文本)就:
##   · 继承 DialoguePresenter 自己实现 present()/dismiss()/refresh(), 或
##   · 继承本类, 只覆盖 `_build_view()` / `_apply_style()` / `_layout_slots()`。
class_name BubblePresenter extends DialoguePresenter

@export var style: StyleBox
@export var font_size := 20
@export var font_color := Color(1, 1, 1, 1)
@export var content_padding := Vector4(22.0, 14.0, 22.0, 14.0)

var panel: Panel
var label: RichTextLabel

var _slots := {}
var _text := ""
var _layout_key := []


func _ready() -> void:
	super._ready()
	_build_view()


func _build_view() -> void:
	panel = Panel.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	label = RichTextLabel.new()
	label.name = "Label"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.bbcode_enabled = true
	label.fit_content = false
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	_apply_style()


func _apply_style() -> void:
	if panel == null:
		return
	var box := style
	if box == null and has_theme_stylebox("panel", "DialogueBubble"):
		box = get_theme_stylebox("panel", "DialogueBubble")
	if box == null:
		var flat := StyleBoxFlat.new()
		flat.bg_color = Color(0.09, 0.1, 0.12, 0.94)
		flat.set_corner_radius_all(10)
		box = flat
	panel.add_theme_stylebox_override("panel", box)
	if label:
		label.add_theme_font_size_override("normal_font_size", font_size)
		label.add_theme_color_override("default_color", font_color)


# ------------------------------------------------------------
# 表现实现
# ------------------------------------------------------------

func present(line: DialogueLineDef, text: String) -> void:
	var content := text
	if content.is_empty() and line:
		content = line.get_display_text()
	set_text(content)


func set_text(text: String) -> void:
	_text = text
	var should_show := not text.is_empty()
	if should_show and not visible:
		visible = true
		shown.emit()
	elif not should_show and visible:
		visible = false
		dismissed.emit()
	_layout_key = []
	refresh()


func dismiss() -> void:
	set_text("")


func get_text() -> String:
	return _text


func attach_slot(slot_name: StringName, node: Control, size: Vector2) -> void:
	if node == null:
		return
	if node.get_parent() == null:
		add_child(node)
	_slots[slot_name] = {"node": node, "size": size}
	refresh()


func detach_slot(slot_name: StringName) -> void:
	_slots.erase(slot_name)
	refresh()


func refresh() -> void:
	if not visible or label == null:
		return
	var view := get_view_size()
	if view.x <= 0.0:
		return
	var key := [view, _text, get_anchor_rect(), placement, max_width, min_width,
			min_height, content_padding, gap, limit_top, _slot_height()]
	if key == _layout_key:
		return
	_layout_key = key

	var pad_l := content_padding.x
	var pad_t := content_padding.y
	var pad_r := content_padding.z
	var pad_b := content_padding.w
	var slot_w := _slot_width()
	var slot_h := _slot_height()

	var width := minf(view.x - screen_margin * 2.0, max_width)
	if min_width > 0.0:
		width = maxf(width, min_width)
	label.size = Vector2(maxf(width - pad_l - pad_r - slot_w, 1.0), 0.0)
	var height := maxf(label.get_content_height(), slot_h) + pad_t + pad_b
	height = maxf(height, min_height)
	var panel_size := Vector2(width, height)

	panel.position = resolve_position(panel_size)
	panel.size = panel_size
	label.position = Vector2(pad_l + slot_w, pad_t)
	label.size = Vector2(maxf(panel_size.x - pad_l - pad_r - slot_w, 1.0),
			maxf(panel_size.y - pad_t - pad_b, 1.0))
	_layout_slots(pad_l, pad_t)
	if get_parent():
		get_parent().move_child(self, -1)
	placed.emit()


func _slot_width() -> float:
	var total := 0.0
	for entry in _slots.values():
		total = maxf(total, entry.size.x)
	return total + (8.0 if not _slots.is_empty() else 0.0)


func _slot_height() -> float:
	var total := 0.0
	for entry in _slots.values():
		total += entry.size.y
	return total


## 插槽默认左上竖排, 项目可覆盖
func _layout_slots(pad_l: float, pad_t: float) -> void:
	var y := pad_t
	for entry in _slots.values():
		var node: Control = entry.node
		if not is_instance_valid(node):
			continue
		node.position = Vector2(pad_l, y)
		node.size = entry.size
		y += entry.size.y
