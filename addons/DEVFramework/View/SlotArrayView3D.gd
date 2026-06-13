@tool
class_name SlotArrayView3D extends Node3D

@export var view_scene: PackedScene:
	set(value):
		view_scene = value
		_preview_setup()

var pool: BakedPool
var data: Array:
	set(value):
		data = value
		refresh()

@export var auto_hide_empty: bool = false:
	set(value):
		auto_hide_empty = value
		_update_slot_visibility()

var views: Array[Node3D] = []

func _resize_views():
	var count = get_child_count()
	while views.size() < count:
		views.append(null)
	while views.size() > count:
		var view = views.pop_back()
		if is_instance_valid(view):
			ArrayViewTool.free_view(view, pool)

func _ready():
	_resize_views()
	_preview_setup()

func _preview_setup():
	if not Engine.is_editor_hint():
		return
	_resize_views()
	clear()
	var slot_nodes := get_children()
	if not view_scene or slot_nodes.is_empty():
		return
	for i in slot_nodes.size():
		var view = ArrayViewTool.create_view(view_scene, pool, null)
		if view:
			slot_nodes[i].add_child(view)
			views[i] = view
	_update_slot_visibility()

func _update_slot_visibility():
	if not auto_hide_empty:
		return
	var slot_nodes := get_children()
	for i in slot_nodes.size():
		var slot = slot_nodes[i] as Node3D
		if not slot:
			continue
		slot.visible = i < views.size() and is_instance_valid(views[i])

func refresh():
	_resize_views()
	clear()
	var slot_nodes := get_children()
	if not data or data.is_empty() or slot_nodes.is_empty():
		return
	var count = mini(data.size(), slot_nodes.size())
	for i in count:
		if data[i] == null:
			continue
		var view = ArrayViewTool.create_view(view_scene, pool, data[i])
		if view:
			slot_nodes[i].add_child(view)
			views[i] = view
	_update_slot_visibility()

func clear():
	for i in views.size():
		if is_instance_valid(views[i]):
			ArrayViewTool.free_view(views[i], pool)
		views[i] = null
	_update_slot_visibility()

func refresh_item(item) -> Node3D:
	_resize_views()
	var item_name = ArrayViewTool.get_item_name(item)
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and view.name == item_name:
			if "data" in view:
				view.data = item
			return view
	var slot_nodes := get_children()
	for i in views.size():
		if not is_instance_valid(views[i]):
			var view = ArrayViewTool.create_view(view_scene, pool, item)
			if view:
				slot_nodes[i].add_child(view)
				views[i] = view
			_update_slot_visibility()
			return view
	return null

func add_item(item) -> Node3D:
	_resize_views()
	var slot_nodes := get_children()
	for i in views.size():
		if not is_instance_valid(views[i]):
			var view = ArrayViewTool.create_view(view_scene, pool, item)
			if view:
				slot_nodes[i].add_child(view)
				views[i] = view
			_update_slot_visibility()
			return view
	return null

func remove_at(index: int):
	_resize_views()
	if index < 0 or index >= views.size():
		return
	if is_instance_valid(views[index]):
		ArrayViewTool.free_view(views[index], pool)
	views[index] = null
	_update_slot_visibility()

func set_item(index: int, item) -> Node3D:
	_resize_views()
	var slot_nodes := get_children()
	if index < 0 or index >= slot_nodes.size():
		return null
	if is_instance_valid(views[index]):
		ArrayViewTool.free_view(views[index], pool)
	var view = ArrayViewTool.create_view(view_scene, pool, item)
	if view:
		slot_nodes[index].add_child(view)
		views[index] = view
	_update_slot_visibility()
	return view

func remove_item(item):
	_resize_views()
	var item_name = ArrayViewTool.get_item_name(item)
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and view.name == item_name:
			ArrayViewTool.free_view(view, pool)
			views[i] = null
			_update_slot_visibility()
			return

func get_item_position(item) -> Vector3:
	_resize_views()
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and "data" in view and view.data == item:
			return view.global_position
	printerr(self, "  无法获取位置 ", item)
	return Vector3.ZERO
