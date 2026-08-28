@tool
## 教程引导控件 — 遮罩/挖孔/边框/箭头/提示气泡一体化, 类 Godot 内置控件, 支持主题定制。
##
## 用法(项目创建后挂到自己的 CanvasLayer):
##   var guide := TutorialGuide.new()
##   guide.set_anchors_preset(Control.PRESET_FULL_RECT)
##   guide.start(flow, host)                       # 一行启动(推荐)
##   guide.stop()                                  # 提前结束/跳过
## 低层手动路径: focus(target, target_def, block, click_to_complete, tip_text) / blur()
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
## 步骤进入(step 为当前活跃 Task, 供外部绑定步骤 UI/进度条/播音频)
signal step_started(step: Task)

const _DEFAULT_DIM := Color(0, 0, 0, 0.55)
const _DEFAULT_ARROW := Color(1, 0.82, 0.25, 1)
const _DEFAULT_TIP_TEXT := Color(0.95, 0.95, 0.95, 1)

# --- 状态 ---
var _target: Node
var _target_def: TutorialTargetDef
var _block := true
var _click_to_complete := false
var _active := false  # 聚焦中标志: blur(完成/未开始) 时不绘制也不拦截; 聚焦中且无孔(纯提示)才画全屏暗区
var _arrow := true  # 当前步骤是否显示指示箭头(读 TutorialTargetDef.arrow)
var _hole := Rect2()
var _last_hole := Rect2()  # 上一帧挖孔(未变化且无动画时跳过重绘)
var _time := 0.0
var _arrow_dir := Vector2.DOWN
var _arrow_anchor := Vector2.ZERO
var _task: GroupTask  # start() 创建的任务(供 stop() 停用)
var _paused_tree: SceneTree  # start({pause_tree}) 暂停的世界(完成后自动恢复)

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
	_arrow = target_def.arrow if target_def else true
	_last_hole = Rect2()
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
	_arrow = true
	_hole = Rect2()
	_last_hole = Rect2()
	_apply_rects()
	if _tip_panel:
		_tip_panel.visible = false
	queue_redraw()


# ------------------------------------------------------------
# 一行启动(便捷; 等价外部手动桥接: 创建任务→连信号→activate→首次渲染)
# ------------------------------------------------------------

## 在已挂载的 Guide 上直接启动教程: 内部完成"Task 推进→渲染"桥接, 完成后自动 blur。
## 与手动路径完全等价(外部仍可通过返回的 task 连接 completed / 调 save_data 存档)。
## [param flow] 教程流程(GroupTaskDef, 步骤为 TutorialStepDef; SEQUENTIAL)
## [param host] 教程宿主(目标路径/信号解析相对它)
## [param opts] {pause_tree: bool} 可选暂停世界(完成后自动恢复)
## [return] GroupTask 实体(由外部持有)
func start(flow: GroupTaskDef, host: Node, opts: Dictionary = {}) -> GroupTask:
	var task := flow.create_entity() as GroupTask
	_task = task
	task.entity_changed.connect(_on_task_changed.bind(task, host))
	task.completed.connect(_on_done)
	if opts.get("pause_tree", false):
		_paused_tree = host.get_tree()
		_paused_tree.paused = true
		process_mode = Node.PROCESS_MODE_ALWAYS
	task.activate({"root": host})
	_on_task_changed(task, host)  # activate 不触发 entity_changed, 手动首次渲染
	return task


## 提前结束/跳过教程(取消聚焦 + 停用任务 + 恢复暂停; 不触发 completed, 供"跳过教程"按钮调用)
func stop() -> void:
	if _task:
		_task.deactivate()
		_task = null
	if _paused_tree:
		_paused_tree.paused = false
		_paused_tree = null
	blur()


func _on_task_changed(task: GroupTask, host: Node) -> void:
	if task.is_completed:
		blur()
		return
	var step := task.active_child_entity
	if step and not step.is_completed:
		show_step(step, host)
		step_started.emit(step)


