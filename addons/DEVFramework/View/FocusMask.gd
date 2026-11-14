@tool
## 焦点遮罩 — 全场变暗, 只有被聚焦的目标"亮着", 目标外不可交互。不挖洞。
## 统一规则: 目标所在 canvas 上, 除目标外全部压暗, 目标画到暗区之上。
##   · 2D 内容 → 按 modulate 压暗(保留 alpha, 透明/不透明背景都不会露出色块)
##   · 3D 内容 → 目标挪到 highlight_layer, 用与所在相机逐帧同步的相机单独渲染, 贴图盖在暗区上
##   · 子视口里的目标 → 贴图面整体提亮, 子视口内部再按上面两条各自处理
class_name FocusMask extends Control

## 空白处按下(仅 click_to_complete 开启时; 供"点任意处继续")
signal blank_pressed

## 暗区绘制层(必须低于 LIFT_Z)
const DIM_Z := 4090
## 被点亮内容的绘制层
const LIFT_Z := 4095
const _NAV_ACTIONS: Array[StringName] = [&"ui_focus_next", &"ui_focus_prev",
		&"ui_left", &"ui_right", &"ui_up", &"ui_down"]
const _BACK_ACTIONS: Array[StringName] = [&"ui_focus_prev", &"ui_left", &"ui_up"]

## 暗区颜色(alpha = 压暗强度, rgb = 暗色倾向)
@export var dim_color := Color(0.0, 0.0, 0.0, 0.62)
## 拦截目标外的一切交互(点击/悬停/焦点导航)
@export var block_input := true
## 键盘/手柄的"继续"动作, 空 = 只能点击
@export var advance_action: StringName = &"ui_accept"
## 点/按任意处触发 blank_pressed(展示说明类步骤的"点一下继续")
@export var click_to_complete := false
## 3D 目标是否单独重渲染(关闭 = 只提绘制层, 会被其它几何遮挡)
@export var render_3d := true
## 点亮用的渲染层(1..20, 需项目未占用)
@export_range(1, 20) var highlight_layer := 20
## 点亮渲染抗锯齿
@export var highlight_msaa := Viewport.MSAA_4X
## 拖拽放行(可选): 返回 true 时放行全部指针事件
var drag_checker: Callable

## 提示气泡样式(空 = 内置深色圆角)
@export var tip_style: StyleBox
@export var tip_font_size := 20

var _targets: Array[Node] = []
var _paddings := PackedFloat32Array()
## 舞台根(铺暗区/找光源的范围, 避免碰到编辑器或别的场景)
var _host: Node
## 目标 → 真正被点亮的节点(子视口里的目标升级为承载它的 SubView3D 面板)
var _promoted := {}
## canvas(Viewport) → {view, cam, rect}: 每个 canvas 一套"只渲染目标层"的相机
var _lights := {}
var _layers_backup := {}
var _modulate_backup := {}
## 根画布上的 2D 目标 → [z_index, z_as_relative]
var _z_backup := {}
var _dims: Array[Control] = []
## 可交互区域(屏幕坐标)
var _hit_rects: Array[Rect2] = []
var _screen_size := Vector2.ZERO
var _active := false
var _tip_panel: Panel
var _tip_label: RichTextLabel
var _tip_layout_key := []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	visible = false
	set_process_input(true)
	_build_tip()


func _exit_tree() -> void:
	_release_presentation()


# ------------------------------------------------------------
# 公开 API
# ------------------------------------------------------------

## 聚焦一组目标。items 元素: Node, 或 {node, padding}
## opts: dim(Color) / block(bool) / click_to_complete(bool) / advance_action(StringName) /
##       drag_checker(Callable) / tip(String)
## host = 舞台根(铺暗区的范围), 一般传教程/场景根节点
func focus(items: Array, opts: Dictionary = {}, host: Node = null) -> void:
	_apply_opts(opts)
	_host = host
	_targets.clear()
	_paddings = PackedFloat32Array()
	for item in items:
		var node: Node = null
		var padding := 0.0
		if item is Node:
			node = item
		elif item is Dictionary:
			node = item.get("node")
			padding = float(item.get("padding", 0.0))
		if node == null or not is_instance_valid(node):
			continue
		_targets.append(node)
		_paddings.append(padding)
	_active = true
	visible = true
	_apply_presentation()
	_update_geometry()
	set_tip(str(opts.get("tip", "")))
	_grab_target_focus()


