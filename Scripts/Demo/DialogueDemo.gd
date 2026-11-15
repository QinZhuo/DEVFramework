extends Control

## 对话模块 Demo —— 覆盖 Dialogue 子系统的全部能力。
##
## 运行方式: 直接运行本场景(Scenes/Dialogue/DialogueDemo.tscn)。
##
## 展示内容:
##   1. 单行提示 show() / 隐藏 hide()
##   2. 多行对话 play() + next() 逐句推进(带 finished 回调)
##   3. 锚点跟随: 拖动中间的方块, 气泡跟随并自动上下翻转
##   4. 插槽: 往气泡左侧塞一个色块(attach_slot / detach_slot)
##   5. 定位策略: 跟随目标 / 贴底居中 / 左上角(改 max_width + 锚点为空)

const SCRIPT_LINES := [
	"你好，我是对话系统。",
	"我支持多行脚本、逐句推进，也可以循环。",
	"按「下一句」继续，或者直接点「隐藏」结束。",
]

var _follow := true
var _dragging := false
var _drag_offset := Vector2.ZERO
var _target: Panel
var _status: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 把对话子系统绑到这一层: 之后 show/play 出来的气泡就是它的子节点
	DialogueTool.bind(self)
	_build_ui()
	DialogueTool.show("点击下面的按钮试试；也可以拖动中间的方块看我跟随。", _target.get_global_rect())


func _process(_delta: float) -> void:
	if not _follow:
		return
	# 每帧把目标包围盒喂给气泡: 目标动, 气泡就跟着动, 放不下时会自动翻到上方
	DialogueTool.set_anchor(_target.get_global_rect(), size)


# ------------------------------------------------------------
# UI(全部用代码搭, 避免维护一个复杂场景)
# ------------------------------------------------------------

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := Label.new()
	title.text = "Dialogue 子系统 Demo"
	title.add_theme_font_size_override("font_size", 28)
	title.position = Vector2(32, 24)
	add_child(title)

	_target = Panel.new()
	_target.size = Vector2(220, 120)
	_target.position = Vector2(size.x * 0.5 - 110, size.y * 0.42)
	_target.gui_input.connect(_on_target_input)
	var target_label := Label.new()
	target_label.text = "拖我"
	target_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	target_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_target.add_child(target_label)
	add_child(_target)

	var row := HBoxContainer.new()
	row.position = Vector2(32, 96)
	row.add_theme_constant_override("separation", 10)
	add_child(row)

	_add_button(row, "单行提示", _on_show_one)
	_add_button(row, "多行对话", _on_play_script)
	_add_button(row, "下一句", _on_next)
	_add_button(row, "塞入插槽", _on_attach_slot)
	_add_button(row, "移除插槽", _on_detach_slot)
	_add_button(row, "跟随/贴底", _on_toggle_follow)
	_add_button(row, "左上角", _on_left_top)
	_add_button(row, "隐藏", _on_hide)

	_status = Label.new()
	_status.position = Vector2(32, 144)
	_status.add_theme_font_size_override("font_size", 16)
	add_child(_status)


func _add_button(row: HBoxContainer, text: String, cb: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.pressed.connect(cb)
	row.add_child(btn)


func _set_status(text: String) -> void:
	if _status:
		_status.text = text


# ------------------------------------------------------------
# 按钮回调
# ------------------------------------------------------------

func _on_show_one() -> void:
	_follow = true
	DialogueTool.show("这是一条单行提示。气泡宽度会跟随文案长度自动收缩。", _target.get_global_rect())
	_set_status("show(): 单行提示")


func _on_play_script() -> void:
	var script := DialogueScriptDef.new()
	var lines: Array[DialogueLineDef] = []
	for t in SCRIPT_LINES:
		var line := DialogueLineDef.new()
		line.text = t
		lines.append(line)
	script.lines = lines
	_follow = true
	DialogueTool.play(script)
	_set_status("play(): 多行脚本已开始, 点「下一句」推进")


func _on_next() -> void:
	var advanced := DialogueTool.next()
	_set_status("next() -> %s" % advanced)


func _on_attach_slot() -> void:
	var view := DialogueTool.view() as BubbleView
	if view == null:
		return
	var block := ColorRect.new()
	block.color = Color(0.98, 0.75, 0.2)
	block.custom_minimum_size = Vector2(96, 96)
	view.attach_slot(&"demo", block, Vector2(96, 96))
	_set_status("attach_slot(): 气泡左侧插入色块, 文字自动右移")


func _on_detach_slot() -> void:
	var view := DialogueTool.view() as BubbleView
	if view == null:
		return
	view.detach_slot(&"demo")
	_set_status("detach_slot(): 插槽已移除")


func _on_toggle_follow() -> void:
	_follow = not _follow
	if _follow:
		DialogueTool.set_anchor(_target.get_global_rect(), size)
		_set_status("跟随目标")
	else:
		DialogueTool.set_anchor(Rect2(), size)
		_set_status("贴底居中(锚点为空)")


func _on_left_top() -> void:
	var view := DialogueTool.view() as BubbleView
	if view == null:
		return
	_follow = false
	view.max_width = 640.0
	DialogueTool.set_anchor(Rect2(), size)
	DialogueTool.show("左上角模式: 通过 max_width + 空锚点实现, 不使用二次布局覆盖。", Rect2())
	_set_status("左上角提示")


func _on_hide() -> void:
	DialogueTool.hide()
	_set_status("hide()")


# ------------------------------------------------------------
# 拖动目标
# ------------------------------------------------------------

func _on_target_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_offset = _target.position - get_global_mouse_position()
	elif event is InputEventMouseMotion and _dragging:
		_target.position = get_global_mouse_position() + _drag_offset
