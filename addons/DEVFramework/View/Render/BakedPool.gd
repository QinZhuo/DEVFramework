@tool
class_name BakedPool extends Node3D

func _ready():
	if not Engine.is_editor_hint():
		visible = false

var nead_count: int

var used_items: Array[Node3D]

func pool_get() -> Node3D:
	if get_child_count():
		nead_count = 0
		var item := get_child(0)
		remove_child(item)
		used_items.append(item)
		return item
	else:
		nead_count += 1
		printerr('对象池[', name, ']不足 还需 ', nead_count)
		return null

func pool_push(item: Node3D):
	if !used_items.has(item):
		item.queue_free()
		return
	used_items.erase(item)
	if item.get_parent() != null:
		item.get_parent().remove_child(item)
	add_child(item)