## 取消聚焦(暗区消失, 目标绘制顺序/亮度还原, 不再拦截任何输入)
func clear() -> void:
	_active = false
	visible = false
	_targets.clear()
	_paddings = PackedFloat32Array()
	_hit_rects = []
	_tip_layout_key = []
	_release_presentation()
	if _tip_panel:
		_tip_panel.visible = false


## 设置提示文字(空 = 隐藏气泡; 支持 bbcode)
func set_tip(text: String) -> void:
	if _tip_label == null:
		return
	_tip_label.text = text
	_tip_panel.visible = _active and not text.is_empty()
	_tip_layout_key = []
	_place_tip()


func is_active() -> bool:
	return _active


## 是否处于"锁定目标外输入"状态(供外部禁用快捷键/操作)
func is_blocking() -> bool:
	return _active and block_input


## 当前可交互区域(屏幕坐标)
func get_hit_rects() -> Array[Rect2]:
	return _hit_rects.duplicate()


## 重新铺一遍表现(界面换层、目标重新可见时调用)
func refresh() -> void:
	if not _active:
		return
	_apply_presentation()
	_update_geometry()


# ------------------------------------------------------------
# 表现
# ------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _active:
		return
	_update_geometry()
	if not _lights.is_empty():
		_sync_light_cameras()


func _apply_presentation() -> void:
	_release_presentation()
	_promote_targets()
	_dim_2d()
	_lift_root_2d()
	_add_dim(_stage_root())  # 3D 世界(以及根画布上的 2D)压暗
	_light_3d()


## 目标 → 真正点亮的节点(子视口里的目标升级为它的 SubView3D 面板)
func _promote_targets() -> void:
	for node in _targets:
		_promoted[node] = _promote(node)


static func _promote(node: Node) -> Node:
	var viewport := node.get_viewport()
	if not (viewport is SubViewport):
		return node
	var cursor := viewport.get_parent()
	while cursor:
		if cursor is SubView3D and (cursor as SubView3D).viewport == viewport:
			return cursor
		cursor = cursor.get_parent()
	return node


# --- 2D: modulate 压暗, 保留 alpha ---

func _dim_2d() -> void:
	var own_canvas := get_canvas_layer_node()
	var by_layer := {}
	var by_viewport := {}
	for node in _targets:
		if not (node is CanvasItem) or not is_instance_valid(node):
			continue
		var item := node as CanvasItem
		var layer := item.get_canvas_layer_node()
		if layer and layer != own_canvas:
			by_layer.get_or_add(layer, []).append(item)
		elif item.get_viewport() is SubViewport:
			by_viewport.get_or_add(item.get_viewport(), []).append(item)
	for canvas_layer in _collect_canvas_layers():
		if canvas_layer != own_canvas:
			_dim_canvas(canvas_layer, by_layer.get(canvas_layer, []))
	for viewport in by_viewport:
		_dim_canvas(viewport, by_viewport[viewport])


## 把一个 canvas 上"目标祖先链"之外的内容压暗(改 modulate, 不动布局与层级)
func _dim_canvas(canvas: Node, targets: Array) -> void:
	var keep := {}
	for target in targets:
		var cursor: Node = target
		while cursor and cursor != canvas:
			keep[cursor] = true
			cursor = cursor.get_parent()
	_dim_children(canvas, keep)


func _dim_children(node: Node, keep: Dictionary) -> void:
	for child in node.get_children():
		if child is Viewport or child is CanvasLayer:
			continue  # 别的 canvas 自己处理
		if keep.has(child):
			_dim_children(child, keep)
		elif child is CanvasItem:
			_dim_item(child as CanvasItem)
		else:
			_dim_children(child, keep)


func _dim_item(item: CanvasItem) -> void:
	if _modulate_backup.has(item):
		return
	_modulate_backup[item] = item.modulate
	item.modulate = item.modulate * _dim_scale()


