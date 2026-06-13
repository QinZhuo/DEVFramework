## 泛型数组视图组件，用于显示和管理数据项的视图
@tool
class_name ArrayView extends FlowContainer

@export var view_scene: PackedScene
@export var preview_count: int = 3:
	set(value):
		if not Engine.is_editor_hint():
			return
		clear()
		preview_count = value
		for icon in preview_count:
			add_child(view_scene.instantiate())

var data: Array:
	set(value):
		data = value
		refresh()

## 刷新视图，根据当前数据重新显示所有项目
func refresh():
	if not data or data.is_empty():
		clear()
		return
	for item in data:
		add_item(item)

## 清除所有子节点
func clear():
	for view in get_children():
		ArrayViewTool.free_view(view, null)

## 添加新项目到视图中
## [param item] 要添加的数据项
func add_item(item) -> Node:
	var view = ArrayViewTool.create_view(view_scene, null, item)
	if not view:
		return null
	add_child(view)
	return view

## 刷新单个项目视图
## [param item] 要刷新的数据项
func refresh_item(item) -> Node:
	var item_name = ArrayViewTool.get_item_name(item)
	var view = get_node_or_null(item_name)
	if view:
		if "data" in view:
			view.data = item
	else:
		view = add_item(item)

	var index = data.find(item)
	if index >= 0:
		move_child(view, index)

	return view

## 从视图中移除指定项目
## [param item] 要移除的数据项
func remove_item(item):
	var item_name = ArrayViewTool.get_item_name(item)
	var view = get_node_or_null(item_name)
	if view:
		remove_child(view)
		ArrayViewTool.free_view(view, null)

## 获取项目的唯一标识名称
## [param item] 数据项
static func get_item_name(item) -> String:
	return ArrayViewTool.get_item_name(item)
