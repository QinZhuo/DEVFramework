@tool
## 教程遮罩 — 全屏半透明遮罩 + 目标挖孔(4 矩形拼洞) + 边框脉冲 + 指示箭头。
##
## 4 矩形拼洞的关键优势: 视觉挖孔与输入放行天然一致 ——
## 暗区 mouse_filter=STOP 拦截外围点击, 空洞内事件自动放行到
## 目标按钮(gui_input)或 3D 物体(物理拾取), 无需事件转发 hack。
class_name TutorialOverlay extends CanvasLayer

## 空洞内点击(仅 click_to_complete 步骤启用, 用于"点屏幕区域完成"兜底)
signal hole_clicked()

@onready var _dim: Control = $Dim
@onready var _top: ColorRect = $Dim/Top
@onready var _bottom: ColorRect = $Dim/Bottom
@onready var _left: ColorRect = $Dim/Left
@onready var _right: ColorRect = $Dim/Right
@onready var _frame: Panel = $Dim/Frame
@onready var _sensor: Control = $Dim/HoleSensor

var _target: Node
var _target_def: TutorialTargetDef
var _block := true
var _click_to_complete := false
var _hole := Rect2()
var _arrow: Control
var _time := 0.0


## 聚焦目标(target 为空 = 纯提示, 全屏遮罩不挖孔)
func focus(target: Node, target_def: TutorialTargetDef, block: bool, click_to_complete: bool) -> void:
	_target = target
	_target_def = target_def
	_block = block
	_click_to_complete = click_to_complete
	visible = true
	if _arrow:
		_arrow.visible = target != null and target_def != null and target_def.arrow
	# 先按当前状态铺满, 目标移动/镜头转动由 _process 持续校正
	_apply_rect(_current_rect())


## 取消聚焦(全部隐藏)
func blur() -> void:
	_target = null
	_target_def = null
	_hole = Rect2()
	_set_rects_hidden()
	if _arrow:
		_arrow.visible = false


func get_hole_rect() -> Rect2:
	return _hole


## 挂载指示箭头场景实例(由 TutorialTool 注入)
func set_arrow(arrow: Control) -> void:
	_arrow = arrow
	if _arrow:
		add_child(_arrow)
		_arrow.visible = false


func _process(delta: float) -> void:
	_time += delta
	_frame.modulate.a = 0.7 + 0.3 * sin(_time * 5.0)  # 边框呼吸脉冲
	if _target == null or not is_instance_valid(_target) or not _target.is_inside_tree():
		return
	_apply_rect(_current_rect())
	if _arrow and _arrow.visible:
		_update_arrow(delta)


func _current_rect() -> Rect2:
	if _target_def == null:
		return Rect2()
	return TutorialTargetDef.get_screen_rect(_target, _target_def)


func _apply_rect(rect: Rect2) -> void:
	var v := _dim.get_viewport_rect().size
	# 钳制到屏幕内(目标越界时只挖屏内部分; 完全越界 → 不挖孔)
	rect = rect.intersection(Rect2(Vector2.ZERO, v))
	_hole = rect
	# 统一鼠标过滤: block 时暗区拦截, 否则纯视觉
	var filter := Control.MOUSE_FILTER_STOP if _block else Control.MOUSE_FILTER_IGNORE
	for r: ColorRect in [_top, _bottom, _left, _right]:
		r.mouse_filter = filter
	_sensor.mouse_filter = Control.MOUSE_FILTER_STOP if _block else Control.MOUSE_FILTER_IGNORE
	_sensor.visible = false
	if rect.size == Vector2.ZERO:
		# 不挖孔: 单块全屏暗区
		_top.position = Vector2.ZERO
		_top.size = v
		for r: ColorRect in [_bottom, _left, _right]:
			r.size = Vector2.ZERO
		_frame.visible = false
		return
	_top.position = Vector2.ZERO
	_top.size = Vector2(v.x, rect.position.y)
	_bottom.position = Vector2(0.0, rect.end.y)
	_bottom.size = Vector2(v.x, v.y - rect.end.y)
	_left.position = Vector2(0.0, rect.position.y)
	_left.size = Vector2(rect.position.x, rect.size.y)
	_right.position = Vector2(rect.end.x, rect.position.y)
	_right.size = Vector2(v.x - rect.end.x, rect.size.y)
	_frame.visible = true
	_frame.position = rect.position
	_frame.size = rect.size
	# 点击兜底感应区: 仅 click_to_complete 时启用(拦截孔内点击并上报;
	# 否则必须保持禁用, 让孔内事件穿透到目标按钮/3D 物理拾取)
	_sensor.visible = _block and _click_to_complete
	_sensor.position = rect.position
	_sensor.size = rect.size


func _set_rects_hidden() -> void:
	for r: ColorRect in [_top, _bottom, _left, _right]:
		r.size = Vector2.ZERO
	_frame.visible = false
	_sensor.visible = false
	_hole = Rect2()


## 箭头: 屏内停在目标上/下边缘; 屏外贴边指向目标(3D 目标在相机背后时按镜像近似)
func _update_arrow(_delta: float) -> void:
	var v := _dim.get_viewport_rect().size
	var center := _hole.get_center()
	var dir: Vector2
	var anchor: Vector2
	if _hole.size != Vector2.ZERO:
		# 屏内: 悬停在挖孔上边缘(放不下时移到下边缘), 指向目标
		anchor = Vector2(clampf(center.x, 48.0, v.x - 48.0), _hole.position.y - 36.0)
		dir = Vector2.DOWN
		if anchor.y < 24.0:
			anchor.y = _hole.end.y + 36.0
			dir = Vector2.UP
	else:
		# 屏外/无有效投影: 从屏幕中心指向目标投影方向, 钳到屏幕边缘
		var proj := _projected_pos()
		var behind := _target is Node3D and TutorialTargetDef.is_behind_camera(_target)
		if behind:
			proj.x = v.x - proj.x  # 相机背后投影镜像修正
		var to_target := proj - v * 0.5
		if to_target == Vector2.ZERO:
			to_target = Vector2.RIGHT
		var half := v * 0.5 - Vector2(64.0, 64.0)
		var t := minf(half.x / absf(to_target.x), half.y / absf(to_target.y))
		anchor = v * 0.5 + to_target * t
		dir = to_target.normalized()
	# 呼吸: 沿指向方向前后浮动
	var bob := sin(_time * 6.0) * 5.0
	_arrow.rotation = dir.angle()
	_arrow.position = anchor - dir * (24.0 + bob)


## 目标的投影屏幕坐标(Control 取矩形中心; 2D/3D 取原点投影近似)
func _projected_pos() -> Vector2:
	if _target is Control:
		return (_target as Control).get_global_rect().get_center()
	if _target is Node2D:
		return (_target as Node2D).get_global_transform_with_canvas().origin
	if _target is Node3D:
		var cam := (_target as Node3D).get_viewport().get_camera_3d()
		if cam:
			return cam.unproject_position((_target as Node3D).global_position)
	return _dim.get_viewport_rect().size * 0.5