## 压暗系数: alpha 越大越暗, rgb 决定暗色倾向(黑 → 纯变暗)
func _dim_scale() -> Color:
	var a := clampf(dim_color.a, 0.0, 1.0)
	return Color(1.0 - a * (1.0 - dim_color.r), 1.0 - a * (1.0 - dim_color.g),
			1.0 - a * (1.0 - dim_color.b), 1.0)


## 根画布上的 2D 目标: 上面盖着全屏暗区, 只能靠绘制顺序提到暗区之上
func _lift_root_2d() -> void:
	for node in _targets:
		if not (node is CanvasItem) or not is_instance_valid(node):
			continue
		var item := node as CanvasItem
		if item.get_canvas_layer_node() or item.get_viewport() is SubViewport:
			continue  # 有独立 canvas, 不需要提层
		_z_backup[item] = [item.z_index, item.z_as_relative]
		item.z_as_relative = false
		item.z_index = LIFT_Z


# --- 3D: 层分离 + 同步相机 + 贴图盖在暗区上 ---

func _light_3d() -> void:
	var by_canvas := {}
	for node in _targets:
		# 主画布: 点亮"能被主相机看见的那一层"(3D 物体本身, 或子视口目标的 SubView3D 面板)
		var promoted: Node = _promoted.get(node)
		if promoted is Node3D and _is_renderable(promoted):
			by_canvas.get_or_add(get_viewport(), []).append(promoted)
		# 不透明子视口: 里面也要压暗背景, 只留目标(透明子视口没别的可见内容, 不用管)
		if node is Node3D and node.get_viewport() is SubViewport \
				and not node.get_viewport().transparent_bg:
			by_canvas.get_or_add(node.get_viewport(), []).append(node)
	for canvas in by_canvas:
		if canvas != get_viewport() and not _has_dim(canvas):
			_add_dim(canvas)
		_light_canvas(canvas, by_canvas[canvas])


func _has_dim(parent: Node) -> bool:
	for dim in _dims:
		if is_instance_valid(dim) and dim.get_parent() == parent:
			return true
	return false


func _is_renderable(node: Node) -> bool:
	return render_3d and node is Node3D and node.get_viewport() == get_viewport()


## 在某个 canvas 里点亮一组 3D 节点: 挪层 → 建同步相机 → 贴图盖上去
func _light_canvas(canvas: Viewport, nodes: Array) -> void:
	var light := _ensure_light(canvas)
	if light.is_empty():
		return
	var layer_bit := 1 << (highlight_layer - 1)
	for node in nodes:
		for visual in _visuals_of(node):
			if not _layers_backup.has(visual):
				_layers_backup[visual] = visual.layers
			visual.layers = layer_bit
	# 相机的 cull_mask 同样筛光源, 光源不进这一层物体就全黑
	var light_scope: Node = _stage_root() if canvas == get_viewport() else canvas
	for light_node in _collect_lights(light_scope):
		if not _layers_backup.has(light_node):
			_layers_backup[light_node] = light_node.layers
		light_node.layers = light_node.layers | layer_bit
	light.view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	light.rect.visible = true
	_sync_light(canvas)


func _ensure_light(canvas: Viewport) -> Dictionary:
	var entry: Dictionary = _lights.get(canvas, {})
	if not entry.is_empty() and is_instance_valid(entry.view) and is_instance_valid(entry.rect):
		return entry
	var view := SubViewport.new()
	view.name = "LightView"
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	view.msaa_3d = highlight_msaa
	view.gui_disable_input = true
	view.size = Vector2i(get_viewport_rect().size) if canvas == get_viewport() else canvas.size
	var cam := Camera3D.new()
	cam.name = "LightCamera"
	cam.cull_mask = 1 << (highlight_layer - 1)
	view.add_child(cam)
	cam.current = true
	var rect := TextureRect.new()
	rect.name = "LightResult"
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture = view.get_texture()
	rect.z_as_relative = false
	rect.z_index = LIFT_Z
	rect.visible = false
	if canvas == get_viewport():
		add_child(view)
		add_child(rect)
		if _tip_panel:
			move_child(_tip_panel, -1)  # 气泡始终盖在点亮结果之上
	else:
		canvas.add_child(view)
		canvas.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	entry = {view = view, cam = cam, rect = rect}
	_lights[canvas] = entry
	return entry


