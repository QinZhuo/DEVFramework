@tool
## 教程引导控件 — 遮罩/挖孔/边框/箭头/提示气泡一体化, 类 Godot 内置控件, 支持主题定制。
##
## 用法(项目创建后挂到自己的 CanvasLayer):
##   var guide := TutorialGuide.new()
##   guide.set_anchors_preset(Control.PRESET_FULL_RECT)
##   guide.focus(target, target_def, block, click_to_complete, tip_text)
##   guide.blur()
##
## 主题命名空间 "TutorialGuide"(Theme/ThemeTypeVariation 均可):
##   Color    dim_color         遮罩暗色
##   StyleBox frame_stylebox    挖孔边框样式
##   Color    arrow_color       指示箭头颜色
##   int      arrow_size        箭头长度(像素)
##   StyleBox tip_stylebox      提示气泡面板
##   Color    tip_font_color    气泡文字颜色
##   int      tip_font_size     气泡字号
class_name TutorialGuide extends Control

## 空洞/孔内点击(仅 click_to_complete 步骤启用, 用于"点屏幕区域完成"兜底)
signal hole_clicked()

const _DEFAULT_DIM := Color(0, 0, 0, 0.55)
const _DEFAULT_ARROW := Color(1, 0.82, 0.25, 1)
const _DEFAULT_TIP_TEXT := Color(0.95, 0.95, 0.95, 1)

# --- 状态 ---
var _target: Node
var _target_def: TutorialTargetDef
var _block := true
var _click_to_complete := false
var _active := false  # 聚焦中标志: blur(完成/未开始) 时不绘制也不拦截; 聚焦中且无孔(纯提示)才画全屏暗区
var _hole := Rect2()
var _time := 0.0
var _arrow_dir := Vector2.DOWN
var _arrow_anchor := Vector2.ZERO

# --- 主题缓存 ---
var _dim_color := _DEFAULT_DIM
var _frame_style: StyleBox
var _arrow_color := _DEFAULT_ARROW
var _arrow_size := 28.0
var _default_frame: StyleBoxFlat

# --- 子节点(仅承担输入拦截, 全部视觉统一在 _draw 绘制: 暗区→边框→箭头 层级正确) ---
var _dim_top := Control.new()
var _dim_bottom := Control.new()
var _dim_left := Control.new()
var _dim_right := Control.new()
var _sensor := Control.new()
var _tip_panel: PanelContainer
var _tip_text_label: RichTextLabel


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_default_frame = StyleBoxFlat.new()
	_default_frame.draw_center = false
	_default_frame.border_width_left = 2
	_default_frame.border_width_top = 2
	_default_frame.border_width_right = 2
	_default_frame.border_width_bottom = 2
	_default_frame.border_color = _DEFAULT_ARROW
	_default_frame.set_corner_radius_all(4)


func _ready() -> void:
	_build_widgets()
	_apply_theme()
	blur()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()


# ------------------------------------------------------------
# 公开接口
# ------------------------------------------------------------

## 聚焦目标(全屏遮罩 + 挖孔; target 为空 = 纯提示不挖孔)
func focus(target: Node, target_def: TutorialTargetDef, block: bool, click_to_complete: bool, tip_text: String = "") -> void:
	_active = true
	_target = target
	_target_def = target_def
	_block = block
	_click_to_complete = click_to_complete
	set_tip(tip_text)
	_update_geometry()
	queue_redraw()


## 从任务步骤渲染表现(播放桥接: 外部连 task.entity_changed 调用本方法; 无表现字段的普通步骤退化为纯提示)
func show_step(step: Task, host: Node) -> void:
	var step_def := step.def as TutorialStepDef if step else null
	blur()
	var target: Node = null
	if step_def and step_def.target:
		target = step_def.target.resolve(host)
	focus(target, step_def.target if step_def else null,
			step_def.block_input if step_def else true,
			step_def.click_to_complete if step_def else false,
			step.get_current_desc() if step else "")


## 取消聚焦(全部隐藏: 不绘制暗区/边框/箭头, 拦截板失效)
func blur() -> void:
	_active = false
	_target = null
	_target_def = null
	_hole = Rect2()
	_apply_rects()
	if _tip_panel:
		_tip_panel.visible = false
	queue_redraw()


## 当前挖孔矩形(供外部参考)
func get_hole_rect() -> Rect2:
	return _hole


