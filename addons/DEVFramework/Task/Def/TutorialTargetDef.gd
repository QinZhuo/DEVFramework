@tool
## 教程目标定义 — 描述"当前步骤指哪个节点", 2D/3D 通用。
##
## 定位: 相对教程宿主 root 的节点路径(node_path 必须存在, 否则视为纯提示步骤)。
## 核心能力: 把 Control / Node2D / Node3D 统一换算为屏幕矩形(Rect2),
## 供遮罩挖孔、指示箭头、点击兜底共用; min_size 统一作用于 2D/3D(小于则外扩到最小挖孔)。
class_name TutorialTargetDef extends Def

## 目标节点路径(相对教程宿主 root)
@export var node_path: NodePath
## 挖孔外扩像素
@export var padding: float = 8.0
## 挖孔最小屏幕尺寸(2D/3D 都生效: 目标换算后小于它即外扩到该尺寸; 无体量的 Node2D 直接以它定尺寸)
@export var min_size := Vector2(96, 96)
## 显示指示箭头
@export var arrow := true


## 解析目标节点(root 为教程宿主; 节点缺失返回 null)
func resolve(root: Node) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_path)


## 统一换算目标节点为屏幕矩形(含 padding 与最小尺寸; 失败返回空 Rect2)
static func get_screen_rect(node: Node, target_def: TutorialTargetDef = null) -> Rect2:
	if node == null or not node.is_inside_tree():
		return Rect2()
	var pad := target_def.padding if target_def else 0.0
	var rect := Rect2()
	if node is Control:
		rect = (node as Control).get_global_rect()
	elif node is Node3D:
		rect = _rect_3d(node)
	elif node is Node2D:
		rect = _rect_2d(node, target_def)
	if rect.size == Vector2.ZERO:
		return Rect2()
	rect = rect.grow(pad)
	# min_size 统一生效(2D/3D): 小于最小尺寸时以中心外扩
	var minv := target_def.min_size if target_def else Vector2.ZERO
	var deficit := Vector2(maxf(minv.x - rect.size.x, 0.0), maxf(minv.y - rect.size.y, 0.0))
	if deficit != Vector2.ZERO:
		rect = rect.grow_individual(deficit.x * 0.5, deficit.y * 0.5, deficit.x * 0.5, deficit.y * 0.5)
	return rect


## Node3D → 屏幕矩形: 全局 AABB 8 角投影取包围矩形; 中心在相机背后时返回空
static func _rect_3d(node: Node3D) -> Rect2:
	var cam := node.get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var aabb := _global_aabb(node)
	if cam.is_position_behind(aabb.get_center()):
		return Rect2()
	var rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(aabb.get_endpoint(i))
		rect = rect.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	if rect.size == Vector2.ZERO:
		# 所有角投影重叠(目标极小/极远): 以中心投影点为单位矩形, 交由 min_size 外扩兜底
		var c := cam.unproject_position(aabb.get_center())
		return Rect2(c - Vector2.ONE * 0.5, Vector2.ONE)
	return rect


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


## Node2D → 屏幕矩形: 汇总自身及子级 Sprite2D/Control 的视觉体量(画布坐标);
## 无任何体量时退化为原点单位矩形, 交由 min_size 外扩定挖孔尺寸
static func _rect_2d(node: Node2D, _target_def: TutorialTargetDef) -> Rect2:
	var rects: Array[Rect2] = []
	_collect_canvas_rects(node, rects)
	if rects.is_empty():
		var origin := node.get_global_transform_with_canvas().origin
		return Rect2(origin - Vector2.ONE * 0.5, Vector2.ONE)
	var merged := rects[0]
	for i in range(1, rects.size()):
		merged = merged.merge(rects[i])
	return merged


## 收集 CanvasItem(含子级, 仅可见)的画布坐标矩形 — 2D 挖孔体量的来源
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