func _sync_light_cameras() -> void:
	for canvas in _lights:
		_sync_light(canvas)


## 点亮相机与"该 canvas 自己的相机"逐项同步(变换 + 投影), 保证画面对齐
func _sync_light(canvas: Viewport) -> void:
	var entry: Dictionary = _lights.get(canvas, {})
	if entry.is_empty() or not is_instance_valid(entry.cam):
		return
	var main := canvas.get_camera_3d()
	if main == null:
		return
	var cam: Camera3D = entry.cam
	var size: Vector2i = Vector2i(get_viewport_rect().size) if canvas == get_viewport() else canvas.size
	if entry.view.size != size:
		entry.view.size = size
	cam.global_transform = main.global_transform
	cam.projection = main.projection
	cam.fov = main.fov
	cam.size = main.size
	cam.near = main.near
	cam.far = main.far
	cam.keep_aspect = main.keep_aspect
	cam.frustum_offset = main.frustum_offset
	cam.h_offset = main.h_offset
	cam.v_offset = main.v_offset


func _release_presentation() -> void:
	for dim in _dims:
		if is_instance_valid(dim):
			dim.visible = false  # 立刻消失, 避免下一帧前闪一下
			dim.queue_free()
	_dims.clear()
	for item in _modulate_backup:
		if is_instance_valid(item):
			item.modulate = _modulate_backup[item]
	_modulate_backup.clear()
	for item in _z_backup:
		if is_instance_valid(item):
			item.z_index = _z_backup[item][0]
			item.z_as_relative = _z_backup[item][1]
	_z_backup.clear()
	for visual in _layers_backup:
		if is_instance_valid(visual):
			visual.layers = _layers_backup[visual]
	_layers_backup.clear()
	for canvas in _lights:
		var entry: Dictionary = _lights[canvas]
		if is_instance_valid(entry.view):
			entry.view.queue_free()
		if is_instance_valid(entry.rect):
			entry.rect.visible = false
			entry.rect.queue_free()
	_lights.clear()
	_promoted.clear()


# --- 暗区块 & 场景范围 ---

func _add_dim(parent: Node) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	var dim := ColorRect.new()
	dim.name = "FocusDim"
	dim.color = dim_color
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.z_as_relative = false
	dim.z_index = DIM_Z
	parent.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dims.append(dim)


## 舞台根: 宿主 → 当前场景 → 遮罩最顶层祖先(编辑器/测试里也不去碰别的场景)
func _stage_root() -> Node:
	var tree := get_tree()
	if is_instance_valid(_host) and _host.is_inside_tree():
		return _host
	if tree.current_scene:
		return tree.current_scene
	var cursor: Node = self
	while cursor.get_parent() and cursor.get_parent() != tree.root:
		cursor = cursor.get_parent()
	return cursor


func _collect_canvas_layers() -> Array[CanvasLayer]:
	var result: Array[CanvasLayer] = []
	var stack: Array[Node] = [_stage_root()]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CanvasLayer:
			result.append(node)
		stack.append_array(node.get_children())
	return result


static func _collect_lights(node: Node) -> Array[Light3D]:
	var result: Array[Light3D] = []
	if node is Light3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_lights(child))
	return result


## 目标自身及子级里所有真实参与绘制的实例(Area3D 本身不画, 画的是它的 mesh 子节点)
static func _visuals_of(node: Node) -> Array[VisualInstance3D]:
	var result: Array[VisualInstance3D] = []
	if node is VisualInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_visuals_of(child))
	return result


# ------------------------------------------------------------
# 输入
# ------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _active or not block_input:
		return
	if drag_checker.is_valid() and drag_checker.call():
		return
	if click_to_complete and (_is_primary_press(event) or _is_advance(event)):
		blank_pressed.emit()
		get_viewport().set_input_as_handled()
		return
	var pos := _pointer_position(event)
	if pos == Vector2.INF:
		if _contain_focus(event):
			get_viewport().set_input_as_handled()
		return
	if not _contains(pos):
		get_viewport().set_input_as_handled()


