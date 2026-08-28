@tool
## 教程目标定义 — 描述"当前步骤要指哪", 2D/3D 通用。
##
## 定位: 相对 root 的节点路径, 或场景组名(取第一个命中)。
## 核心能力: 把 Control / Node2D / Node3D 统一换算为屏幕矩形(Rect2),
## 供遮罩挖孔、指示箭头、点击兜底共用。
class_name TutorialTargetDef extends Def

## 定位方式
enum Locate {
	NODE_PATH, ## 按节点路径(相对教程宿主 root)
	GROUP, ## 按场景组名, 取第一个命中节点
}

## 定位方式
@export var locate: Locate = Locate.NODE_PATH
## 目标节点路径(相对教程宿主 root; NODE_PATH 模式)
@export var node_path: NodePath
## 场景组名(取第一个命中节点; GROUP 模式)
@export var group: StringName
## 挖孔外扩像素
@export var padding: float = 8.0
## Node2D 目标的尺寸(世界单位, 用于换算屏幕矩形)
@export var size_2d := Vector2(64, 64)
## 挖孔最小屏幕尺寸(远处 3D 目标太小时保证可读可点)
@export var min_size := Vector2(96, 96)
## 显示指示箭头
@export var arrow := true


## 解析目标节点(root 为教程宿主)
func resolve(root: Node) -> Node:
	if root == null:
		return null
	match locate:
		Locate.NODE_PATH:
			return root.get_node_or_null(node_path)
		Locate.GROUP:
			if group.is_empty():
				return null
			var nodes := root.get_tree().get_nodes_in_group(group)
			return nodes[0] if not nodes.is_empty() else null
	return null


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
	# 保证最小挖孔尺寸(以中心外扩)
	var minv := target_def.min_size if target_def else Vector2.ZERO
	var deficit := Vector2(maxf(minv.x - rect.size.x, 0.0), maxf(minv.y - rect.size.y, 0.0))
	if deficit != Vector2.ZERO:
		rect = rect.grow_individual(deficit.x * 0.5, deficit.y * 0.5, deficit.x * 0.5, deficit.y * 0.5)
	return rect


## 3D 目标是否在相机背后(用于箭头贴边方向的近似修正)
static func is_behind_camera(node: Node3D) -> bool:
	var cam := node.get_viewport().get_camera_3d() if node.is_inside_tree() else null
	return cam != null and cam.is_position_behind(node.global_position)


## Node3D → 屏幕矩形: 全局 AABB 8 角投影取包围矩形; 任一角在相机背后时用中心点兜底
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


## Node2D → 屏幕矩形: 按 size_2d 四角经 canvas 变换(含 Camera2D 缩放)换算
static func _rect_2d(node: Node2D, target_def: TutorialTargetDef) -> Rect2:
	var t := node.get_global_transform_with_canvas()
	var half := (target_def.size_2d if target_def else Vector2(64, 64)) * 0.5
	var rect := Rect2(t * (-half), Vector2.ZERO)
	for corner in [Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
		rect = rect.expand(t * corner)
	return rect