func _on_done() -> void:
	blur()
	if _paused_tree:
		_paused_tree.paused = false
		_paused_tree = null
	_task = null


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
	# 有箭头动画或挖孔变化才重绘; 静止纯提示步骤不再每帧重绘
	if (_arrow and _hole.size != Vector2.ZERO) or _last_hole != _hole:
		_last_hole = _hole
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
	# 拦截策略: 阻断时暗区 STOP(拦截暗区点击, 孔内穿透); 不阻断时暗区 IGNORE(仅视觉不拦输入)
	var dim_filter := Control.MOUSE_FILTER_STOP if _block else Control.MOUSE_FILTER_IGNORE
	_sensor.mouse_filter = Control.MOUSE_FILTER_STOP if _block and _click_to_complete else Control.MOUSE_FILTER_IGNORE
	_sensor.visible = _block and _click_to_complete
	if _hole.size == Vector2.ZERO:
		# 不挖孔: 单块全屏板(阻断时拦截全屏, 不阻断时仅视觉由 _draw 画暗区)
		_dim_top.position = Vector2.ZERO
		_dim_top.size = v
		_dim_top.mouse_filter = dim_filter
		for r: Control in [_dim_bottom, _dim_left, _dim_right]:
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.size = Vector2.ZERO
		return
	# 4 矩形拼洞: 拦截板与孔贴合(暗区拦截, 孔内穿透到目标按钮/3D 拾取)
	_dim_top.position = Vector2.ZERO
	_dim_top.size = Vector2(v.x, _hole.position.y)
	_dim_top.mouse_filter = dim_filter
	_dim_bottom.position = Vector2(0.0, _hole.end.y)
	_dim_bottom.size = Vector2(v.x, v.y - _hole.end.y)
	_dim_bottom.mouse_filter = dim_filter
	_dim_left.position = Vector2(0.0, _hole.position.y)
	_dim_left.size = Vector2(_hole.position.x, _hole.size.y)
	_dim_left.mouse_filter = dim_filter
	_dim_right.position = Vector2(_hole.end.x, _hole.position.y)
	_dim_right.size = Vector2(v.x - _hole.end.x, _hole.size.y)
	_dim_right.mouse_filter = dim_filter
	# 点击兜底感应区: 仅 click_to_complete 时启用(拦截孔内点击; 否则禁用让事件穿透)
	_sensor.position = _hole.position
	_sensor.size = _hole.size


## 箭头: 按挖孔到屏幕四边的富余空间选最佳方位(上/下/左/右), 尖端贴近孔边指向目标;
## 箭头 + 气泡始终落在屏内富余侧, 不遮挡目标; 孔无效或未启用箭头时隐藏
func _update_arrow(v: Vector2) -> void:
	if _hole.size == Vector2.ZERO or not _arrow:
		_arrow_dir = Vector2.RIGHT
		_arrow_anchor = Vector2.ZERO
		return
	var gap := _arrow_size * 0.25 + 8.0  # 尖端到孔边的间隙
	var center := _hole.get_center()
	# 选择富余空间最大的一侧放置(保证箭头+气泡都留在屏内)
	var top := _hole.position.y
	var bottom := v.y - _hole.end.y
	var left := _hole.position.x
	var right := v.x - _hole.end.x
	match _pick_side(top, bottom, left, right):
		"bottom":
			_arrow_dir = Vector2.UP
			_arrow_anchor = Vector2(clampf(center.x, 48.0, v.x - 48.0), _hole.end.y + gap)
		"left":
			_arrow_dir = Vector2.RIGHT
			_arrow_anchor = Vector2(_hole.position.x - gap, clampf(center.y, 48.0, v.y - 48.0))
		"right":
			_arrow_dir = Vector2.LEFT
			_arrow_anchor = Vector2(_hole.end.x + gap, clampf(center.y, 48.0, v.y - 48.0))
		_:
			_arrow_dir = Vector2.DOWN
			_arrow_anchor = Vector2(clampf(center.x, 48.0, v.x - 48.0), _hole.position.y - gap)


## 四边富余空间最大者(箭头/气泡放置侧); 均不足时优先生成上方(目标贴边时的兜底)
func _pick_side(top: float, bottom: float, left: float, right: float) -> String:
	var best := "top"
	var best_space := top
	if bottom > best_space:
		best = "bottom"
		best_space = bottom
	if left > best_space:
		best = "left"
		best_space = left
	if right > best_space:
		best = "right"
	return best


## 提示气泡置于箭头尾端外侧(与箭头同侧), 固定不动不跟随浮动, 避免晃动影响阅读;
## 无箭头时: 有挖孔则置于孔下方, 纯提示(无孔)置于左上角
func _place_tip(v: Vector2) -> void:
	if _tip_panel == null or not _tip_panel.visible:
		return
	var margin := 12.0
	var pos := Vector2.ZERO
	if _arrow_anchor == Vector2.ZERO:
		if _hole.size != Vector2.ZERO:
			pos = Vector2(_hole.get_center().x - _tip_panel.size.x * 0.5, _hole.end.y + margin)
		else:
			pos = Vector2(margin, margin)
	else:
		var tail := _arrow_anchor - _arrow_dir * (_arrow_size + 10.0)
		if _arrow_dir == Vector2.DOWN:
			pos = tail + Vector2(-_tip_panel.size.x * 0.5, -_tip_panel.size.y)
		elif _arrow_dir == Vector2.UP:
			pos = tail + Vector2(-_tip_panel.size.x * 0.5, 0.0)
		elif _arrow_dir == Vector2.RIGHT:
			pos = tail + Vector2(-_tip_panel.size.x, -_tip_panel.size.y * 0.5)
		else:
			pos = tail + Vector2(0.0, -_tip_panel.size.y * 0.5)
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