## 键盘/手柄: 拦截返回键, 并把焦点导航限制在目标内, 防止焦点逃到背后的 UI
func _contain_focus(event: InputEvent) -> bool:
	var focusables := _focusables()
	if focusables.is_empty():
		return _is_nav(event) or event.is_action_pressed(&"ui_cancel")
	if _is_nav(event):
		_cycle_focus(-1 if _is_back_nav(event) else 1, focusables)
		return true
	return event.is_action_pressed(&"ui_cancel")


func _cycle_focus(step: int, focusables: Array[Control]) -> void:
	var current := get_viewport().gui_get_focus_owner()
	var idx := focusables.find(current)
	var next: Control = focusables[0] if idx < 0 else focusables[(idx + step + focusables.size()) % focusables.size()]
	if next and not next.has_focus():
		next.grab_focus()


## 目标自身及子级里所有可聚焦 Control
func _focusables() -> Array[Control]:
	var result: Array[Control] = []
	for node in _targets:
		if is_instance_valid(node):
			_collect_focusables(node, result)
	return result


static func _collect_focusables(node: Node, result: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		if control.is_visible_in_tree() and control.focus_mode != Control.FOCUS_NONE:
			result.append(control)
	for child in node.get_children():
		_collect_focusables(child, result)


func _grab_target_focus() -> void:
	var focusables := _focusables()
	if focusables.is_empty():
		# 目标没有可聚焦控件(如 3D 物体): 释放残留焦点, 免得继续键激活背后被变暗的按钮
		var owner := get_viewport().gui_get_focus_owner()
		if owner:
			owner.release_focus()
		return
	if not focusables[0].has_focus():
		focusables[0].grab_focus()


static func _is_primary_press(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		return button.pressed and button.button_index == MOUSE_BUTTON_LEFT
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	return false


func _is_advance(event: InputEvent) -> bool:
	return advance_action != &"" and event.is_action_pressed(advance_action)


static func _is_nav(event: InputEvent) -> bool:
	for action in _NAV_ACTIONS:
		if event.is_action_pressed(action):
			return true
	return false


static func _is_back_nav(event: InputEvent) -> bool:
	for action in _BACK_ACTIONS:
		if event.is_action_pressed(action):
			return true
	return false


## 指针类事件的屏幕坐标; 非指针事件返回 INF
static func _pointer_position(event: InputEvent) -> Vector2:
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).position
	if event is InputEventMouseMotion:
		return (event as InputEventMouseMotion).position
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).position
	if event is InputEventScreenDrag:
		return (event as InputEventScreenDrag).position
	return Vector2.INF


func _contains(pos: Vector2) -> bool:
	for rect in _hit_rects:
		if rect.has_point(pos):
			return true
	return false


# ------------------------------------------------------------
# 几何
# ------------------------------------------------------------

func _update_geometry() -> void:
	var view := get_viewport_rect().size
	var hit_rects: Array[Rect2] = []
	if view.x > 0.0 and view.y > 0.0:
		var screen := Rect2(Vector2.ZERO, view)
		for i in _targets.size():
			var node := _targets[i]
			if not is_instance_valid(node) or not node.is_inside_tree():
				continue
			var rect := screen_rect(node)
			if rect.size == Vector2.ZERO:
				continue
			rect = rect.grow(_paddings[i] if i < _paddings.size() else 0.0).intersection(screen)
			if rect.size != Vector2.ZERO:
				hit_rects.append(rect)
	if hit_rects == _hit_rects and view == _screen_size:
		return
	_hit_rects = hit_rects
	_screen_size = view
	_place_tip()


# ------------------------------------------------------------
# 提示气泡
# ------------------------------------------------------------

func _build_tip() -> void:
	if _tip_panel:
		return
	_tip_panel = Panel.new()
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.visible = false
	# 气泡永远压在最上层(点亮结果的贴图是 LIFT_Z, 这里必须更高)
	_tip_panel.z_as_relative = false
	_tip_panel.z_index = LIFT_Z + 1
	_tip_panel.add_theme_stylebox_override("panel", tip_style if tip_style else _default_tip_style())
	_tip_label = RichTextLabel.new()
	_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_label.bbcode_enabled = true
	_tip_label.fit_content = false
	_tip_label.scroll_active = false
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tip_label.add_theme_font_size_override("normal_font_size", tip_font_size)
	_tip_panel.add_child(_tip_label)
	add_child(_tip_panel)