## 设置提示文字(空 = 隐藏气泡)
func set_tip(text: String) -> void:
	if _tip_panel == null:
		return
	_tip_text_label.text = text
	_tip_panel.reset_size()
	_tip_panel.visible = not text.is_empty()


# ------------------------------------------------------------
# 构建
# ------------------------------------------------------------

func _build_widgets() -> void:
	if _tip_panel:
		return
	for r: Control in [_dim_top, _dim_bottom, _dim_left, _dim_right]:
		r.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(r)
	_sensor.mouse_filter = Control.MOUSE_FILTER_STOP
	_sensor.visible = false
	add_child(_sensor)
	_tip_panel = PanelContainer.new()
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.visible = false
	_tip_text_label = RichTextLabel.new()
	_tip_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_text_label.bbcode_enabled = true
	_tip_text_label.fit_content = true
	_tip_text_label.scroll_active = false
	_tip_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_text_label.custom_minimum_size = Vector2(360, 0)
	_tip_panel.add_child(_tip_text_label)
	add_child(_tip_panel)


# ------------------------------------------------------------
# 主题
# ------------------------------------------------------------

func _apply_theme() -> void:
	_dim_color = _read_color("dim_color", _DEFAULT_DIM)
	_arrow_color = _read_color("arrow_color", _DEFAULT_ARROW)
	_arrow_size = float(_read_const("arrow_size", 28))
	_frame_style = get_theme_stylebox("frame_stylebox", "TutorialGuide") \
			if has_theme_stylebox("frame_stylebox", "TutorialGuide") else null
	if _tip_panel:
		var tip_box := get_theme_stylebox("tip_stylebox", "TutorialGuide") \
				if has_theme_stylebox("tip_stylebox", "TutorialGuide") else null
		if tip_box:
			_tip_panel.add_theme_stylebox_override("panel", tip_box)
		var tc := get_theme_color("tip_font_color", "TutorialGuide") \
				if has_theme_color("tip_font_color", "TutorialGuide") else _DEFAULT_TIP_TEXT
		_tip_text_label.add_theme_color_override("default_color", tc)
		var fsz := get_theme_font_size("tip_font_size", "TutorialGuide") \
				if has_theme_font_size("tip_font_size", "TutorialGuide") else 16
		_tip_text_label.add_theme_font_size_override("normal_font_size", fsz)


func _read_color(name: String, fallback: Color) -> Color:
	return get_theme_color(name, "TutorialGuide") if has_theme_color(name, "TutorialGuide") else fallback


func _read_const(name: String, fallback: int) -> int:
	return get_theme_constant(name, "TutorialGuide") if has_theme_constant(name, "TutorialGuide") else fallback


# ------------------------------------------------------------
# 几何更新(每帧, 目标移动/镜头转动持续校正)
# ------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active:
		return
	_time += delta
	_update_geometry()
	queue_redraw()


func _update_geometry() -> void:
	var v := get_viewport_rect().size
	var rect := Rect2()
	if _target_def and _target != null and is_instance_valid(_target) and _target.is_inside_tree():
		rect = TutorialTargetDef.get_screen_rect(_target, _target_def)
	rect = rect.intersection(Rect2(Vector2.ZERO, v))
	_hole = rect
	_apply_rects()
	_update_arrow(v)
	_place_tip(v)


func _apply_rects() -> void:
	var v := get_viewport_rect().size
	if not _active:
		# 未聚焦(完成/未开始): 拦截板全部失效(不拦截任何输入)
		for r: Control in [_dim_top, _dim_bottom, _dim_left, _dim_right]:
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.size = Vector2.ZERO
		_sensor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sensor.visible = false
		return
	_sensor.mouse_filter = Control.MOUSE_FILTER_STOP if _block else Control.MOUSE_FILTER_IGNORE
	_sensor.visible = false
	if _hole.size == Vector2.ZERO:
		# 不挖孔: 单块全屏拦截板(视觉由 _draw 画全屏暗区)
		_dim_top.position = Vector2.ZERO
		_dim_top.size = v
		for r: Control in [_dim_bottom, _dim_left, _dim_right]:
			r.size = Vector2.ZERO
		return
	# 4 矩形拼洞: 拦截板与孔贴合(暗区 STOP 拦截, 孔内穿透到目标按钮/3D 拾取)
	_dim_top.position = Vector2.ZERO
	_dim_top.size = Vector2(v.x, _hole.position.y)
	_dim_bottom.position = Vector2(0.0, _hole.end.y)
	_dim_bottom.size = Vector2(v.x, v.y - _hole.end.y)
	_dim_left.position = Vector2(0.0, _hole.position.y)
	_dim_left.size = Vector2(_hole.position.x, _hole.size.y)
	_dim_right.position = Vector2(_hole.end.x, _hole.position.y)
	_dim_right.size = Vector2(v.x - _hole.end.x, _hole.size.y)
	# 点击兜底感应区: 仅 click_to_complete 时启用(拦截孔内点击; 否则禁用让事件穿透)
	_sensor.visible = _block and _click_to_complete
	_sensor.position = _hole.position
	_sensor.size = _hole.size