static func _default_tip_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.1, 0.12, 0.94)
	box.set_corner_radius_all(10)
	box.content_margin_left = 22.0
	box.content_margin_right = 22.0
	box.content_margin_top = 14.0
	box.content_margin_bottom = 14.0
	return box


## 气泡贴在目标下方(放不下翻到上方); 无目标时贴屏幕底部居中
func _place_tip() -> void:
	if _tip_panel == null or not _tip_panel.visible:
		return
	var view := _screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size
	var anchor := _merged_rects()
	var key := [view, _tip_label.text, anchor]
	if key == _tip_layout_key:
		return
	_tip_layout_key = key
	var box := _tip_panel.get_theme_stylebox("panel")
	var pad_l := box.get_margin(SIDE_LEFT) if box else 0.0
	var pad_r := box.get_margin(SIDE_RIGHT) if box else 0.0
	var pad_t := box.get_margin(SIDE_TOP) if box else 0.0
	var pad_b := box.get_margin(SIDE_BOTTOM) if box else 0.0
	var margin := 12.0
	var width := minf(view.x - margin * 2.0, 720.0)
	_tip_label.size = Vector2(maxf(width - pad_l - pad_r, 1.0), 0.0)
	var height := _tip_label.get_content_height() + pad_t + pad_b
	var panel_size := Vector2(width, height)
	var gap := 14.0
	var pos := Vector2(view.x * 0.5 - width * 0.5, view.y - margin - panel_size.y)
	if anchor.size != Vector2.ZERO:
		pos = Vector2(anchor.get_center().x - width * 0.5, anchor.end.y + gap)
		if pos.y + panel_size.y > view.y - margin:
			pos.y = anchor.position.y - gap - panel_size.y
	pos.x = clampf(pos.x, margin, maxf(margin, view.x - panel_size.x - margin))
	pos.y = clampf(pos.y, margin, maxf(margin, view.y - panel_size.y - margin))
	_tip_panel.position = pos
	_tip_panel.size = panel_size
	_tip_label.position = Vector2(pad_l, pad_t)
	_tip_label.size = Vector2(maxf(panel_size.x - pad_l - pad_r, 1.0),
			maxf(panel_size.y - pad_t - pad_b, 1.0))


func _merged_rects() -> Rect2:
	var merged := Rect2()
	for i in _hit_rects.size():
		merged = _hit_rects[i] if i == 0 else merged.merge(_hit_rects[i])
	return merged


func _apply_opts(opts: Dictionary) -> void:
	if opts.has("dim"):
		dim_color = opts.dim
	if opts.has("block"):
		block_input = opts.block
	if opts.has("click_to_complete"):
		click_to_complete = opts.click_to_complete
	if opts.has("advance_action"):
		advance_action = opts.advance_action
	if opts.has("drag_checker"):
		drag_checker = opts.drag_checker


# ------------------------------------------------------------
# 目标 → 屏幕矩形(2D 控件 / Node2D 精灵 / 3D 模型 / 子视口贴面通用)
# ------------------------------------------------------------

## 节点在屏幕上的可见矩形(失败返回空 Rect2)
static func screen_rect(node: Node) -> Rect2:
	if node == null or not node.is_inside_tree():
		return Rect2()
	var rect := Rect2()
	if node is Node3D:
		rect = _rect_3d(node as Node3D)
	elif node is CanvasItem:
		rect = _rect_2d(node as CanvasItem)
	if rect.size == Vector2.ZERO:
		return Rect2()
	# UI 或 3D 画在子视口里(贴图面渲染到 3D 屏幕等)时, 换回主视口坐标
	return _sub_view_screen_rect(node.get_viewport(), rect)


## CanvasItem → 画布矩形: 合并自身与可见子级(父节点可作为"多目标同框"的目标)
static func _rect_2d(item: CanvasItem) -> Rect2:
	var rects: Array[Rect2] = []
	_collect_canvas_rects(item, rects)
	if rects.is_empty():
		var origin := item.get_global_transform_with_canvas().origin
		return Rect2(origin - Vector2.ONE * 0.5, Vector2.ONE)
	var rect := rects[0]
	for i in range(1, rects.size()):
		rect = rect.merge(rects[i])
	return rect


## 子视口内的矩形 → 主视口矩形(约定: 承载该视口的 SubView3D 是视口的祖先)
static func _sub_view_screen_rect(viewport: Viewport, rect: Rect2) -> Rect2:
	if not (viewport is SubViewport):
		return rect
	var node := viewport.get_parent()
	while node:
		if node is SubView3D and (node as SubView3D).viewport == viewport:
			return (node as SubView3D).viewport_rect_to_screen(rect)
		node = node.get_parent()
	return rect


## Node3D → 屏幕矩形。统一用"可见 mesh 世界 AABB 合并投影"而非顶点投影
static func _rect_3d(node: Node3D) -> Rect2:
	var cam := node.get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var aabb := _visible_mesh_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = _global_aabb(node)  # 无可见网格 → 退回整体 AABB
	if cam.is_position_behind(aabb.get_center()):
		return Rect2()
	var rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(aabb.get_endpoint(i))
		rect = rect.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	if rect.size == Vector2.ZERO:
		# 所有角投影重叠(目标极小/极远): 以中心投影点为单位矩形, 交由 padding 外扩兜底
		var c := cam.unproject_position(aabb.get_center())
		return Rect2(c - Vector2.ONE * 0.5, Vector2.ONE)
	return rect


## 汇总"真实显示中"的网格世界 AABB(合并), 收所有可见 MeshInstance3D 与 Label3D
static func _visible_mesh_aabb(node: Node3D) -> AABB:
	if not node.is_visible_in_tree():
		return AABB()
	var result := AABB()
	var found := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		result = (node as MeshInstance3D).global_transform * (node as MeshInstance3D).mesh.get_aabb()
		found = true
	elif node is Label3D and (node as VisualInstance3D).get_aabb().size != Vector3.ZERO:
		result = (node as Node3D).global_transform * (node as VisualInstance3D).get_aabb()
		found = true
	for child in node.get_children():
		if child is Node3D:
			var aabb := _visible_mesh_aabb(child)
			if aabb.size != Vector3.ZERO:
				result = result.merge(aabb) if found else aabb
				found = true
	return result


## 汇总节点(含子级)的全局 AABB
static func _global_aabb(node: Node3D) -> AABB:
	if node is VisualInstance3D:
		return (node as VisualInstance3D).global_transform * (node as VisualInstance3D).get_aabb()
	var result := AABB()
	var found := false
	for child in node.get_children():
		if child is Node3D:
			var aabb := _global_aabb(child)
			if aabb.size == Vector3.ZERO and not found:
				continue
			result = result.merge(aabb) if found else aabb
			found = true
	if not found:
		return AABB(node.global_position, Vector3.ZERO)
	return result


## 收集 CanvasItem(含子级, 仅可见)的画布坐标矩形
static func _collect_canvas_rects(item: CanvasItem, result: Array[Rect2]) -> void:
	if not item.visible:
		return
	if item is Control:
		result.append((item as Control).get_global_rect())
	elif item is Sprite2D:
		var local := (item as Sprite2D).get_rect()
		if local.size != Vector2.ZERO:
			result.append(_canvas_rect(item, local))
	for child in item.get_children():
		if child is CanvasItem:
			_collect_canvas_rects(child, result)


## 局部矩形 → 画布坐标包围矩形(Node2D 经 global_transform_with_canvas 投影)
static func _canvas_rect(item: Node2D, local_rect: Rect2) -> Rect2:
	var t := item.get_global_transform_with_canvas()
	var p1 := t * local_rect.position
	var p2 := t * (local_rect.position + local_rect.size)
	return Rect2(
		Vector2(minf(p1.x, p2.x), minf(p1.y, p2.y)),
		Vector2(absf(p2.x - p1.x), absf(p2.y - p1.y)))