## 箭头: 停在挖孔上/下边缘, 尖端贴近孔边指向目标(屏内); 孔无效时隐藏
func _update_arrow(v: Vector2) -> void:
	if _hole.size == Vector2.ZERO:
		_arrow_dir = Vector2.RIGHT
		_arrow_anchor = Vector2.ZERO
		return
	var center := _hole.get_center()
	var gap := _arrow_size * 0.25 + 8.0  # 尖端到孔边的间隙
	_arrow_anchor = Vector2(clampf(center.x, 48.0, v.x - 48.0), _hole.position.y - gap)
	_arrow_dir = Vector2.DOWN  # 尖端朝下指向目标
	if _arrow_anchor.y < gap + 8.0:
		_arrow_anchor.y = _hole.end.y + gap
		_arrow_dir = Vector2.UP


## 提示气泡置于箭头上方(箭头尾端外侧, 固定不动不跟随浮动, 避免晃动影响阅读)
func _place_tip(v: Vector2) -> void:
	if _tip_panel == null or not _tip_panel.visible:
		return
	var margin := 12.0
	var base := _arrow_anchor - _arrow_dir * (_arrow_size + 10.0)
	var pos := Vector2(base.x - _tip_panel.size.x * 0.5, base.y - _tip_panel.size.y)
	pos.x = clampf(pos.x, margin, maxf(margin, v.x - _tip_panel.size.x - margin))
	pos.y = clampf(pos.y, margin, maxf(margin, v.y - _tip_panel.size.y - margin))
	_tip_panel.position = pos


# ------------------------------------------------------------
# 绘制: 层级 = 暗区 → 边框 → 箭头(同一 CanvasItem 内先画后叠, 箭头恒在顶层)
# ------------------------------------------------------------

func _draw() -> void:
	if not _active:
		return  # 未聚焦(完成/未开始)不绘制任何内容
	_draw_dim()
	if _hole.size == Vector2.ZERO:
		return
	if _frame_style:
		draw_style_box(_frame_style, _hole)
	else:
		draw_rect(_hole, _DEFAULT_ARROW, false, 2.0)
	_draw_arrow()


## 暗区: 与拦截板矩形一致(4 矩形拼洞), 直接绘制在本控件(不再被子节点遮盖)
func _draw_dim() -> void:
	var v := get_viewport_rect().size
	if _hole.size == Vector2.ZERO:
		draw_rect(Rect2(Vector2.ZERO, v), _dim_color)
		return
	draw_rect(Rect2(0.0, 0.0, v.x, _hole.position.y), _dim_color)
	draw_rect(Rect2(0.0, _hole.end.y, v.x, v.y - _hole.end.y), _dim_color)
	draw_rect(Rect2(0.0, _hole.position.y, _hole.position.x, _hole.size.y), _dim_color)
	draw_rect(Rect2(_hole.end.x, _hole.position.y, v.x - _hole.end.x, _hole.size.y), _dim_color)


## 箭头: 像素尺寸恒定, 整体沿指向方向往复平移(bob 整体偏移, 长度恒为 arrow_size 不拉伸)
func _draw_arrow() -> void:
	if _arrow_anchor == Vector2.ZERO:
		return
	var bob := sin(_time * 6.0) * 4.0
	var tip := _arrow_anchor + _arrow_dir * bob
	var tail := tip - _arrow_dir * _arrow_size
	var normal := Vector2(-_arrow_dir.y, _arrow_dir.x)
	var half_w := _arrow_size * 0.25
	draw_colored_polygon([
		tip,
		tail + normal * half_w,
		tail - normal * half_w,
	], _arrow_color)